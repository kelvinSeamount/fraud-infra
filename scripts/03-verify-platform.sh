#!/usr/bin/env bash
# =============================================================================
# Phase 0, Step E — Verify the platform
#
# Six checks, in order:
#   1. Both node pools Ready, taint present on the memory pool
#   2. ArgoCD Applications Synced + Healthy
#   3. Observability stack running (Prometheus, Grafana, ES, Kibana, Jaeger, OTel)
#   4. Pod placement respects the pool split (ES/Kafka on memory pool only)
#   5. ESO successfully materialising secrets from AWS
#   6. The hello-platform GitOps canary is serving
#
# Exits non-zero if anything critical fails, so it can gate a pipeline.
# Components not deployed yet report WARN, not FAIL — re-run it as you go.
# =============================================================================
set -uo pipefail   # NOT -e: run every check and report all failures

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0

ok()    { echo -e "${GREEN}  PASS  $*${NC}"; PASS=$((PASS+1)); }
bad()   { echo -e "${RED}  FAIL  $*${NC}";  FAIL=$((FAIL+1)); }
warn()  { echo -e "${YELLOW}  WARN  $*${NC}"; WARN=$((WARN+1)); }
head_() { echo ""; echo -e "${CYAN}=== $* ===${NC}"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found."; exit 1; }

echo ""
echo "======================================================"
echo "  Fraud Detection Platform -- Phase 0 Verification"
echo "  Cluster: $(kubectl config current-context)"
echo "======================================================"

# ─── 1. Node pools ──────────────────────────────────────────────────────────
head_ "1. Node pools"

GEN=$(kubectl get nodes -l workload=general --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
MEM=$(kubectl get nodes -l workload=memory  --no-headers 2>/dev/null | grep -c " Ready " || echo 0)

[[ "$GEN" -ge 1 ]] && ok "General pool: $GEN node(s) Ready" || bad "General pool has no Ready nodes"
[[ "$MEM" -ge 1 ]] && ok "Memory pool: $MEM node(s) Ready"  || bad "Memory pool has no Ready nodes"

# The taint is the entire point of the split — verify it actually landed.
TAINTED=$(kubectl get nodes -l workload=memory \
  -o jsonpath='{range .items[*]}{.spec.taints[?(@.key=="workload")].value}{"\n"}{end}' 2>/dev/null \
  | grep -c "memory" || echo 0)

[[ "$TAINTED" -ge 1 ]] \
  && ok "Memory pool carries the workload=memory:NoSchedule taint" \
  || bad "Memory pool is NOT tainted — Elasticsearch and the scoring service can co-schedule"

kubectl get nodes -L workload,node.kubernetes.io/instance-type

# ─── 2. ArgoCD ──────────────────────────────────────────────────────────────
head_ "2. ArgoCD Applications"

if ! kubectl get ns argocd >/dev/null 2>&1; then
  bad "argocd namespace missing — run scripts/01 first"
else
  APPS=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$APPS" -eq 0 ]]; then
    warn "No ArgoCD Applications yet — run scripts/02 once fraud-gitops exists"
  else
    ok "$APPS Application(s) registered"
    kubectl get applications -n argocd \
      -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

    NOT_SYNCED=$(kubectl get applications -n argocd \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{"\n"}{end}' \
      | grep -v " Synced" | grep -v '^$' || true)
    [[ -z "$NOT_SYNCED" ]] && ok "All Applications Synced" || warn "Not yet Synced: $NOT_SYNCED"

    DEGRADED=$(kubectl get applications -n argocd \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.health.status}{"\n"}{end}' \
      | grep -E " (Degraded|Missing)" || true)
    [[ -z "$DEGRADED" ]] && ok "No Degraded Applications" || bad "Degraded: $DEGRADED"
  fi
fi

# ─── 3. Observability stack ─────────────────────────────────────────────────
head_ "3. Observability stack"

check_deploy() {
  local ns="$1" selector="$2" label="$3"
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    warn "$label: namespace '$ns' not created yet"
    return
  fi
  local ready
  ready=$(kubectl get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null | grep -c "Running" || echo 0)
  [[ "$ready" -ge 1 ]] && ok "$label: $ready pod(s) Running" || warn "$label: no Running pods in $ns"
}

check_deploy monitoring    "app.kubernetes.io/name=prometheus"              "Prometheus"
check_deploy monitoring    "app.kubernetes.io/name=grafana"                 "Grafana"
check_deploy logging       "common.k8s.elastic.co/type=elasticsearch"       "Elasticsearch"
check_deploy logging       "common.k8s.elastic.co/type=kibana"              "Kibana"
check_deploy observability "app.kubernetes.io/name=jaeger"                  "Jaeger"
check_deploy observability "app.kubernetes.io/name=opentelemetry-collector" "OTel Collector"

# ─── 4. Pod placement ───────────────────────────────────────────────────────
head_ "4. Pod placement (does the taint actually work?)"

MISPLACED=$(kubectl get pods -A -o wide --no-headers 2>/dev/null \
  | grep -Ei "elasticsearch|kafka" \
  | awk '{print $1, $2, $8}' \
  | while read -r ns pod node; do
      pool=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.workload}' 2>/dev/null)
      [[ "$pool" != "memory" ]] && echo "  $ns/$pod is on '$pool' pool (expected memory)"
    done)

[[ -z "$MISPLACED" ]] \
  && ok "All Elasticsearch/Kafka pods are on the memory pool (or none scheduled yet)" \
  || bad "Misplaced pods: $MISPLACED"

# ─── 5. External Secrets ────────────────────────────────────────────────────
head_ "5. External Secrets Operator"

STORE=$(kubectl get clustersecretstore aws-secrets-manager \
  -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Missing")
[[ "$STORE" == "Valid" ]] \
  && ok "ClusterSecretStore is Valid (IRSA working end to end)" \
  || bad "ClusterSecretStore status: $STORE — check the ESO IAM role trust policy"

ES_TOTAL=$(kubectl get externalsecrets -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ES_TOTAL" -eq 0 ]]; then
  warn "No ExternalSecret resources yet (expected until fraud-gitops defines them)"
else
  ES_BAD=$(kubectl get externalsecrets -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.status.conditions[0].reason}{"\n"}{end}' \
    | grep -v " SecretSynced" | grep -v '^$' || true)
  [[ -z "$ES_BAD" ]] && ok "All $ES_TOTAL ExternalSecret(s) synced" || bad "Not synced: $ES_BAD"
fi

# ─── 6. GitOps canary ───────────────────────────────────────────────────────
head_ "6. hello-platform GitOps canary"

if kubectl get deployment hello-platform -n platform-demo >/dev/null 2>&1; then
  READY=$(kubectl get deployment hello-platform -n platform-demo \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [[ "${READY:-0}" -ge 1 ]] \
    && ok "hello-platform: $READY replica(s) Ready — GitOps delivery is proven" \
    || bad "hello-platform deployment exists but no replicas are Ready"
else
  warn "hello-platform not deployed yet (Phase 0 Step D/E)"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo -e "  ${GREEN}PASS: $PASS${NC}   ${YELLOW}WARN: $WARN${NC}   ${RED}FAIL: $FAIL${NC}"
echo "======================================================"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo "Phase 0 is NOT complete. Fix the FAIL items above."
  exit 1
fi
if [[ "$WARN" -gt 0 ]]; then
  echo "Phase 0 core is healthy; some components are still coming up."
  echo "Re-run in a few minutes: ./scripts/03-verify-platform.sh"
  exit 0
fi

echo "Phase 0 verified. The platform is up and self-healing."
echo ""
echo "  Port-forwards:"
echo "    ArgoCD     : kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    Grafana    : kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
echo "    Prometheus : kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090"
echo "    Kibana     : kubectl port-forward svc/fraud-kibana-kb-http -n logging 5601:5601"
echo "    Jaeger     : kubectl port-forward svc/jaeger-query -n observability 16686:16686"