#!/usr/bin/env bash
# =============================================================================
# Phase 0, Step B — Bootstrap ArgoCD + External Secrets Operator
#
# These two, and ONLY these two, are installed imperatively. Everything else —
# Strimzi, Elasticsearch, Kibana, Jaeger, OpenTelemetry, kube-prometheus-stack,
# MLflow, Feast, Redis, KServe, Argo Workflows — is installed and continuously
# self-healed by ArgoCD from the fraud-gitops repo.
#
# Why these two are the exception:
#   ArgoCD : something has to install the thing that installs everything else.
#   ESO    : ArgoCD-managed apps need secrets present before they start.
#
# Run AFTER the Terraform apply completes and kubeconfig points at the cluster.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] OK  $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] !!  $*${NC}"; }
die()  { echo -e "${RED}[$(date +%H:%M:%S)] ERR $*${NC}" >&2; exit 1; }
info() { echo -e "${CYAN}[$(date +%H:%M:%S)]    $*${NC}"; }

prompt() {
  local var_name="$1" label="$2" example="$3" default="${4:-}"
  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    info "Using $var_name=$current  (pre-set in environment, skipping prompt)"
    return
  fi
  echo ""
  echo -e "${CYAN}  $label${NC}"
  echo    "    Example : $example"
  if [[ -n "$default" ]]; then
    echo -ne "    Default : $default\n    Your value [press Enter to use default]: "
  else
    echo -ne "    Your value: "
  fi
  read -r input
  local value="${input:-$default}"
  [[ -z "$value" ]] && die "'$label' is required and cannot be empty."
  printf -v "$var_name" '%s' "$value"
  log "  $var_name = $value"
}

