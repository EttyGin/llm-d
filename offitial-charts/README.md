# llm-d 0.8.1 — Helm charts (Gateway mode)

Helm packaging of the llm-d **Precise Prefix Cache Routing** well-lit path, in
**Gateway mode**, with the **`flowControl`** feature gate enabled.

The values tree mirrors the upstream guide layout, so an install reads like the
guide's own `helm install` command:

```bash
helm install ppc charts/llm-d-router \
  -f values/base.values.yaml \
  -f values/guides/precise-prefix-cache-flowcontrol.yaml \
  -f values/features/httproute-flags.yaml \
  -n $NAMESPACE
```

| Chart | What it deploys |
|---|---|
| `charts/llm-d-gateway` | `Gateway` + Istio infrastructure params |
| `charts/llm-d-router` | EPP Deployment, `InferencePool`, `HTTPRoute`, `InferenceObjective`s, `DestinationRule`, RBAC |
| `charts/llm-d-modelserver` | vLLM `decode` pods + the `render` tokenizer Service |

## Versions

Pinned to what llm-d **0.8.1** is tested against (`guides/env.sh` and
`guides/recipes/gateway/install-gateway-crds.sh` at tag `v0.8.1`):

| Component | Version | Notes |
|---|---|---|
| llm-d release | `0.8.1` | chart `version:` field |
| llm-d router chart / EPP image | `v0.9.0` | the 0.8.1 tag already points at v0.9.0 |
| Gateway API | `v1.5.1` | standard channel |
| GAIE | `v1.5.0` | provides `InferencePool` (`inference.networking.k8s.io/v1`) |
| llm-d router CRDs | `v0.9.0` | `InferenceObjective` + `InferenceModelRewrite` (`llm-d.ai/v1alpha2`) — vendored in `crds/` |
| vLLM | `v0.23.0` | serving + `vllm-openai-cpu` render image |

### NVIDIA GPU image choice

The `precise-prefix-cache-routing` guide's `gpu-vllm` component defaults to the
**upstream** `vllm/vllm-openai:v0.23.0` (what `values/modelserver/gpu-vllm.yaml`
uses). llm-d also ships its **own** NVIDIA build, `ghcr.io/llm-d/llm-d-cuda`
(RHEL UBI9, release-matched, with patches not yet upstream + the KV offloading
connector) — use `values/modelserver/gpu-cuda.yaml` for it. Prefer `llm-d-cuda`
on OpenShift/enterprise, for tiered-cache offloading, or when you want the
llm-d-supported image; `vllm/vllm-openai` is the plain upstream default. See
`docs/api-reference/artifacts.md` → *Custom Images* (also `-gb200`, `-aws`
variants).

> ### Note on older guide text
> If you are following a guide that mentions `guides/recipes/scheduler/`, the
> GAIE `standalone`/`inferencepool` charts, `experimentalHttpRoute.enabled`, or
> a `--post-renderer .../uds-tokenizer/post-renderer.sh`, that documentation
> **predates 0.8.1**. Commits `7808df6` (2026-05-21, `scheduler/` → `router/`)
> and `8b1f4d9` (2026-05-27, migration to llm-d's own charts, deleting the UDS
> post-renderer) both landed before `v0.8.1` was tagged on 2026-06-26. The
> chart limitation that post-renderer worked around no longer exists, and the
> UDS tokenizer backend is marked deprecated in the architecture docs.
>
> | Old | 0.8.1 |
> |---|---|
> | `oci://registry.k8s.io/.../charts/inferencepool`, `--version $GAIE_VERSION` | `oci://ghcr.io/llm-d/charts/llm-d-router-gateway`, `--version v0.9.0` |
> | `guides/recipes/scheduler/base.values.yaml` | `guides/recipes/router/base.values.yaml` |
> | `--post-renderer .../uds-tokenizer/post-renderer.sh` | deleted — `token-producer` plugin + render endpoint |
> | `experimentalHttpRoute.enabled=true` | `httpRoute.create=true` |
> | `ghcr.io/llm-d/llm-d-uds-tokenizer:vllm-v0.19.1` | `vllm/vllm-openai-cpu` (`vllm launch render`) |

