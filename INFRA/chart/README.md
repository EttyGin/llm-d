# llm-d umbrella chart — v0.9.0

One Helm release that deploys the llm-d **Router (EPP) + model servers**, wired
from a **single identity** in `global.llmd`. The base is deliberately generic —
a plain `vllm serve` model server with basic load-aware routing — and every
smarter mode (approximate prefix affinity, precise KV-event routing, P/D
disaggregation, wide EP) is an opt-in overlay under `examples/`.

| | |
| --- | --- |
| llm-d release | **v0.9.0** |
| Router chart / EPP | **v0.10.0** (vendored, patched) |
| vLLM default | **v0.26.0** |
| Gateway API / GAIE CRDs | v1.5.1 / v1.5.0 (cluster prerequisite) |
| Mode | **Gateway only** — see below |

## Why `global` and not YAML anchors

The identity is written **once**, in `global.llmd`:

```yaml
global:
  llmd:
    model:      Qwen/Qwen3-32B
    modelLabel: Qwen3-32B
    guide:      optimized-baseline
    gateway:    llm-d-inference-gateway
    vllmVersion: v0.26.0
```

and fans out to the InferencePool selector, the pod labels, the HTTPRoute's
gateway, the tokenizer, and every image tag.

YAML anchors (`&name` / `*name`) cannot do this. They resolve **inside one
file**, so the moment a second `-f` is layered — or someone wraps this chart in
their own — the anchor is gone and the identity has to be restated. Helm
propagates `global` through every level of the dependency tree, so this works:

```yaml
# my-team-chart/values.yaml — a chart that depends on this umbrella
llm-d:
  global:
    llmd:
      model: meta-llama/Llama-3.1-8B-Instruct
      modelLabel: Llama-3.1-8B-Instruct
      guide: my-team-serving
```

and so does `--set global.llmd.guide=...` on the command line. Nothing else
needs restating.

**Precedence, everywhere:** an explicit subchart value wins > `global.llmd.*` >
the chart's built-in default. Nothing silently overrides a value you set.

| You set once | Fans out to |
| --- | --- |
| `global.llmd.model` | render pool arg · EPP tokenizer sidecar · token-producer check · autoscaling query |
| `global.llmd.modelLabel` | `llm-d.ai/model` pod label · InferencePool `matchLabels` |
| `global.llmd.guide` | `llm-d.ai/guide` pod label · InferencePool `matchLabels` · render Service name |
| `global.llmd.gateway` | the `HTTPRoute`'s `parentRefs` |
| `global.llmd.vllmVersion` | decode / prefill / render / tokenizer image tags |
| `global.llmd.hfTokenSecret` | render pool env |
| `global.llmd.accelerator` | `llm-d.ai/accelerator-*` pod labels |

## Layout

```
chart/
├── Chart.yaml                  umbrella, 2 subchart dependencies
├── values.yaml                 global.llmd + the full override surface
├── templates/
│   ├── validations.yaml        fail-fast guards, evaluated at render time
│   └── NOTES.txt
├── examples/                   copy-paste overlays, one per llm-d guide
└── charts/
    ├── llm-d-router/           vendored OCI llm-d-router-gateway v0.10.0 + patches
    └── llm-d-modelserver/      vLLM model servers (decode + prefill) + render pool
```

## Gateway mode only

This umbrella vendors `llm-d-router-gateway`: a Kubernetes Gateway fronts the
EPP, the chart creates the `HTTPRoute`, and the Gateway provider's own proxy is
the data plane. Deploy the Gateway separately and name it in
`global.llmd.gateway`.

**Standalone mode is not available here.** It needs the other upstream chart,
`llm-d-router-standalone`. Setting `router.proxy.enabled=true` on the gateway
chart does *not* work: it has no proxy image defaults and never emits the Envoy
configuration ConfigMap, so the sidecar renders unnamed and imageless. For
standalone, install that chart directly — `INFRA/scripts/03-install-router.sh`
with `ROUTER_MODE=standalone` does exactly that.

## vLLM arguments are yours

`decode.spec` and `prefill.spec` are rendered **verbatim** — they are the
upstream kustomize patch `spec:`, so anything the kustomize overlays express,
this expresses. The chart injects only what the kustomize base injects:
metadata, the guide/role labels, the selector, the pod-template labels and the
ServiceAccount.

The chart deliberately does **not** model tensor parallelism, kv-transfer
configs, all2all backends or MoE flags. Those change per model and per release,
and a chart that guessed them would be wrong more often than right. Author them
in `spec` or append with `extraArgs`.

Additive knobs merge onto `spec` without restating it: `extraArgs`, `extraEnv`,
`extraVolumeMounts`, `extraVolumes`, `podAnnotations`, `deploymentAnnotations`,
`containerSecurityContext`, `podSecurityContext`, `imagePullSecrets`, `image`.

## Tokenization: sidecar, Service, or nothing

