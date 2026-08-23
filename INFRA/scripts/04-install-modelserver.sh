#!/usr/bin/env bash
# Model servers (vLLM) publishing KV-cache events over ZMQ + the render
# (tokenizer) Service the EPP token-producer calls.
#
#   ACCELERATOR=gpu-vllm ./04-install-modelserver.sh          # default, NVIDIA + vLLM
#   ACCELERATOR=gpu-vllm-gke ./04-install-modelserver.sh      # GKE variant
#   ACCELERATOR=gpu-sglang ./04-install-modelserver.sh        # forces the standalone render pool
#   ACCELERATOR=cpu-vllm|amd-vllm|xpu-vllm|tpu-v6|tpu-v7 ./04-install-modelserver.sh
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env.sh"

ACCELERATOR=${ACCELERATOR:-gpu-vllm}
G="${INFRA_ROOT}/manifests/kustomize/precise-prefix-cache-routing"

case "${ACCELERATOR}" in
  gpu-vllm)     OVERLAY="${G}/modelserver/gpu/vllm/base";  RENDER="${G}/render" ;;
  gpu-vllm-gke) OVERLAY="${G}/modelserver/gpu/vllm/gke";   RENDER="${G}/render" ;;
  gpu-sglang)   OVERLAY="${G}/modelserver/gpu/sglang";     RENDER="${G}/render/standalone" ;;
  cpu-vllm)     OVERLAY="${G}/modelserver/cpu/vllm";       RENDER="${G}/render" ;;
  amd-vllm)     OVERLAY="${G}/modelserver/amd/vllm";       RENDER="${G}/render" ;;
  xpu-vllm)     OVERLAY="${G}/modelserver/xpu/vllm";       RENDER="${G}/render" ;;
  tpu-v6)       OVERLAY="${G}/modelserver/tpu/v6/vllm";    RENDER="${G}/render" ;;
  tpu-v7)       OVERLAY="${G}/modelserver/tpu/v7/vllm";    RENDER="${G}/render" ;;
  *) echo "unknown ACCELERATOR=${ACCELERATOR}" >&2; exit 1 ;;
esac

echo "==> model servers: ${OVERLAY}"
kubectl apply -n "${NAMESPACE}" -k "${OVERLAY}"

echo "==> waiting for at least one Ready model server before the render Service"
kubectl wait --for=condition=Available deploy -n "${NAMESPACE}" \
  -l llm-d.ai/guide="${GUIDE_NAME}" --timeout=30m || true

# The render Service must come after the model servers: the default overlay has
# no pods of its own, it selects the decode pods. Until one is Ready the
# Service has no endpoints and token-producer calls fail.
echo "==> render (tokenizer): ${RENDER}"
kubectl apply -n "${NAMESPACE}" -k "${RENDER}"

kubectl get pods -n "${NAMESPACE}"
kubectl get endpoints "${GUIDE_NAME}-render" -n "${NAMESPACE}"