> **See [RUNBOOK.md](RUNBOOK.md)** for a verified, from-empty-cluster walkthrough
> with the real errors hit along the way and how each was fixed.

## Assumptions

* **Istio is already installed** (via OLM / the Sail operator) and provides the
  `istio` GatewayClass. These charts do not install it:
  `kubectl get gatewayclass istio`.
* NVIDIA GPUs matching `decode.resources`.
* Prometheus Operator, if you enable the monitoring feature.

## Layout

```
offitial-charts/
├── Makefile
├── RUNBOOK.md                          <- verified end-to-end walkthrough
├── scripts/install-crds.sh
├── crds/
│   └── llm-d-router-v0.9.0-crds.yaml   <- vendored, sha256-pinned
├── values/                              <- mirrors the upstream guide layout
│   ├── base.values.yaml                 <- recipes/router/base.values.yaml
│   ├── guides/
│   │   ├── precise-prefix-cache-routing.yaml       (precise only)
│   │   ├── precise-prefix-cache-flowcontrol.yaml   (precise + flow control)
│   │   ├── flow-control.yaml                       (standalone flow control)
│   │   └── cpu-smoke.yaml              (not upstream; small self-contained)
│   ├── features/
│   │   ├── autoscaling-keda.yaml
│   │   ├── httproute-flags.yaml
│   │   ├── monitoring.values.yaml
│   │   ├── tracing.values.yaml
│   │   └── tokenizer-sidecar.yaml
│   ├── gateway/
│   │   └── istio.yaml                   <- recipes/gateway/{base,istio}/
│   └── modelserver/
│       ├── base.values.yaml             <- recipes/modelserver/base/single-host/default/
│       ├── gpu-vllm.yaml                <- decode.spec == patch-vllm.yaml
│       ├── gpu-cuda.yaml                <- same, llm-d-cuda image
│       ├── cpu-vllm.yaml / cpu-preseed.yaml
│       └── cpu-preseed.yaml            (not upstream; offline)
└── charts/
    ├── llm-d-gateway/
    ├── llm-d-router/
    │   ├── Chart.yaml                   <- OCI dep: llm-d-router-gateway v0.9.0
    │   ├── charts/*.tgz                 <- pulled by `make deps`, unmodified
    │   └── values.yaml                  <- pure passthrough; NO templates of its own
    └── llm-d-modelserver/
```

The chart `values.yaml` files hold only neutral defaults. Installed bare, the
router behaves like the stock upstream chart (`default-plugins.yaml`, no
HTTPRoute, no flow control) — all real configuration comes from the layered
`values/` files.

## Install

```bash
export NAMESPACE=llm-d
export HF_TOKEN=hf_xxx

make deps                                       # pull the official OCI chart
./scripts/install-crds.sh                       # once per cluster
make install NAMESPACE=$NAMESPACE HF_TOKEN=$HF_TOKEN
```

Variants:

```bash
make install ... SMOKE=1              # 1 GPU, 1 replica, Qwen3-0.6B
make install ... SIDECAR=1            # render as EPP sidecar, no render Service
make config                           # print the generated EndpointPickerConfig
```

### Manual equivalent

```bash
helm install ppc-gw charts/llm-d-gateway \
  -f values/gateway/istio.yaml -n $NAMESPACE

helm install ppc charts/llm-d-router \
  -f values/base.values.yaml \
  -f values/guides/precise-prefix-cache-flowcontrol.yaml \
  -f values/features/httproute-flags.yaml \
  -n $NAMESPACE

helm install ppc-ms charts/llm-d-modelserver \
  -f values/modelserver/base.values.yaml \
  -f values/modelserver/gpu-vllm.yaml \
  -n $NAMESPACE
```