The EPP only needs a tokenizer when its plugin chain contains a
`token-producer` — precise prefix-cache routing and P2P source selection do,
load-aware and approximate-prefix routing do **not**. Do not deploy one unused.

`llm-d-modelserver.render.mode` picks the topology:

| mode | What it deploys | When |
| --- | --- | --- |
| `none` *(default)* | nothing | no `token-producer` in the plugin chain |
| `service` | a Service with **no pods**, fronting the model servers | **the llm-d v0.9.0 default for vLLM.** `vllm serve` already exposes the render endpoints, so render capacity scales with the serving fleet and costs no extra pods |
| `standalone` | a dedicated GPU-less `vllm launch render` Deployment | **required for SGLang** (no render endpoints), or when you would rather not spend model-server CPU on tokenization |

The **EPP sidecar** (`llm-d-router.llmd.router.tokenizer.enabled`) is a fourth
option and is **off** — matching both upstream v0.10.0 and the llm-d v0.9.0
guides. It is per-EPP-pod loopback, so render capacity is tied to the EPP
replica count rather than to the fleet. The v0.9.0 guides moved away from it
because render latency sits inside TTFT: a separately-scheduled pool saturates
before the model servers do.

`validations.yaml` enforces the coherence — a `token-producer` with no
tokenizer fails, two tokenizers fail, and a tokenizer nobody calls fails.

Under P/D, `mode: service` fronts the **prefill** pods automatically: the decode
pod's port 8000 belongs to the routing sidecar, not to vLLM. Derived, not
restated — override with `render.selectorRole`.

## Guards

`templates/validations.yaml` fails the render, not the runtime. Everything it
checks is a value that must agree with a value somewhere else but cannot be
single-sourced, because the EPP plugin config is an opaque string and vLLM args
are hand-authored:

* `global.llmd.model` present, `modelLabel` free of `/`, gateway named in
  gateway mode
* the model in the vLLM args == `global.llmd.model` == the plugin config's
  `modelName`
* `--block-size` == the plugin config's `blockSize` **or** `blockSizeTokens`
  (upstream spells it both ways; an earlier version of this guard matched only
  the first and went silently dead against the second)
* P/D mode: the decode pod actually has a routing sidecar and a port shift
* tokenizer coherence, as above
* KEDA needs `eppServiceName`

## Examples

| File | Reproduces |
| --- | --- |
| `values-optimized-baseline.yaml` | approximate prefix affinity + token-load scoring |
| `values-precise-prefix-cache-routing.yaml` | exact KV-event index, with the v0.26 replay socket |
| `values-pd-disaggregation.yaml` | prefill/decode split over NIXL |
| `values-wide-ep.yaml`, `values-wide-ep-lws.yaml` | wide expert parallelism, without and with LeaderWorkerSet |
| `values-wide-ep-glm.yaml`, `values-wide-ep-glm-aggregated.yaml` | GLM-5.2-FP8 wide EP |
| `values-observability.yaml` | Prometheus + tracing |
| `values-autoscaling.yaml` | KEDA on EPP metrics |
| `values-byo-clusterrole.yaml`, `values-bring-your-own.yaml` | admin-less installs |
| `values-existing-pvc.yaml`, `values-modelexpress.yaml`, `values-lws-minikube.yaml` | model delivery and small-cluster variants |

```bash
helm install my-llm-d . -n <ns> -f my-values.yaml -f examples/values-optimized-baseline.yaml
```

## What changed from the v0.8.1 chart

* Router OCI chart **v0.9.0 → v0.10.0**; both vendored tgz variants rebuilt.
* EPP image tag → `v0.10.0`. Upstream also renamed the default repository from
  `llm-d-router-endpoint-picker-dev` to `llm-d-router-endpoint-picker`; this
  chart pins it explicitly, so the rename cannot surprise it.
* vLLM **v0.23.0 → v0.26.0** everywhere; routing sidecar `v0.9.0 → v0.10.0`.
* Identity moved from a file-local `identity:` anchor block to `global.llmd`,
  and the vendored router gained the patches that make the globals reach it.
* Render topology became a mode (`none`/`service`/`standalone`) with the
  Service form as the recommended path; the EPP sidecar is off.
* Precise-routing example gained the vLLM v0.26 **KV-event replay socket**
  (`:5559`), so an EPP restart rebuilds its index from the engine's buffer
  instead of waiting for live traffic.
* `build-variants.sh` now **asserts every patch target before editing**, so an
  upstream bump that drifted fails the build instead of shipping half a patch.
* Block-size guard fixed to match `blockSizeTokens` as well as `blockSize`.

## Bumping the vendored router

See [`charts/llm-d-router/PATCHES.md`](charts/llm-d-router/PATCHES.md). Short
version: bump `Chart.yaml`, `helm dependency update` (which wipes the patches),
then `patches/build-variants.sh` (which puts them back, or tells you exactly
which hunk drifted).
