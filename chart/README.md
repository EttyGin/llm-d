# llm-d umbrella chart

One Helm release that deploys the llm-d **Router (EPP) + model servers**, wired
together from a **single identity block**. Set the model name, gateway name, and
guide label once and they fan out to both components. The base is a **generic**
setup — a plain `vllm serve` model server (Qwen3-32B, TP=2) with **basic
load-aware routing** — and smarter routing modes (optimized-baseline, precise
prefix cache, P/D) are opt-in overlays.

> **The Gateway is not managed here.** Deploy it separately (e.g. the standalone
> `llm-d-gateway` chart) and put its name in `identity.gateway` — the router's
> `HTTPRoute` binds to it. Only the **router** and **modelserver** subcharts are
> wrapped, and **neither subchart is modified** — this umbrella only feeds them
> values.

## Layout

```
chart/
├── Chart.yaml                 # umbrella: 2 subchart dependencies
├── values.yaml                # ← the identity block + all defaults live here
├── templates/
│   ├── validations.yaml       # fail-fast guards (render time)
│   └── NOTES.txt              # post-install: endpoints + test curl
├── examples/                  # copy-paste overlays
└── charts/
    ├── llm-d-router/          # thin passthrough → OCI llm-d-router-gateway (untouched)
    └── llm-d-modelserver/     # vLLM model servers (untouched; decode.spec authored via values)
```

## Single source of truth (no chart edits)

Edit the `identity:` block at the top of `values.yaml` **once**. Each field is a
YAML anchor referenced throughout the file:

| You set (once)      | Fans out to                                                                     |
| ------------------- | ------------------------------------------------------------------------------- |
| `identity.model`    | vLLM `serve` arg · `--served-model-name` · router tokenizer · autoscaling query |
| `identity.modelLabel` | the `llm-d.ai/model` pod label · InferencePool `matchLabels`                   |
| `identity.guide`    | model server pod labels · the router `InferencePool` selector                   |
| `identity.gateway`  | the router `HTTPRoute` parentRef (a Gateway you deployed separately)            |

**How the model name reaches the vLLM args without touching the chart:** the
`decode.spec` is authored in this umbrella's values (the modelserver renders it
verbatim), and the model appears only as the `*model` YAML alias — the serve
positional arg and `--served-model-name`. So the model string is written once.

**InferencePool selector stays in sync:** `modelServers.matchLabels` is built from
the same anchors (`llm-d.ai/guide` + `llm-d.ai/model`) that the model-server pods
carry, so the pool can't drift from the servers. It's a plain map — add more keys
(e.g. `llm-d.ai/accelerator-vendor`) to narrow it.

## Install

Prerequisites (none created by this chart):

- A Gateway named `identity.gateway`, plus Gateway API + GAIE CRDs and the
  `istio` GatewayClass.
- An `HF_TOKEN` secret (unless the model is public/offline).
- The **Prometheus Operator** — metrics are on by default (see below).

```bash
kubectl create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN}" -n "$NAMESPACE"

helm install my-llm-d . -n "$NAMESPACE"
```

> **Overrides:** change the model via the `identity:` block in a `-f` file (anchors
> resolve within one file). A bare `--set identity.model=...` does **not** propagate.

## Default routing (most basic)

The base EPP does **basic load-aware routing**: each request goes to the endpoint
with the **shortest queue** and the **lowest KV-cache utilization** (served
fastest) — `queue-scorer` + `kv-cache-utilization-scorer`, no prefix-cache, no
tokenizer sidecar. Upgrade to smarter routing with an overlay:

- `examples/values-optimized-baseline.yaml` — prefix-cache-affinity (approx, no kv-events).
- `examples/values-precise-prefix-cache-routing.yaml` — exact kv-events index.
- `examples/values-pd-disaggregation.yaml` — the PD guide's **router only** (see note).

## Observability

- **Prometheus metrics: ON by default** — an EPP `ServiceMonitor` + a decode
  `PodMonitor`. Requires the Prometheus Operator (their CRDs); turn off with
  `llm-d-router.llmd.router.monitoring.prometheus.enabled: false` and
  `llm-d-modelserver.monitoring.podMonitor.enabled: false`.
- **Tracing: opt-in** — `-f examples/values-observability.yaml`. Client-side only
  (EPP + vLLM emit to a collector you run); no OTel Collector / Jaeger is created.

## Extension points

The modelserver's native additive knobs (no need to restate `decode.spec`), under
`llm-d-modelserver.decode` unless noted:

| Need                        | Knob                                                             |
| --------------------------- | --------------------------------------------------------------- |
| Extra vLLM args             | `decode.extraArgs` (appended; a repeated `--flag=val` wins — last one) |
| EPP plugins (`plugin.yaml`) | `llm-d-router.llmd.router.epp.pluginsConfigFile` + `pluginsCustomConfig` |
| Security context            | `decode.podSecurityContext`, `decode.containerSecurityContext`   |
| Annotations                 | `decode.podAnnotations`, `decode.deploymentAnnotations`          |
| Existing PVC for weights    | `decode.extraVolumes` + `extraVolumeMounts` + `extraEnv` (see example) |
| Existing ServiceAccount     | `serviceAccount.create: false` + `serviceAccount.name`           |
| Env vars                    | `decode.extraEnv`                                                |
| Extra volumes / mounts      | `decode.extraVolumes`, `decode.extraVolumeMounts`                |
| Autoscaling (KEDA)          | `autoscaling.keda.enabled: true` **+ `eppServiceName: <release>-epp`** |

To **remove** a default arg (not just override it), edit `decode.spec.args` in
`values.yaml` — that's the base, and the only place args live.

### Examples

- `examples/values-optimized-baseline.yaml` — prefix-cache-affinity routing.
- `examples/values-precise-prefix-cache-routing.yaml` — precise (kv-events) routing.
- `examples/values-pd-disaggregation.yaml` — PD guide, **router only** (see note).
- `examples/values-existing-pvc.yaml` — load weights from an existing PVC, offline.
- `examples/values-bring-your-own.yaml` — existing SA + hardened pod.
- `examples/values-observability.yaml` — add distributed tracing.
- `examples/values-autoscaling.yaml` — enable KEDA.

**Changing the model / hardware** is not a tiny overlay: the base lives in
`values.yaml`, so copy it, edit the `identity:` anchors (model propagates
everywhere) plus `decode.spec` args/resources for the new TP/GPU count, and
install with your copy as `-f`. Helm replaces list values, so args and resources
are edited there in place, not layered.

## Caveats

- **P/D disaggregation is router-only here.** It needs separate prefill + decode
  Deployments and a routing-proxy sidecar; the `llm-d-modelserver` subchart models
  only a single `decode` role and is left untouched, so the PD model servers must
  come from the guide's kustomize. The overlay deploys the PD-aware EPP and sets
  `decode.enabled: false`.
- **KEDA `eppServiceName`** is required when autoscaling is on — the modelserver
  chart can't infer the router release, so set it to `<release>-epp`.
- **EPP RBAC**: the router is a pure passthrough over the upstream OCI
  `llm-d-router-gateway` chart, which **always creates** the EPP ServiceAccount +
  namespaced Role/RoleBinding (and a ClusterRole when
  `...monitoring.prometheus.enabled=true`, i.e. by default now). Bring-your-own
  EPP Role is not supported. BYO is available for the **modelserver** SA.

## Verify a render

```bash
helm lint .
helm template t . -n llm-d | less
```
