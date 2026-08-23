# Images — precise-prefix-cache-routing @ llm-d v0.9.0

Every image, where it comes from, and whether you actually need it.
Machine-readable lists: [`../images.txt`](../images.txt),
[`../images-gateway.txt`](../images-gateway.txt),
[`../images-alt-backends.txt`](../images-alt-backends.txt).

## Core — always needed (NVIDIA GPU + vLLM)

| Image | Role | Pulled by | Source of truth |
| --- | --- | --- | --- |
| `docker.io/vllm/vllm-openai:v0.26.0` | Model server. Serves inference, publishes KV-cache events on ZMQ `:5556`, replay on `:5559`, and also serves `/v1/*/render` for tokenization. | model server pods (8 replicas default) | `components/images/gpu-vllm/release` |
| `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.10.0` | The EPP — runs `precise-prefix-cache-producer`, `token-producer`, `prefix-cache-affinity-filter`, `token-load-scorer`. This is the component that does the routing. | `${GUIDE_NAME}-epp` pod | router chart `v0.10.0` default |
| `cfmanteiga/alpine-bash-curl-jq` | Throwaway in-cluster curl pod for verification only. | `scripts/05-verify.sh` | guide README |

## Standalone mode only

| Image | Role |
| --- | --- |
| `docker.io/envoyproxy/envoy:distroless-v1.33.2` | Sidecar proxy in the EPP pod. In standalone mode this *is* the data plane — clients hit `${GUIDE_NAME}-epp:80`, Envoy ext-procs to the EPP and forwards to the chosen pod. Not deployed in gateway mode. |

## Gateway mode only

Pick one provider.

| Provider | Images | Notes |
| --- | --- | --- |
| **agentgateway v1.1.0** (preferred) | `cr.agentgateway.dev/controller:v1.1.0` (control plane), `cr.agentgateway.dev/agentgateway:v1.1.0` (data plane, provisioned per `Gateway`) | Installed by the `agentgateway-crds` + `agentgateway` Helm charts with `inferenceExtension.enabled=true`. |
| **Istio 1.29.2** | `docker.io/istio/pilot:1.29.2`, `docker.io/istio/proxyv2:1.29.2` | `istioctl install` + `ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true`. |
| **GKE** (`gke-l7-rilb`, `gke-l7-regional-external-managed`) | none | Control plane and data plane are Google-managed. |
| **Envoy AI Gateway** | per upstream | Install per aigateway.envoyproxy.io. |

In gateway mode the router chart deploys **only the EPP** — no Envoy sidecar. The
Gateway's own data plane is the proxy, wired to the `InferencePool` through the
chart-created `HTTPRoute`.

## Only if you swap the render (tokenizer) topology

| Image | When |
| --- | --- |
| `docker.io/vllm/vllm-openai-cpu:v0.26.0` | Dedicated GPU-less `vllm launch render` pool (`render/standalone/`, 3 replicas). **Required for SGLang**, which does not implement vLLM's `/v1/*/render`. Optional for vLLM if you would rather not spend model-server CPU on tokenization. |

## Only if you change the accelerator/engine

| Image | Backend |
| --- | --- |
| `docker.io/lmsysorg/sglang:v0.5.16.0` | SGLang on NVIDIA (`--page-size=64`; also needs the standalone render pool) |
| `docker.io/vllm/vllm-openai-rocm:v0.26.0` | AMD ROCm |
| `docker.io/vllm/vllm-openai-xpu:v0.26.0` | Intel XPU |
| `docker.io/vllm/vllm-tpu:v0.26.0` | Google TPU v6e / v7 |
| `ghcr.io/llm-d/llm-d-cuda:v0.9.0`, `llm-d-cpu`, `llm-d-rocm`, `llm-d-xpu` @ `v0.9.0` | llm-d-built engine images (the `llm-d` image components rather than `release`) |

## Not used by this guide

`ghcr.io/llm-d/llm-d-router-disagg-sidecar:v0.10.0` — the routing sidecar, only
needed for P/D disaggregation. There is no P/D in precise-prefix-cache-routing.

## Air-gapped

```bash
TARGET_REGISTRY=registry.internal/llm-d LISTS="images.txt images-gateway.txt" \
  ./scripts/mirror-images.sh
```

Then repoint: the `images:` entries in
`manifests/kustomize/recipes/modelserver/components/images/*/release/kustomization.yaml`
for the engine images, and `--set router.epp.image.repository=...` /
`--set router.proxy.image.repository=...` for the chart images.