Release names are independent. The router finds the tokenizer via the **guide
label**, not the release name: `token-producer` defaults its URL to
`http://<guideLabel>-render:8000`, and the modelserver chart names its render
Service `<guideLabel>-render`. Both resolve to
`precise-prefix-cache-routing-render` — identical to what upstream's Kustomize
`namePrefix` produces.

### One config file per topology (no cross-file merge)

The EPP reads a **single** config file (`pluginsConfigFile` selects it), so
precise-prefix and flow-control cannot be layered as two `-f` files — the same
constraint upstream has. Pick one guide file:

| File | What |
|---|---|
| `precise-prefix-cache-routing.yaml` | precise prefix routing only |
| `precise-prefix-cache-flowcontrol.yaml` | precise prefix routing **+** flow control (one combined config) |
| `flow-control.yaml` | standalone flow control (generic prefix scorer, no KV events) |
| `cpu-smoke.yaml` | small self-contained combined config for minikube |

## Values that must agree across charts

These silently produce wrong routing (not errors) if they drift:

| `llm-d-router` | `llm-d-modelserver` | Why |
|---|---|---|
| `router.modelServers.matchLabels."llm-d.ai/guide"` | `guideLabel` | InferencePool selector, **and** the render Service name |
| `router.epp.llmd.model.name` | `model.name` | The tokenizer must tokenize the model actually being served |
| `router.epp.llmd.precisePrefixCache.blockSize` | `decode.kvEvents.blockSize` | Block hashes won't line up; prefix scores become meaningless |
| `router.epp.llmd.precisePrefixCache.kvEvents.socketPort` | `decode.kvEvents.port` | EPP dials the wrong port, gets no KV events |

## CRDs

Three separate bundles, easy to confuse:

| Resource | Group / version | Source |
|---|---|---|
| `Gateway`, `HTTPRoute` | `gateway.networking.k8s.io/v1` | Gateway API `v1.5.1` |
| `InferencePool` | `inference.networking.k8s.io/v1` | GAIE `v1.5.0` |
| `InferenceObjective`, `InferenceModelRewrite` | `llm-d.ai/v1alpha2` | llm-d-router `v0.9.0`, vendored at `crds/` |
| `EndpointPickerConfig` | `llm-d.ai/v1alpha1` | **not a CRD** — an EPP config-file format read from a ConfigMap at startup |

The llm-d-router bundle is that project's own, not part of GAIE, and not
installed by any Helm chart. `InferenceObjective` is what makes the
`x-llm-d-inference-objective` header work — without it, the router's
`inferenceObjectives` fail to apply and every request lands in the default
priority band. `InferenceModelRewrite` (model-name rewriting for canary and
LoRA-adapter rollouts) ships in the same file but is unused here.

```bash
./scripts/install-crds.sh              # vendored copies (default)
./scripts/install-crds.sh --remote     # straight from upstream
./scripts/install-crds.sh fetch        # re-download + print sha256
```

See `crds/README.md`.

## Model server customization (patch-shaped)

`charts/llm-d-modelserver` renders the decode Deployment from a `decode.spec`
block laid out **exactly like the upstream kustomize patch**
(`guides/.../modelserver/gpu/vllm/base/patch-vllm.yaml`). The chart injects only
what the kustomize base + labels transformer inject — metadata, the guide
labels (InferencePool selector), the selector, the pod-template labels, and the
ServiceAccount. Everything under `decode.spec` is passed through **verbatim**,
so you have full kustomize-style control and nothing to un-learn when updating.

```yaml
decode:
  spec:                        # == patch-vllm.yaml `spec:`
    replicas: 8
    template:
      spec:
        containers:
          - name: modelserver
            image: vllm/vllm-openai:v0.23.0
            command: ["vllm", "serve"]
            args: [ Qwen/Qwen3-32B, --tensor-parallel-size=2, --block-size=64, ... ]
            env: [ ... ]        # HF_TOKEN, KV_EVENTS_ENDPOINT, ...
            securityContext:    # run as root, add caps, etc. — your call
              runAsUser: 0
            resources: { ... }
            volumeMounts: [ ... ]
        # anything else you'd put in a pod spec (nodeSelector, tolerations,
        # affinity, imagePullSecrets, priorityClassName, hostNetwork, ...) goes
        # here and renders untouched.
        volumes: [ ... ]
```

