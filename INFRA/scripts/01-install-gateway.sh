#!/usr/bin/env bash
# GATEWAY MODE ONLY. Installs a Gateway API provider (control plane) and the
# `llm-d-inference-gateway` Gateway object in ${NAMESPACE}.
# Skip this entirely for Standalone mode.
#
#   GATEWAY_PROVIDER=agentgateway ./01-install-gateway.sh
#   GATEWAY_PROVIDER=istio        ./01-install-gateway.sh
#   GATEWAY_PROVIDER=gke          ./01-install-gateway.sh   # control plane is managed by GKE
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env.sh"
K="${INFRA_ROOT}/manifests/kustomize/recipes/gateway"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

case "${GATEWAY_PROVIDER}" in
  agentgateway)
    echo "==> agentgateway ${AGENTGATEWAY_VERSION} control plane"
    helm upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
      --namespace agentgateway-system --create-namespace --version "${AGENTGATEWAY_VERSION}"
    helm upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
      --namespace agentgateway-system --create-namespace --version "${AGENTGATEWAY_VERSION}" \
      --set inferenceExtension.enabled=true
    kubectl wait --for=condition=Available deploy -n agentgateway-system --all --timeout=5m
    # Use agentgateway-openshift instead when running on OpenShift.
    kubectl apply -n "${NAMESPACE}" -k "${K}/agentgateway"
    ;;
  istio)
    echo "==> istio ${ISTIO_VERSION} control plane (istioctl must be on PATH)"
    istioctl install -y \
      --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true
    kubectl wait --for=condition=Available deploy/istiod -n istio-system --timeout=5m
    kubectl apply -n "${NAMESPACE}" -k "${K}/istio"
    ;;
  gke)
    echo "==> GKE Gateway controller is cluster-managed; applying Gateway only"
    kubectl apply -n "${NAMESPACE}" -k "${K}/gke-l7-rilb"
    ;;
  envoy-ai-gateway)
    echo "==> Install Envoy AI Gateway per https://aigateway.envoyproxy.io/ first, then:"
    kubectl apply -n "${NAMESPACE}" -k "${K}/envoy-ai-gateway"
    ;;
  *)
    echo "unsupported GATEWAY_PROVIDER=${GATEWAY_PROVIDER}" >&2; exit 1 ;;
esac

echo "==> waiting for Gateway ${GATEWAY_NAME} to be PROGRAMMED"
kubectl wait --for=condition=Programmed "gateway/${GATEWAY_NAME}" -n "${NAMESPACE}" --timeout=5m
kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}"
