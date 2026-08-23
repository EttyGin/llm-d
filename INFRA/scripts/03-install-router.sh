#!/usr/bin/env bash
# Installs the llm-d Router (EPP) — the component that does the precise
# prefix-cache aware routing. Also creates the InferencePool.
#
#   ROUTER_MODE=standalone ./03-install-router.sh          # default: EPP pod + Envoy sidecar
#   ROUTER_MODE=gateway GATEWAY_PROVIDER=agentgateway ./03-install-router.sh
#
#   CHART_SOURCE=local  ./03-install-router.sh             # use ../charts/*.tgz instead of OCI
#   ENABLE_MONITORING=true ./03-install-router.sh          # needs Prometheus Operator CRDs
#
# The Helm release name MUST stay ${GUIDE_NAME}: the InferencePool selector is
# built from it and pairs with the llm-d.ai/guide label on the model servers.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env.sh"

ROUTER_MODE=${ROUTER_MODE:-standalone}
CHART_SOURCE=${CHART_SOURCE:-oci}
ENABLE_MONITORING=${ENABLE_MONITORING:-false}
V="${INFRA_ROOT}/values"

ARGS=(-f "${V}/base.values.yaml")
[[ "${ENABLE_MONITORING}" == "true" ]] && ARGS+=(-f "${V}/monitoring.values.yaml")

case "${ROUTER_MODE}" in
  standalone)
    if [[ "${CHART_SOURCE}" == "local" ]]; then CHART="${ROUTER_STANDALONE_CHART_LOCAL}"; VERSION_FLAG=()
    else CHART="${ROUTER_STANDALONE_CHART}"; VERSION_FLAG=(--version "${ROUTER_CHART_VERSION}"); fi
    ARGS+=(-f "${V}/precise-prefix-cache-routing.values.yaml")
    ;;
  gateway)
    if [[ "${CHART_SOURCE}" == "local" ]]; then CHART="${ROUTER_GATEWAY_CHART_LOCAL}"; VERSION_FLAG=()
    else CHART="${ROUTER_GATEWAY_CHART}"; VERSION_FLAG=(--version "${ROUTER_CHART_VERSION}"); fi
    # httproute-flags wires the chart-created HTTPRoute to ${GATEWAY_NAME}.
    ARGS+=(-f "${V}/httproute-flags.yaml"
           -f "${V}/precise-prefix-cache-routing.values.yaml"
           --set "provider.name=${GATEWAY_PROVIDER}")
    ;;
  *) echo "ROUTER_MODE must be standalone|gateway" >&2; exit 1 ;;
esac

echo "==> helm upgrade --install ${GUIDE_NAME} (${ROUTER_MODE} mode, chart ${CHART})"
helm upgrade --install "${GUIDE_NAME}" "${CHART}" "${ARGS[@]}" "${VERSION_FLAG[@]}" \
  -n "${NAMESPACE}" --create-namespace

kubectl rollout status "deploy/${GUIDE_NAME}-epp" -n "${NAMESPACE}" --timeout=5m
kubectl get inferencepool,svc -n "${NAMESPACE}"