Because Helm **replaces** lists rather than merging them, each accelerator
overlay carries a COMPLETE `decode.spec` — exactly as each kustomize overlay
carries a complete `patch-vllm.yaml`. Pick one:

| Overlay | decode.spec |
|---|---|
| `values/modelserver/gpu-vllm.yaml` | NVIDIA GPU, `vllm/vllm-openai:v0.23.0`, 8×TP2 |
| `values/modelserver/gpu-cuda.yaml` | NVIDIA GPU, `ghcr.io/llm-d/llm-d-cuda:v0.8.1` (RHEL UBI9) |
| `values/modelserver/cpu-vllm.yaml` | CPU, download at startup |
| `values/modelserver/cpu-preseed.yaml` | CPU, weights from a node hostPath (offline) |

Chart-owned, structured (separate resources, not part of the pod spec):
`serviceAccount.*`, `render.*`, `monitoring.podMonitor.*`, `autoscaling.keda.*`,
and the `model.label` / `guideLabel` / `accelerator.*` labels.

### Loading the model from an existing PVC

There is no dedicated knob — mount it directly in `decode.spec`, kustomize-style
(the chart never creates a PVC). See
`values/modelserver/model-pvc.example.yaml`:

```yaml
decode:
  spec:
    template:
      spec:
        containers:
          - name: modelserver
            env:
              - { name: HF_HOME, value: /model-cache }
              - { name: HF_HUB_OFFLINE, value: "1" }
            volumeMounts:
              - { name: model-cache, mountPath: /model-cache, readOnly: true }
        volumes:
          - name: model-cache
            persistentVolumeClaim:
              claimName: my-model-pvc   # must already exist
```

A `ReadOnlyMany` PVC holding an HF cache tree (`…/hub/models--org--name/…`) can
back every replica.

## Flow control

`flowControl.priorityBands` must line up with `router.inferenceObjectives`,
rendered as `InferenceObjective` resources:

| Objective | Priority |
|---|---|
| `premium-traffic` | 100 |
| `standard-traffic` | 0 |
| `best-effort-traffic` | -10 |

```bash
curl -X POST http://$IP/v1/completions \
  -H 'x-llm-d-inference-objective: premium-traffic' \
  -H 'x-llm-d-inference-fairness-id: tenant-a' \
  -d '{"model":"Qwen/Qwen3-32B","prompt":"..."}'
```

> **Production**: your ingress must strip client-supplied `x-llm-d-*` headers,
> then inject the authoritative objective/fairness-id from validated token
> claims. Otherwise any caller can promote themselves to `premium-traffic`.

```bash
kubectl logs deploy/ppc-epp -n $NAMESPACE | grep "Flow Control enabled"
kubectl exec deploy/ppc-epp -n $NAMESPACE -- \
  curl -s localhost:9090/metrics | grep llm_d_epp_flow_control_queue_size
```

`maxConcurrency: 132` is upstream's value for 8×Qwen3-32B on 16×H100. Calibrate
for your fleet — see `guides/flow-control/tuning.md` and
`guides/recipes/router/calibration/`.

## Autoscaling (KEDA + EPP metrics)

Port of `guides/workload-autoscaling/keda-epp/`. Composes with precise
prefix-cache routing: the EPP keeps making prefix-aware decisions per request
while KEDA resizes the pool underneath it. Scaling does not disturb the KV
index — new pods are picked up by `discoverPods`, evicted pods' blocks age out.

```bash
make install ... AUTOSCALE=1
```

That layers `values/features/monitoring.values.yaml` (both releases) and
`values/features/autoscaling-keda.yaml` (modelserver), and passes
`autoscaling.keda.eppServiceName=<router release>-epp`.