prompt_choice() {
  local var_name="$1" label="$2"; shift 2
  local choices=("$@")
  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    info "Using $var_name=$current  (pre-set in environment, skipping prompt)"
    return
  fi
  echo ""
  echo -e "${CYAN}  $label${NC}"
  for i in "${!choices[@]}"; do
    printf "    %d) %s\n" "$((i+1))" "${choices[$i]}"
  done
  echo -ne "    Enter number [1]: "
  read -r input
  local idx=$(( ${input:-1} - 1 ))
  [[ $idx -lt 0 || $idx -ge ${#choices[@]} ]] && die "Invalid choice '$input'."
  printf -v "$var_name" '%s' "${choices[$idx]}"
  log "  $var_name = ${choices[$idx]}"
}

command -v kubectl >/dev/null 2>&1 || die "kubectl not found."
command -v helm    >/dev/null 2>&1 || die "helm not found. Install Helm 3."
command -v aws     >/dev/null 2>&1 || die "aws CLI not found."

kubectl cluster-info >/dev/null 2>&1 \
  || die "kubectl cannot reach a cluster. Run: aws eks update-kubeconfig --region <region> --name fraud-dev-cluster"

echo ""
echo "======================================================"
echo "  Fraud Detection Platform -- ArgoCD + ESO Bootstrap"
echo "======================================================"
echo ""
echo "  This installs ONLY the two components that must exist before"
echo "  GitOps can take over:"
echo "     1. ArgoCD                    - the GitOps controller"
echo "     2. External Secrets Operator - AWS Secrets Manager -> K8s Secrets"
echo ""
echo "  Everything else is installed BY ArgoCD from fraud-gitops."
echo ""

ENV=""; AWS_REGION=""; AWS_ACCOUNT_ID=""; ESO_ROLE_NAME=""

prompt_choice ENV \
  "Target environment (must match the Terraform env you applied)" \
  "dev" "qa" "prod"

prompt AWS_REGION \
  "AWS region where the cluster and Secrets Manager live" \
  "eu-central-1" "eu-central-1"

prompt AWS_ACCOUNT_ID \
  "AWS account ID (12 digits, NO dashes — the console shows it as 8662-5908-4078)" \
  "123456789012" ""

DEFAULT_ESO_ROLE_NAME="fraud-${ENV}-eso-role"
prompt ESO_ROLE_NAME \
  "ESO IAM role name ('terraform output eso_role_name')" \
  "fraud-dev-eso-role" "$DEFAULT_ESO_ROLE_NAME"

# The AWS console displays the account ID with dashes for readability. Pasting
# that produces an unusable ARN and ESO fails to assume the role with a
# misleading error. Strip anything that is not a digit, then insist on 12.
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID//[^0-9]/}"
[[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "AWS account ID must be 12 digits. Got: '$AWS_ACCOUNT_ID'"
ESO_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ESO_ROLE_NAME}"

echo ""
echo "  ----- Configuration Summary -----"
echo "  Environment  : $ENV"
echo "  AWS Region   : $AWS_REGION"
echo "  Account ID   : $AWS_ACCOUNT_ID"
echo "  ESO Role ARN : $ESO_ROLE_ARN"
echo "  Cluster      : $(kubectl config current-context)"
echo "  ---------------------------------"
echo ""
echo -ne "  Continue? [Y/n]: "
read -r confirm
[[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# =============================================================================
# Pre-flight: verify both node pools are healthy before installing anything
#
# A split node group can silently come up with only one pool ready. Installing
# on top of that produces confusing Pending pods later, so check first.
# =============================================================================
echo "--------------------------------------------"
echo "  Pre-flight: node pools"
echo "--------------------------------------------"

# grep -c prints 0 AND exits 1 when there are no matches, so '|| echo 0' would
# produce the string "0\n0" and break the numeric tests below. Use '|| true'.
GENERAL_NODES=$(kubectl get nodes -l workload=general --no-headers 2>/dev/null | grep -c " Ready " || true)
MEMORY_NODES=$(kubectl get nodes -l workload=memory  --no-headers 2>/dev/null | grep -c " Ready " || true)
GENERAL_NODES=${GENERAL_NODES:-0}
MEMORY_NODES=${MEMORY_NODES:-0}

info "General pool  : $GENERAL_NODES Ready"
info "Memory pool   : $MEMORY_NODES Ready"

# Written as 'if' blocks, not '[[ ]] && cmd'. Under 'set -e' a false '&&' list
# returns 1 and kills the script — the warning below would abort the run.
if [[ "$GENERAL_NODES" -lt 1 ]]; then
  die "No Ready nodes in the general pool. Check the node group in the EKS console."
fi
if [[ "$MEMORY_NODES" -lt 1 ]]; then
  warn "No Ready nodes in the memory pool — Elasticsearch and Kafka will stay Pending later."
fi

kubectl get nodes -L workload,node.kubernetes.io/instance-type
log "Node pools verified."

# =============================================================================
# Step 1 of 4 — Helm repositories
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 1 of 4: Helm repositories"
echo "--------------------------------------------"

helm repo add argo             https://argoproj.github.io/argo-helm  2>/dev/null || true
helm repo add external-secrets https://charts.external-secrets.io     2>/dev/null || true
helm repo update
log "Helm repositories updated."

# =============================================================================
# Step 2 of 4 — ArgoCD
#
# The only job here is getting ArgoCD running. Script 02 then hands it ONE root
# Application and ArgoCD discovers the rest of the platform from Git.
#
# TLS: left at the ArgoCD default, matching Infra-Zen. ArgoCD self-signs and
# serves HTTPS end to end, so the browser shows a certificate warning you click
# through. The alternative — configs.params.server.insecure=true — makes ArgoCD
# serve plain HTTP, which is only correct when an ALB ingress in front is
# terminating TLS with a real ACM certificate. No such ingress exists yet, so
# that flag would state something untrue about this cluster. Turn it on in
# Phase 4 when the ALB is actually built.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 2 of 4: ArgoCD"
echo "--------------------------------------------"

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set controller.resources.requests.cpu=250m \
  --set controller.resources.requests.memory=512Mi \
  --wait --timeout 10m

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || \
  kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode)

log "ArgoCD installed."
echo ""
echo "  ============================================================"
echo "  SAVE THESE CREDENTIALS"
echo "  ============================================================"
echo "  Username : admin"
echo "  Password : $ARGOCD_PASSWORD"
echo ""
echo "  Access the UI:"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    open https://localhost:8080"
echo ""
echo "  The browser will warn that the certificate is not trusted."
echo "  Click Advanced -> Proceed. ArgoCD signs its own certificate on a"
echo "  dev cluster; that warning is expected, not a fault."
echo "  Confirm the mode any time with:"
echo "    kubectl logs -n argocd deploy/argocd-server | grep 'tls:'"
echo "  ============================================================"
echo ""

# =============================================================================
# Step 3 of 4 — External Secrets Operator
#
# The service account is annotated with the IRSA role ARN. That annotation is
# the entire authentication story: ESO's pod gets a projected token, exchanges
# it for the role, and reads /fraud/* from Secrets Manager. No AWS keys exist
# anywhere in this cluster.
#
# The CRD flag is 'crds.enabled' in chart 2.x. The old 'installCRDs' name is
# silently ignored by Helm rather than erroring, so a stale flag looks fine
# right up until a CRD turns out to be missing.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 3 of 4: External Secrets Operator"
echo "--------------------------------------------"

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set crds.enabled=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ESO_ROLE_ARN" \
  --wait --timeout 5m

log "External Secrets Operator installed with IRSA role $ESO_ROLE_ARN"

# Prove the annotation actually landed. A typo in the account ID produces an
# ARN that looks plausible but can never be assumed.
ANNOTATED_ARN=$(kubectl get sa external-secrets -n external-secrets \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
if [[ "$ANNOTATED_ARN" != "$ESO_ROLE_ARN" ]]; then
  die "ServiceAccount annotation is '$ANNOTATED_ARN', expected '$ESO_ROLE_ARN'."
fi
log "ServiceAccount annotation verified: $ANNOTATED_ARN"

# Restart so the pod definitely picks up the SA annotation. On a first install
# this is a no-op; on a re-run with a changed ARN it is essential.
kubectl -n external-secrets rollout restart deployment external-secrets
kubectl -n external-secrets rollout status  deployment external-secrets --timeout=180s

# =============================================================================
# Step 4 of 4 — ClusterSecretStore
#
# A ClusterSecretStore (not a namespaced SecretStore) because secrets are
# consumed across many namespaces: monitoring (Grafana), mlflow, kafka, argo.
# One store, many namespaces, one IAM role.
#
# API VERSION: external-secrets.io/v1. ESO 2.x stopped serving v1beta1 — the
# CRD still lists it with served=false, which is why kubectl reports
# "no matches for kind" rather than "CRD not found". Confirm what is actually
# served with:  kubectl api-resources --api-group=external-secrets.io
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 4 of 4: ClusterSecretStore"
echo "--------------------------------------------"

kubectl api-resources --api-group=external-secrets.io 2>/dev/null \
  | grep -q "ClusterSecretStore" \
  || die "ClusterSecretStore CRD is not present. Re-run Step 3 with --set crds.enabled=true"

cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
EOF

log "ClusterSecretStore 'aws-secrets-manager' created."

info "Waiting for the store to validate against AWS..."
sleep 15
STORE_STATUS=$(kubectl get clustersecretstore aws-secrets-manager \
  -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Unknown")

if [[ "$STORE_STATUS" == "Valid" ]]; then
  log "ClusterSecretStore is Valid — IRSA is working end to end."
else
  warn "ClusterSecretStore status: $STORE_STATUS"
  warn "Check with: kubectl describe clustersecretstore aws-secrets-manager"
  warn "Most common causes:"
  warn "  1. Account ID typo in the role ARN (console shows it with dashes)"
  warn "  2. IAM role trust policy does not match"
  warn "     system:serviceaccount:external-secrets:external-secrets"
  warn "  Compare with:"
  warn "     aws iam get-role --role-name $ESO_ROLE_NAME \\"
  warn "       --query 'Role.AssumeRolePolicyDocument'"
fi

echo ""
echo "--------------------------------------------"
echo "  Verification"
echo "--------------------------------------------"
echo ""
echo "ArgoCD (namespace: argocd):"
kubectl get pods -n argocd
echo ""
echo "External Secrets (namespace: external-secrets):"
kubectl get pods -n external-secrets
echo ""

log "Bootstrap complete. ArgoCD and ESO are running."
echo ""
echo "  Nothing else was installed imperatively — by design."
echo "  ArgoCD takes over from here."
echo ""
echo "  ArgoCD admin password : $ARGOCD_PASSWORD"
echo "  ArgoCD UI             : kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "                          then open https://localhost:8080"
echo ""
echo "Next step: ./scripts/02-register-gitops.sh"
