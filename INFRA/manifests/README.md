# Manifests

## `kustomize/`

A self-contained mini-`guides/` root: the guide overlays plus the shared
`recipes/` they reference, with the original relative paths intact. Build any
overlay directly:

```bash
kustomize build kustomize/precise-prefix-cache-routing/modelserver/gpu/vllm/base
```

| Path | What |
| --- | --- |
| `precise-prefix-cache-routing/modelserver/{gpu,cpu,amd,xpu,tpu}/...` | Model server overlays per backend. `gpu/vllm/base` is the default (8 replicas, TP=2, Qwen3-32B, `--block-size=64`, KV events on `:5556` + replay on `:5559`). |
| `precise-prefix-cache-routing/render/` | Default render (tokenizer) overlay — a **Service with no pods**, selecting the decode pods, which already serve `/v1/*/render`. |
| `precise-prefix-cache-routing/render/standalone/` | Dedicated GPU-less `vllm launch render` pool, 3 replicas. Required for SGLang. Publishes the same Service name — apply exactly one of the two. |
| `recipes/modelserver/base/single-host/default/` | The shared decode Deployment the overlays patch. |
| `recipes/modelserver/components/images/*/` | Image pins per backend/channel (`release`, `nightly`, `llm-d`). Change these to point at a mirror. |
| `recipes/modelserver/components/monitoring/` | PodMonitor for the model servers (needs Prometheus Operator). |
| `recipes/gateway/{agentgateway,agentgateway-openshift,istio,gke-l7-*,envoy-ai-gateway}/` | The `llm-d-inference-gateway` Gateway object per provider. Gateway mode only. |

`recipes/gateway/kgateway*` is deprecated in v0.9.0 and slated for removal next
release — retained for migrations only.

## `rendered/`

`kustomize build` output, ready to `kubectl apply -n ${NAMESPACE} -f`, or to drop
into GitOps. Regenerate after editing anything under `kustomize/`.

| File | Source |
| --- | --- |
| `00-gateway-agentgateway.yaml`, `00-gateway-istio.yaml`, `00-gateway-gke-l7-rilb.yaml` | `recipes/gateway/*` |
| `01-modelserver-gpu-vllm.yaml` | `precise-prefix-cache-routing/modelserver/gpu/vllm/base` |
| `02-render-service.yaml` | `precise-prefix-cache-routing/render` |
| `02-render-standalone-pool.yaml` | `precise-prefix-cache-routing/render/standalone` |

## `rendered/reference/`

`helm template` output of the router charts for each mode/provider. **Not for
installation** — install with Helm so upgrades and rollbacks work. These exist to
review what the chart actually produces and to diff across providers.
