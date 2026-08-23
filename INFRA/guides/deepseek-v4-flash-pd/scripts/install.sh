#!/usr/bin/env bash
# Deploys the whole guide: router (EPP + InferencePool), model servers
# (prefill + decode) and the render Service.
#
#   export HF_TOKEN=hf_xxx
#   ./install.sh
#
# Knobs:
#   NAMESPACE          target namespace              (default llm-d-deepseek-v4-flash)
#   MODELSERVER_VALUES extra -f layers for the chart (space separated, from ../values/)
#   ROUTER_MODE        standalone | gateway          (default standalone)
#   PRECISE_ROUTING    true to add the precise index (needs dp-multiport + decode-dep8)
#   CHART_SOURCE       oci | local                   (default oci)
set -euo pipefail
GUIDE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INFRA_ROOT=$(cd "${GUIDE_DIR}/../.." && pwd)
source "${INFRA_ROOT}/env.sh"

export GUIDE_NAME=deepseek-v4-flash
export NAMESPACE=${NAMESPACE:-llm-d-${GUIDE_NAME}}
export MODEL_NAME=deepseek-ai/DeepSeek-V4-Flash-0731
ROUTER_MODE=${ROUTER_MODE:-standalone}
CHART_SOURCE=${CHART_SOURCE:-oci}
PRECISE_ROUTING=${PRECISE_ROUTING:-false}
MODELSERVER_VALUES=${MODELSERVER_VALUES:-}

: "${HF_TOKEN:?export HF_TOKEN=<your HuggingFace token> first}"

echo "==> namespace + HF token secret"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN}" -n "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 1. Router ---------------------------------------------------------------
# Installed first so the InferencePool exists before the pods that join it.
ROUTER_ARGS=(-f "${INFRA_ROOT}/values/base.values.yaml"
             -f "${GUIDE_DIR}/router/${GUIDE_NAME}.values.yaml")
if [[ "${PRECISE_ROUTING}" == "true" ]]; then
  ROUTER_ARGS+=(-f "${GUIDE_DIR}/router/precise-routing.values.yaml")
fi

if [[ "${ROUTER_MODE}" == "gateway" ]]; then
  ROUTER_ARGS+=(-f "${INFRA_ROOT}/values/httproute-flags.yaml"
                --set "provider.name=${GATEWAY_PROVIDER}")
  CHART=${ROUTER_GATEWAY_CHART}; CHART_LOCAL=${ROUTER_GATEWAY_CHART_LOCAL}
else
  CHART=${ROUTER_STANDALONE_CHART}; CHART_LOCAL=${ROUTER_STANDALONE_CHART_LOCAL}
fi

if [[ "${CHART_SOURCE}" == "local" ]]; then
  CHART_REF="${CHART_LOCAL}"; VERSION_FLAG=()
else
  CHART_REF="${CHART}"; VERSION_FLAG=(--version "${ROUTER_CHART_VERSION}")
fi

echo "==> router (${ROUTER_MODE}, precise=${PRECISE_ROUTING})"
helm upgrade --install "${GUIDE_NAME}" "${CHART_REF}" \
  "${ROUTER_ARGS[@]}" "${VERSION_FLAG[@]}" -n "${NAMESPACE}"

# --- 2. Model servers + render Service ---------------------------------------
MS_ARGS=()
for layer in ${MODELSERVER_VALUES}; do
  MS_ARGS+=(-f "${GUIDE_DIR}/values/${layer}")
done

echo "==> model servers${MODELSERVER_VALUES:+ (layers: ${MODELSERVER_VALUES})}"
helm upgrade --install "${GUIDE_NAME}-modelserver" "${GUIDE_DIR}/chart" \
  "${MS_ARGS[@]}" -n "${NAMESPACE}"

echo
echo "==> weights are ~304B; first pull and EP shard load take a long time."
echo "    kubectl get pods -n ${NAMESPACE} -w"
