#!/usr/bin/env bash
# INFRA/env.sh — pinned environment for the llm-d v0.9.0 release,
# precise-prefix-cache-routing guide.
#
# Every version here is the value shipped in guides/env.sh at tag v0.9.0
# (main has since floated these to "latest" — this file keeps them pinned).
#
#   source ${INFRA_ROOT}/env.sh

export INFRA_ROOT=${INFRA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}
export REPO_ROOT=${REPO_ROOT:-$(realpath "$(git -C "${INFRA_ROOT}" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)}

### llm-d release this tree is pinned to
export LLM_D_VERSION=${LLM_D_VERSION:-v0.9.0}

### Guide / namespace
export GUIDE_NAME=${GUIDE_NAME:-precise-prefix-cache-routing}
export NAMESPACE=${NAMESPACE:-llm-d-${GUIDE_NAME}}
export MODEL_NAME=${MODEL_NAME:-Qwen/Qwen3-32B}

### CRD releases (pinned as of v0.9.0)
export GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.5.1}
if [[ $GATEWAY_API_VERSION == "latest" ]]; then
  export GATEWAY_API_URL=releases/latest/download
else
  export GATEWAY_API_URL=releases/download/${GATEWAY_API_VERSION}
fi
export GAIE_VERSION=${GAIE_VERSION:-v1.5.0}
if [[ $GAIE_VERSION == "latest" ]]; then
  export GAIE_URL=releases/latest/download
else
  export GAIE_URL=releases/download/${GAIE_VERSION}
fi
# llm-d/llm-d-router release (CRDs; used by the flow-control guide, not this one)
export ROUTER_RELEASE_VERSION=${ROUTER_RELEASE_VERSION:-v0.10.0}
if [[ $ROUTER_RELEASE_VERSION == "latest" ]]; then
  export ROUTER_RELEASE_URL=releases/latest/download
else
  export ROUTER_RELEASE_URL=releases/download/${ROUTER_RELEASE_VERSION}
fi

### Router Helm charts (llm-d v0.9.0 ships router component v0.10.0)
export ROUTER_CHART_VERSION=${ROUTER_CHART_VERSION:-v0.10.0}
export ROUTER_STANDALONE_CHART=${ROUTER_STANDALONE_CHART:-oci://ghcr.io/llm-d/charts/llm-d-router-standalone}
export ROUTER_GATEWAY_CHART=${ROUTER_GATEWAY_CHART:-oci://ghcr.io/llm-d/charts/llm-d-router-gateway}
# Local, air-gap friendly copies of the same charts (pulled into charts/).
export ROUTER_STANDALONE_CHART_LOCAL=${ROUTER_STANDALONE_CHART_LOCAL:-${INFRA_ROOT}/charts/llm-d-router-standalone-v0.10.0.tgz}
export ROUTER_GATEWAY_CHART_LOCAL=${ROUTER_GATEWAY_CHART_LOCAL:-${INFRA_ROOT}/charts/llm-d-router-gateway-v0.10.0.tgz}

### EPP image (chart default; override only when mirroring)
export ROUTER_EPP_VERSION=${ROUTER_EPP_VERSION:-v0.10.0}
export ROUTER_EPP_IMAGE=${ROUTER_EPP_IMAGE:-ghcr.io/llm-d/llm-d-router-endpoint-picker}

### Model server / render images (from the `release` image components)
export MODEL_SERVER_IMAGE=${MODEL_SERVER_IMAGE:-docker.io/vllm/vllm-openai:v0.26.0}
export RENDER_IMAGE=${RENDER_IMAGE:-docker.io/vllm/vllm-openai-cpu:v0.26.0}
export ENVOY_SIDECAR_IMAGE=${ENVOY_SIDECAR_IMAGE:-docker.io/envoyproxy/envoy:distroless-v1.33.2}

### Gateway providers (only for Gateway mode)
export GATEWAY_PROVIDER=${GATEWAY_PROVIDER:-agentgateway}   # agentgateway | istio | gke | envoy-ai-gateway | none
export AGENTGATEWAY_VERSION=${AGENTGATEWAY_VERSION:-v1.1.0}
export ISTIO_VERSION=${ISTIO_VERSION:-1.29.2}
export GATEWAY_NAME=${GATEWAY_NAME:-llm-d-inference-gateway}
