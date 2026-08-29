#!/usr/bin/env bash
# =============================================================================
# Phase 0, Step C — Register fraud-gitops with ArgoCD (app-of-apps)
#
# Applies exactly THREE things:
#   1. A repository credential secret so ArgoCD can read fraud-gitops
#   2. The 'fraud-platform' AppProject (the security boundary)
#   3. ONE root Application pointing at argocd/apps/<env>/
#
# That root Application contains other Applications. ArgoCD walks the directory,
# creates each child, and from that moment the platform installs itself.
#
# This is the upgrade over Infra-Zen, where the script applied one manifest per
# service. Here, adding Kafka in Phase 2 is a git commit — not a script edit.
#
# Safe to run before fraud-gitops has content: the AppProject and root app fall
# back to inline definitions if the repo files are not there yet.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

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

prompt_secret() {
  local var_name="$1" label="$2" example="$3"
  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    info "Using $var_name=****** (pre-set in environment, skipping prompt)"
    return
  fi
  echo ""
  echo -e "${CYAN}  $label${NC}"
  echo    "    Example : $example"
  echo -ne "    Your value (input is hidden): "
  read -rs input
  echo ""
  [[ -z "$input" ]] && die "'$label' is required and cannot be empty."
  printf -v "$var_name" '%s' "$input"
  log "  $var_name = ****** (set)"
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

kubectl get deployment argocd-server -n argocd >/dev/null 2>&1 \
  || die "ArgoCD not found. Run ./scripts/01-bootstrap-argocd-eso.sh first."

echo ""
echo "======================================================"
echo "  Fraud Detection Platform -- GitOps Registration"
echo "======================================================"
echo ""
echo "  Registers fraud-gitops with ArgoCD and hands over control."
echo "  After this, ArgoCD installs the whole platform by itself."
echo ""

ENV=""; GITOPS_REPO_URL=""; GITHUB_USERNAME=""; GITOPS_TOKEN=""

prompt_choice ENV "Target environment" "dev" "qa" "prod"

prompt GITOPS_REPO_URL \
  "GitOps repository HTTPS URL" \
  "https://github.com/kelvinSeamount/fraud-gitops.git" ""

prompt GITHUB_USERNAME \
  "Your GitHub username (used for ArgoCD repo authentication)" \
  "kelvinSeamount" ""

prompt_secret GITOPS_TOKEN \
  "GitHub PAT with READ access to fraud-gitops" \
  "github_pat_xxxxxxxxxxxxxxxxxxxx"

echo ""
echo "  ----- Configuration Summary -----"
echo "  Environment  : $ENV"
echo "  GitOps repo  : $GITOPS_REPO_URL"
echo "  GitHub user  : $GITHUB_USERNAME"
echo "  GitHub token : ******"
echo "  ---------------------------------"
echo ""
echo -ne "  Continue? [Y/n]: "
read -r confirm
[[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

ARGOCD_NAMESPACE="argocd"

# =============================================================================
# Step 1 of 3 — Register the repository
#
# ArgoCD discovers repo credentials by looking for Secrets labelled
# argocd.argoproj.io/secret-type=repository. The label is NOT optional —
# without it the secret is invisible and syncs fail with "repository not found".
# =============================================================================
echo "--------------------------------------------"
echo "  Step 1 of 3: Register fraud-gitops"
echo "--------------------------------------------"

kubectl create secret generic fraud-gitops-repo \
  --namespace "$ARGOCD_NAMESPACE" \
  --from-literal=type=git \
  --from-literal=url="$GITOPS_REPO_URL" \
  --from-literal=username="$GITHUB_USERNAME" \
  --from-literal=password="$GITOPS_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret fraud-gitops-repo \
  "argocd.argoproj.io/secret-type=repository" \
  --namespace "$ARGOCD_NAMESPACE" --overwrite

log "Repository registered."

# =============================================================================
# Step 2 of 3 — AppProject
#
# The AppProject is the blast radius. It says: apps in this project may only
# pull from THIS repo, may only deploy to THESE namespaces, and may only create
# THESE cluster-scoped resource kinds.
#
# clusterResourceWhitelist is '*' here on purpose: this platform legitimately
# installs CRDs (Strimzi, KServe, Prometheus Operator, Argo Workflows) and
# ClusterRoles. Restricting it would break those installs. Say that out loud
# rather than pretending it is locked down.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 2 of 3: fraud-platform AppProject"
echo "--------------------------------------------"

PROJECT_FILE="$WORKSPACE_ROOT/fraud-gitops/argocd/projects/fraud-project.yaml"
if [[ -f "$PROJECT_FILE" ]]; then
  sed "s|YOUR_GITHUB_USERNAME|${GITHUB_USERNAME}|g" "$PROJECT_FILE" | kubectl apply -f -
  log "AppProject applied from $PROJECT_FILE"
else
  warn "$PROJECT_FILE not found — creating inline."
  cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: fraud-platform
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Real-Time Fraud Detection Platform
  sourceRepos:
    - "$GITOPS_REPO_URL"
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
EOF
  log "AppProject created inline."
fi

# =============================================================================
# Step 3 of 3 — The root Application (app-of-apps)
#
# ONE manifest. It points at a directory of Application manifests and syncs
# them recursively. Every future platform component is a file in that directory.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 3 of 3: Root Application ($ENV)"
echo "--------------------------------------------"

ROOT_APP_FILE="$WORKSPACE_ROOT/fraud-gitops/argocd/apps/root-app-${ENV}.yaml"
if [[ -f "$ROOT_APP_FILE" ]]; then
  sed "s|YOUR_GITHUB_USERNAME|${GITHUB_USERNAME}|g" "$ROOT_APP_FILE" | kubectl apply -f -
  log "Root Application applied from $ROOT_APP_FILE"
else
  warn "$ROOT_APP_FILE not found — creating inline."
  cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: fraud-platform-root-${ENV}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: fraud-platform
  source:
    repoURL: "$GITOPS_REPO_URL"
    targetRevision: main
    path: argocd/apps/${ENV}
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
  log "Root Application created inline."
fi

echo ""
echo "--------------------------------------------"
echo "  ArgoCD Applications"
echo "--------------------------------------------"
sleep 5
kubectl get applications -n "$ARGOCD_NAMESPACE"

echo ""
log "GitOps registration complete for environment: $ENV"
echo ""
echo "  The platform is now installing itself. Watch it:"
echo "    kubectl get applications -n argocd -w"
echo ""
echo "  First sync takes 10-20 minutes (Elasticsearch and Prometheus are slow)."
echo ""
echo "Next step: ./scripts/03-verify-platform.sh"