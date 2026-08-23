#!/usr/bin/env bash
# Checks the deployment end to end and reports whether P/D and P2P are live.
set -uo pipefail
GUIDE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INFRA_ROOT=$(cd "${GUIDE_DIR}/../.." && pwd)
source "${INFRA_ROOT}/env.sh"
export GUIDE_NAME=deepseek-v4-flash
export NAMESPACE=${NAMESPACE:-llm-d-${GUIDE_NAME}}
MODEL_NAME=deepseek-ai/DeepSeek-V4-Flash-0731
ROUTER_MODE=${ROUTER_MODE:-standalone}

echo "==> workloads"
kubectl get deploy,pods,svc,inferencepool -n "${NAMESPACE}"

echo
echo "==> render Service endpoints (must be non-empty, and prefill-only)"
kubectl get endpoints "${GUIDE_NAME}-render" -n "${NAMESPACE}" -o wide

echo
echo "==> EPP: profiles and plugin registration"
kubectl logs -n "${NAMESPACE}" "deploy/${GUIDE_NAME}-epp" -c epp --tail=300 2>/dev/null \
  | grep -iE 'plugin|profile|prefill|decode|p2p' | tail -20

if [[ "${ROUTER_MODE}" == "gateway" ]]; then
  IP=$(kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.addresses[0].value}')
else
  IP=$(kubectl get service "${GUIDE_NAME}-epp" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
fi
echo
echo "==> completion through the router at http://${IP}"
kubectl run curl-verify-$RANDOM --rm -i --restart=Never \
  --image=cfmanteiga/alpine-bash-curl-jq -n "${NAMESPACE}" -- \
  curl -sS -X POST "http://${IP}/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"How are you today?\",\"max_tokens\":32}"

echo
echo "==> NIXL P/D handoffs seen by the decode sidecar"
kubectl logs -n "${NAMESPACE}" -l llm-d.ai/role=decode -c routing-proxy --tail=100 2>/dev/null \
  | grep -iE 'prefill|nixl|remote_kv' | tail -10

echo
echo "==> P2P pulls (empty means every prefix was computed locally, which is"
echo "    expected until a peer out-caches the scheduled pod by minCachedTokenDelta)"
kubectl logs -n "${NAMESPACE}" -l llm-d.ai/role=prefill -c vllm --tail=500 2>/dev/null \
  | grep -iE 'remote_kv_source|p2p' | tail -10
