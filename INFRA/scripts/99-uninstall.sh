#!/usr/bin/env bash
# Tears everything down, in reverse order. CRDs are left alone
# (cluster-scoped, shared) unless you pass --crds.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env.sh"
G="${INFRA_ROOT}/manifests/kustomize/precise-prefix-cache-routing"
ACCELERATOR=${ACCELERATOR:-gpu-vllm}

kubectl delete -n "${NAMESPACE}" -k "${G}/render" --ignore-not-found
kubectl delete -n "${NAMESPACE}" -k "${G}/render/standalone" --ignore-not-found
case "${ACCELERATOR}" in
  gpu-vllm)     OVERLAY="${G}/modelserver/gpu/vllm/base" ;;
  gpu-vllm-gke) OVERLAY="${G}/modelserver/gpu/vllm/gke" ;;
  gpu-sglang)   OVERLAY="${G}/modelserver/gpu/sglang" ;;
  cpu-vllm)     OVERLAY="${G}/modelserver/cpu/vllm" ;;
  amd-vllm)     OVERLAY="${G}/modelserver/amd/vllm" ;;
  xpu-vllm)     OVERLAY="${G}/modelserver/xpu/vllm" ;;
  tpu-v6)       OVERLAY="${G}/modelserver/tpu/v6/vllm" ;;
  tpu-v7)       OVERLAY="${G}/modelserver/tpu/v7/vllm" ;;
  *) echo "unknown ACCELERATOR=${ACCELERATOR}" >&2; exit 1 ;;
esac
kubectl delete -n "${NAMESPACE}" -k "${OVERLAY}" --ignore-not-found

helm uninstall "${GUIDE_NAME}" -n "${NAMESPACE}"
# Gateway object (gateway mode only; the recipe dir name differs from the provider name for GKE).
case "${GATEWAY_PROVIDER}" in
  gke) GW_RECIPE=gke-l7-rilb ;;
  *)   GW_RECIPE=${GATEWAY_PROVIDER} ;;
esac
GW_DIR="${INFRA_ROOT}/manifests/kustomize/recipes/gateway/${GW_RECIPE}"
[[ -d "${GW_DIR}" ]] && kubectl delete -n "${NAMESPACE}" -k "${GW_DIR}" --ignore-not-found
kubectl delete secret llm-d-hf-token -n "${NAMESPACE}" --ignore-not-found
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

if [[ "${1:-}" == "--crds" ]]; then
  "${SCRIPT_DIR}/00-install-crds.sh" delete
fi