**The router side is values-only** — nothing in that chart changes. It just
needs `monitoring.prometheus.enabled` so Prometheus has something to scrape,
plus `flowControl` if you want the queue-depth signal.

Prerequisites, neither installed by these charts: **KEDA** and a **Prometheus**
scraping the EPP.

### The two signals

| Metric | Meaning | Needs `flowControl`? |
|---|---|---|
| `llm_d_epp_request_running` | active running requests across the pool | no |
| `llm_d_epp_flow_control_queue_size` | requests waiting for backend capacity | **yes** |

Queue-size is the earlier signal — it rises before saturation reaches
running-requests. But on small clusters it often sits at 0, because requests
are admitted immediately and never queue. Default here is
**running-requests enabled, queue-size disabled**; flip
`triggers[].enabled` once you have confirmed the queue metric actually moves
under your load.

> `autoscaling.keda.eppServiceName` is **required**. The EPP Service is named
> after the *router* release (`ppc` → `ppc-epp`) by the upstream chart, which
> the modelserver chart cannot infer. It fails loudly rather than silently
> querying a Service that does not exist.

## Production install (GPU, EPP + tokenizer in one pod)

Runs the model servers on GPU with production images, and co-locates the
tokenizer as a **sidecar in the EPP pod** (no separate render Service):

```bash
# Gateway
helm upgrade --install ppc-gw charts/llm-d-gateway -n $NS \
  -f values/gateway/istio.yaml

# Router: EPP (HA, 2 replicas) + tokenizer sidecar + flow control
helm upgrade --install ppc charts/llm-d-router -n $NS \
  -f values/base.values.yaml \
  -f values/guides/precise-prefix-cache-flowcontrol.yaml \
  -f values/features/httproute-flags.yaml \
  -f values/features/tokenizer-sidecar.yaml

# Model servers: GPU/vLLM production image, render Service disabled
helm upgrade --install ppc-ms charts/llm-d-modelserver -n $NS \
  -f values/modelserver/base.values.yaml \
  -f values/modelserver/gpu-vllm.yaml \
  -f values/features/tokenizer-sidecar.yaml
```

Produces:

| Component | Image | Where |
|---|---|---|
| EPP | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0` | EPP pod (x2, HA) |
| Tokenizer | `docker.io/vllm/vllm-openai-cpu:v0.23.0` (`vllm launch render`) | **same pod as EPP** |
| Model server | `vllm/vllm-openai:v0.23.0` | GPU decode pods |

All images are production tags (no `-dev`). Point `registry`/`repository` at
your own mirror/air-gapped registry via `-f` or `--set`. The tokenizer stays on
the GPU-less `vllm-openai-cpu` image on purpose — it only tokenizes, so it needs
no GPU and lets the EPP pod schedule on a CPU node; see the note below before
switching it to the full image.

## Tokenization topology: sidecar vs. Service

Precise prefix-cache routing needs **exact token IDs** before it can route: the
KV index is keyed by hashes of 64-token blocks, so the EPP tokenizes every
prompt before scoring, by calling vLLM's `/v1/completions/render`.

Upstream supports both topologies —
`docs/architecture/advanced/kv-management/prefix-cache-aware-routing.md`:

> "…typically a `vllm launch render` **sidecar in the EPP pod** (loopback) **or
> a shared render Service**…"

The chart ships `router.tokenizer.enabled: false`, so upstream picks per guide.
`precise-prefix-cache-routing` — the only well-lit path doing exact
tokenization — chose the **Service**, and these values default to that.

|  | Sidecar | Service (default) |
|---|---|---|
| Moving parts | EPP Deployment only | + Deployment + Service |
| Network | loopback | ClusterIP hop on the TTFT critical path |
| Scaling | pinned 1:1 to EPP replicas | independent of EPP replicas |
| EPP pod footprint | +4 CPU / 8Gi per replica | unchanged |

Sidecar for dev clusters and small fleets; Service once tokenization throughput
and EPP replica count must scale independently. Upstream uses the Service
because it benchmarks at 8 replicas on 16×H100.

```bash
make install ... SIDECAR=1
# or: -f values/features/tokenizer-sidecar.yaml  (on BOTH releases)
```

That profile also pins the sidecar image to `v0.23.0` — the chart's own default
is `v0.19.1`, older than the render Deployment upstream actually uses.

## How the EPP config is supplied

This chart adds **no templates of its own** — it is a pure dependency wrapper.
The EPP configuration is provided the upstream way, through the official
subchart's `router.epp.pluginsCustomConfig` (a map of `filename: <raw config>`)
with `router.epp.pluginsConfigFile` selecting which file is active. The subchart
mounts that ConfigMap and points the EPP `--config-file` at it.

Everything under `llmd:` in these values is passed straight through to
`oci://ghcr.io/llm-d/charts/llm-d-router-gateway`, so the value hierarchy is
**identical to that chart's own** (and to the upstream guide values files),
nested one level under the `llmd` dependency alias. Updating to a new release is
therefore a copy-paste: take the upstream guide's `router:` block, drop it under
`llmd:`. The `.tgz` in `charts/llm-d-router/charts/` is the unmodified upstream
chart.

