#!/usr/bin/env bash
# End-to-end check: resolve the entry point and send a completion request.
#
#   ROUTER_MODE=standalone ./05-verify.sh
#   ROUTER_MODE=gateway    ./05-verify.sh
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env.sh"
ROUTER_MODE=${ROUTER_MODE:-standalone}

if [[ "${ROUTER_MODE}" == "gateway" ]]; then
  IP=$(kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.addresses[0].value}')
else
  IP=$(kubectl get service "${GUIDE_NAME}-epp" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
fi
echo "==> endpoint: http://${IP}"

kubectl get inferencepool,httproute,pods -n "${NAMESPACE}" 2>/dev/null || true

echo "==> EPP log lines mentioning the KV index / pod discovery:"
kubectl logs -n "${NAMESPACE}" "deploy/${GUIDE_NAME}-epp" -c epp --tail=200 2>/dev/null \
  | grep -iE 'kv|prefix|discover' | tail -20 || true

echo "==> sending a completion through the router (in-cluster curl pod)"
kubectl run curl-verify-$RANDOM --rm -i --restart=Never \
  --image=cfmanteiga/alpine-bash-curl-jq -n "${NAMESPACE}" -- \
  curl -sS -X POST "http://${IP}/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"How are you today?\",\"max_tokens\":32}"
