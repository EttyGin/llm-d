#!/usr/bin/env bash
# Cluster-scoped prerequisites: Gateway API + Gateway API Inference Extension CRDs.
# Needs cluster-admin. Run once per cluster.
#
#   ./00-install-crds.sh [apply|delete] [--local]
#
# --local applies the copies under ../crds/ instead of downloading from GitHub.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env.sh"

MODE=${1:-apply}
LOCAL=${2:-}
[[ "$MODE" == "apply" || "$MODE" == "delete" ]] || { echo "usage: $0 [apply|delete] [--local]" >&2; exit 1; }
FLAGS=()
[[ "$MODE" == "delete" ]] && FLAGS=(--ignore-not-found)

if [[ "$LOCAL" == "--local" ]]; then
  GWAPI="${INFRA_ROOT}/crds/gateway-api-${GATEWAY_API_VERSION}-standard-install.yaml"
  GAIE="${INFRA_ROOT}/crds/gaie-${GAIE_VERSION}-v1-manifests.yaml"
else
  GWAPI="https://github.com/kubernetes-sigs/gateway-api/${GATEWAY_API_URL}/standard-install.yaml"
  GAIE="https://github.com/kubernetes-sigs/gateway-api-inference-extension/${GAIE_URL}/v1-manifests.yaml"
fi

echo "==> Gateway API ${GATEWAY_API_VERSION}: ${MODE}"
kubectl "$MODE" "${FLAGS[@]}" -f "$GWAPI"
echo "==> GAIE ${GAIE_VERSION} (InferencePool v1): ${MODE}"
kubectl "$MODE" "${FLAGS[@]}" -f "$GAIE"

if [[ "$MODE" == "apply" ]]; then
  kubectl get crd inferencepools.inference.networking.k8s.io gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
fi