> Earlier revisions of this wrapper generated the config from a structured
> `eppPlugins.*` block via a custom template. That was removed — it drifted from
> upstream and made version bumps harder. The config is now raw YAML matching
> upstream exactly. Field-level knobs (e.g. `speculativeIndexing`) are edited
> directly in the config string.

## Provenance

| This repo | Upstream |
|---|---|
| `values/base.values.yaml` | `guides/recipes/router/base.values.yaml` |
| `values/guides/precise-prefix-cache-routing.yaml` | `guides/precise-prefix-cache-routing/router/precise-prefix-cache-routing.values.yaml` |
| `values/guides/flow-control.yaml` | `guides/flow-control/router/flow-control.values.yaml` + `guides/flow-control/objectives.yaml` |
| `values/features/*` | `guides/recipes/router/features/*` |
| `values/gateway/istio.yaml` | `guides/recipes/gateway/base/gateway.yaml` + `guides/recipes/gateway/istio/{gateway,configmap,telemetry}.yaml` |
| `values/modelserver/base.values.yaml` | `guides/recipes/modelserver/base/single-host/default/` + `guides/precise-prefix-cache-routing/render/` |
| `values/modelserver/gpu-vllm.yaml` | `guides/precise-prefix-cache-routing/modelserver/gpu/vllm/base/` + `recipes/modelserver/components/images/gpu-vllm/` |
| PodMonitor template | `guides/recipes/modelserver/components/monitoring/decode-podmonitor.yaml` |
| ServiceAccount template | `guides/recipes/modelserver/common/sa.yaml` |
| `scripts/install-crds.sh` | `guides/recipes/gateway/install-gateway-crds.sh` + `guides/env.sh` |

### Deliberate deviations

| Deviation | Why |
|---|---|
| Decode/EPP resources are named `<release>-decode` / `<release>-epp` instead of Kustomize's `precise-prefix-cache-routing-gpu-vllm-*` | Helm release-scoped naming. The **render Service keeps the upstream name** because the router resolves it by guide label |
| PodMonitor selector includes the full decode label set, not just `llm-d.ai/role: decode` | Upstream adds guide labels via a Kustomize `commonLabels` configuration; the chart applies them directly. Stricter, same effect |

### Not from upstream

| Item | Note |
|---|---|
| `Makefile` | Convenience wrapper only — no configuration lives here |
| `values/guides/cpu-smoke.yaml`, `values/modelserver/cpu-*.yaml` | Small-cluster sizing and `maxConcurrency` are **scaled-down guesses**, not upstream-tested. Upstream has no small-cluster profile |
| `decode.spec` passthrough (nodeSelector, tolerations, affinity, …) | Rendered verbatim from your patch-shaped values; nothing chart-specific |
| `charts/llm-d-gateway` values *schema* | Rendered output matches upstream; the values structure around it is new |
