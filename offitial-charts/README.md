# llm-d 0.8.1 — Helm charts (Gateway mode)

Helm packaging of the llm-d **Precise Prefix Cache Routing** well-lit path, in
**Gateway mode**, with the **`flowControl`** feature gate enabled.

The values tree mirrors the upstream guide layout, so an install reads like the
guide's own `helm install` command:

```bash
helm install ppc charts/llm-d-router \
  -f values/base.values.yaml \
  -f values/guides/precise-prefix-cache-routing.yaml \
  -f values/guides/flow-control.yaml \
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
│   │   ├── precise-prefix-cache-routing.yaml
│   │   ├── flow-control.yaml
│   │   └── smoke-test.yaml              (not upstream)
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
│       ├── gpu-vllm.yaml                <- modelserver/gpu/vllm/base/
│       └── smoke-test.yaml              (not upstream)
└── charts/
    ├── llm-d-gateway/
    ├── llm-d-router/
    │   ├── Chart.yaml                   <- OCI dep: llm-d-router-gateway v0.9.0
    │   ├── charts/*.tgz                 <- pulled by `make deps`, unmodified
    │   └── templates/epp-plugins-configmap.yaml
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
  -f values/guides/precise-prefix-cache-routing.yaml \
  -f values/guides/flow-control.yaml \
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

### Stacking guide overlays

`precise-prefix-cache-routing.yaml` and `flow-control.yaml` compose. **Upstream
cannot do this**: its EPP config is an opaque YAML *string* under
`epp.pluginsCustomConfig`, so a second `-f` replaces the first wholesale. This
chart models the config as structured values under `eppPlugins`, so Helm
deep-merges the overlays and you get precise prefix-cache routing *and* flow
control in one config.

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

## Model server customization

`charts/llm-d-modelserver` exposes the knobs the upstream Kustomize overlay
would require a patch for:

```yaml
serviceAccount:
  create: false          # bind an existing SA instead of creating one
  name: my-existing-sa
  annotations: {}
  automountServiceAccountToken: false

decode:
  # Appended verbatim to `vllm serve`. vLLM takes the last occurrence of a
  # repeated flag, so these also override the generated ones.
  extraArgs:
    - "--max-model-len=32768"
    - "--gpu-memory-utilization=0.92"

  annotations:                       # pod template
    sidecar.istio.io/inject: "false"
  deploymentAnnotations: {}          # Deployment object
  podLabels: {}

  podSecurityContext:                # run as root
    runAsUser: 0
    runAsGroup: 0
    fsGroup: 0
    runAsNonRoot: false
  securityContext:                   # container-level, wins over pod-level
    capabilities:
      add: ["IPC_LOCK"]

  imagePullSecrets:
    - name: my-registry-creds
```

### Loading the model from an existing PVC

`modelCache` mounts a PVC (or hostPath) you already created — the chart **never
creates a PVC**. Weights are read from it instead of downloaded, which is the
clean way to serve on air-gapped or filtered networks, or to share one cached
copy across replicas.

```yaml
modelCache:
  enabled: true
  existingClaim: my-model-pvc    # must already exist in the namespace
  mountPath: /model-cache
  setHfHome: true                # exports HF_HOME=/model-cache
  offline: true                  # HF_HUB_OFFLINE=1 — never hit the network
  readOnly: true                 # a ReadOnlyMany PVC can back every replica
```

The PVC should hold a Hugging Face cache tree (`…/hub/models--org--name/…`).
If it lives in a subdirectory, use `modelCache.subPath` or set `mountPath` so
`<mountPath>/hub` resolves. Set `hostPath` instead of `existingClaim` for a
single-node/dev cluster. Enabling it without either fails the render with a
clear message rather than producing a broken Deployment.

The same `annotations` / `podLabels` / `podSecurityContext` / `securityContext`
/ `imagePullSecrets` keys exist under `render`, plus `render.serviceAnnotations`
for the Service object.

> Annotation values are force-quoted by the templates. Kubernetes requires
> annotation values to be strings, and `--set decode.annotations.foo=false`
> would otherwise render an unquoted YAML bool that the API server rejects.

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

## How the templated config is wired

The upstream chart accepts the `EndpointPickerConfig` only as a pre-rendered
YAML **string** under `router.epp.pluginsCustomConfig`, and Helm cannot template
a subchart's values — so the string cannot be parameterized from here.

Instead this chart renders its own ConfigMap (`llm-d-epp-plugins`) from
`.Values.eppPlugins` and points the EPP at it through the subchart's public
`volumes` / `volumeMounts` / `pluginsConfigFile` hooks:

```yaml
llmd:
  router:
    epp:
      # The upstream chart hardcodes "--config-file /config/<pluginsConfigFile>"
      # and mounts its own ConfigMap at /config. ".." escapes that prefix.
      pluginsConfigFile: "../llmd-plugins/plugins.yaml"
      volumeMounts:
        - { name: llmd-plugins, mountPath: /llmd-plugins, readOnly: true }
      volumes:
        - { name: llmd-plugins, configMap: { name: llm-d-epp-plugins } }
```

Nothing in the subchart is modified — it is the unmodified upstream `.tgz` in
`charts/llm-d-router/charts/`. Set `eppPlugins.enabled: false` and
`pluginsConfigFile: "default-plugins.yaml"` to fall back to stock behavior.

> The `..` in the path is deliberate and load-bearing: `/config` is already
> occupied by the subchart's own ConfigMap mount, so the generated config has
> to live elsewhere and be reached relatively.

### Two value namespaces

| Prefix | Goes to |
|---|---|
| `eppPlugins.*` | this chart — generates the EndpointPickerConfig |
| `llmd.*` | the upstream subchart verbatim (its `router:` / `provider:` / `httpRoute:` nested one level deeper) |


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
| The EPP config comes from a separately-mounted ConfigMap | See [How the templated config is wired](#how-the-templated-config-is-wired). The subchart itself is unmodified |

### Not from upstream

| Item | Note |
|---|---|
| `Makefile` | Convenience wrapper only — no configuration lives here |
| `values/guides/smoke-test.yaml`, `values/modelserver/smoke-test.yaml` | The 1-GPU sizing and `maxConcurrency: 16` / `64,32,8` bands are **scaled-down guesses**, not upstream-tested. Upstream has no small-cluster profile |
| `decode.extraArgs` / `extraEnv` / `nodeSelector` / `tolerations` / `affinity` | Standard Helm escape hatches, empty by default |
| `charts/llm-d-gateway` values *schema* | Rendered output matches upstream; the values structure around it is new |
