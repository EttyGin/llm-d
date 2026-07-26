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
> wrapped: the **router is a pure passthrough** (never modified); the
> **modelserver** carries a few small additive extensions (an image-tag override
> and P/D prefill support). Everything else is driven by values.

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
    └── llm-d-modelserver/     # vLLM model servers, decode + prefill (spec authored via values)
```

## Single source of truth

Edit the `identity:` block at the top of `values.yaml` **once**. Each field is a
YAML anchor referenced throughout the file:

| You set (once)        | Fans out to                                                                     |
| --------------------- | ------------------------------------------------------------------------------- |
| `identity.model`      | vLLM `serve` arg · `--served-model-name` · router tokenizer · autoscaling query |
| `identity.modelLabel` | the `llm-d.ai/model` pod label · InferencePool `matchLabels`                     |
| `identity.guide`      | model server pod labels · the router `InferencePool` selector                   |
| `identity.gateway`    | the router `HTTPRoute` parentRef (a Gateway you deployed separately)             |
| `identity.vllmVersion`| the **tag** on all three vLLM images (decode / tokenizer / render) — repositories stay different |

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
- `examples/values-pd-disaggregation.yaml` — prefill/decode disaggregation (see the P/D section).

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
| P/D prefill role            | `prefill.enabled: true` + `prefill.*` (mirrors every `decode.*` knob) — see the P/D section |
| Workload type               | `decode.workload` / `prefill.workload`: `deployment` (default) or `leaderWorkerSet` (wide-EP / multi-node DP; needs the LWS controller) |
| ModelExpress P2P transfer   | `decode.modelExpress.enabled` (+ `prefill.modelExpress`): init container `pip install`s the client before serve, appends `--load-format=mx`, sets `MODEL_EXPRESS_URL` + `MX_SERVER_ADDRESS` — see the ModelExpress section |
| Image tag (all vLLM images) | `identity.vllmVersion` (shared tag; `decode.image`/`prefill.image` override repo+tag per role) |

To **remove** a default arg (not just override it), edit `decode.spec.args` in
`values.yaml` — that's the base, and the only place args live.

### Examples

- `examples/values-optimized-baseline.yaml` — prefix-cache-affinity routing.
- `examples/values-precise-prefix-cache-routing.yaml` — precise (kv-events) routing.
- `examples/values-pd-disaggregation.yaml` — full prefill/decode disaggregation (see the P/D section).
- `examples/values-wide-ep-lws.yaml` — wide expert parallelism as `LeaderWorkerSet` (multi-node DP).
- `examples/values-wide-ep.yaml` — the same wide-EP as a single-node `Deployment` (no LWS).
- `examples/values-lws-minikube.yaml` — a size=1 `LeaderWorkerSet` that actually runs on a CPU minikube (LWS smoke test).
- `examples/values-wide-ep-glm.yaml` — single-node wide-EP (no LWS) for `zai-org/GLM-5.2-FP8` (manual `pip install modelexpress` in the launch script).
- `examples/values-modelexpress.yaml` — ModelExpress P2P weight transfer via the chart-native `modelExpress` knob.
- `examples/values-existing-pvc.yaml` — load weights from an existing PVC, offline.
- `examples/values-bring-your-own.yaml` — existing SA + hardened pod.
- `examples/values-observability.yaml` — add distributed tracing.
- `examples/values-autoscaling.yaml` — enable KEDA.
- `examples/values-byo-clusterrole.yaml` — admin-less install: don't create the EPP
  ClusterRole/Binding (pre-provision from `examples/rbac/epp-rbac.yaml`).

**Changing the model / hardware** is not a tiny overlay: the base lives in
`values.yaml`, so copy it, edit the `identity:` anchors (model propagates
everywhere) plus `decode.spec` args/resources for the new TP/GPU count, and
install with your copy as `-f`. Helm replaces list values, so args and resources
are edited there in place, not layered.

## P/D disaggregation

Full prefill/decode disaggregation is supported. `prefill.enabled: false` by
default (no prefill Deployment). Prefill is the **same Deployment shape** as the
decode server — same knobs (`spec`, `image`, `extraArgs`, `extraEnv`, volumes,
securityContext, annotations, …), rendered by one shared template partial with
the `llm-d.ai/role` label as the only parameter (kept consistent across selector
+ pod labels).

**Naming follows the topology.** With prefill **off** (aggregated — one server
does both phases) the model server is named `<release>-modelserver` with role
`llm-d.ai/role: prefill-decode` — *not* "decode", which only means something under
disaggregation. With prefill **on** it splits into `<release>-decode` (role
`decode`) + `<release>-prefill` (role `prefill`). The PodMonitor and KEDA
ScaledObject follow the same name automatically.

Enabling prefill is **P/D mode and it mutates the decode pod** — decode gains the
routing-proxy sidecar, a vLLM port shift to `8200`, the `nixl` port, and NIXL
kv-transfer config. The validation **fails fast** if `prefill.enabled` is true
while `decode.spec` lacks the sidecar or the port shift. See
`examples/values-pd-disaggregation.yaml`. The sidecar image is a third image on
its own version track (pinned separately, not `vllmVersion`). Prometheus metrics
extend to prefill (a role-aware PodMonitor); **prefill autoscaling** is left to
WVA / a hand-authored trigger (the chart's KEDA ScaledObject stays decode-only —
see the note in `values.yaml`). Production needs an RDMA (IB/RoCE) interconnect.

## ModelExpress (P2P weight transfer)

[ModelExpress](https://github.com/ai-dynamo/modelexpress) lets a new replica pull
model weights (and compatible JIT caches) over RDMA from a Ready replica instead
of re-loading from disk/HF — faster warm-up when scaling out large models. Set
`decode.modelExpress.enabled: true` (and/or `prefill.modelExpress`) and the chart
wires the server the way `modelexpress/examples/dynamo_p2p_transfer_k8s/vllm`
(single node) does:

- an **init container** `pip install`s the client into a shared dir **before** the
  server starts, exposed to it via `PYTHONPATH=/mx-client` (reusing the server's
  own image, so the Python env matches; override with `modelExpress.installImage`);
- **`--load-format=<loadFormat>`** (default `mx`) is appended to the server args;
- the two address env vars **`MODEL_EXPRESS_URL`** and **`MX_SERVER_ADDRESS`** are
  both set to `modelExpress.serverAddress` (Dynamo reads the former, MX is
  standardizing on the latter; the plugin accepts either).

The ModelExpress **server** itself is not created by this chart — run it separately
and point `serverAddress` at its Service. vLLM 0.23.0+ recognizes the `mx` /
`modelexpress` load format natively; on older vLLM add `VLLM_PLUGINS=modelexpress`
via `modelExpress.extraEnv`. See `examples/values-modelexpress.yaml`.

> **Direct-exec only for `--load-format`.** The flag is *appended to args*, so the
> target container must use `command: [vllm, serve]` with args as vLLM flags. If
> your container runs a **shell script** (`command: [bash, -c]`), put
> `--load-format mx` inside the script and set `modelExpress.loadFormat: ""` (env +
> the install init container still apply). `examples/values-wide-ep-glm.yaml` takes
> the fully-manual route instead: a plain `pip install modelexpress` line in its
> launch script.

## Caveats

- **KEDA `eppServiceName`** is required when autoscaling is on — the modelserver
  chart can't infer the router release, so set it to `<release>-epp`.
- **EPP RBAC**: the upstream OCI `llm-d-router-gateway` chart creates the EPP
  ServiceAccount + namespaced Role/RoleBinding (always) and a `/metrics`-auth
  **ClusterRole** (when `...monitoring.prometheus.enabled=true`, i.e. by default).
  The namespaced Role/SA are created in-namespace (no admin needed) and are not
  swappable. The **cluster-scoped** objects are — via a small vendored patch
  (`charts/llm-d-router/PATCHES.md`). **One switch** for admin-less installs:

  ```yaml
  llm-d-router: { llmd: { router: { rbac: { clusterRole: { create: false } } } } }
  ```

  `clusterRole.create: false` creates **neither** the ClusterRole **nor** its
  ClusterRoleBinding (both need cluster-admin) — pre-provision them yourself from
  `examples/rbac/epp-rbac.yaml`. With `auth` off (default) nothing else changes,
  since that ClusterRole is only used for metrics-auth. Cost: the router is no
  longer a pristine passthrough — re-run
  `charts/llm-d-router/patches/apply-patches.sh` after any OCI version bump.

## Fail-fast validations

`templates/validations.yaml` catches config mistakes at render/install time (not
at runtime):

- `identity.model` and `identity.gateway` are required.
- **KEDA**: `eppServiceName` is required when autoscaling is enabled.
- **P/D**: with `prefill.enabled: true`, `decode.spec` must carry the routing-proxy
  sidecar **and** the `--port` shift, or install fails.
- **Precise routing**: if any `pluginsCustomConfig` sets `blockSize`, the decode
  `--block-size` must match it; if it sets `modelName`, it must equal
  `model.name`. (These two can't be single-sourced — they live inside the opaque
  plugin config string — so they're verified instead.)

## Verify a render

```bash
helm lint .
helm template t . -n llm-d | less
```
