# INFRA — working notes for Claude

Context for anyone (human or agent) picking up this tree. It is **not** upstream
llm-d documentation: it describes what lives under `INFRA/`, what changed in
llm-d v0.9.0, and the traps that cost real time here.

Placed at `INFRA/CLAUDE.md` rather than the repo root on purpose: `main` in this
fork is force-synced with upstream `llm-d/llm-d`, so anything at the root risks
being clobbered. Everything in this tree is additive to upstream.

---

## 1. What this tree is

`INFRA/` is a self-contained, **version-pinned** deployment kit for llm-d
v0.9.0. Every version is pinned to what tag `v0.9.0` shipped, not to what `main`
currently resolves to — `main` floated `GATEWAY_API_VERSION`, `GAIE_VERSION`,
`ROUTER_CHART_VERSION` and `ROUTER_EPP_VERSION` to `latest` / `v0` / `main`
after the release, so a clone of `main` and a clone of the tag deploy different
software. `INFRA/env.sh` restores the tag's pins.

```
INFRA/
├── env.sh                    all pinned versions; source before anything
├── charts/                   pulled OCI charts (router x2, agentgateway x2)
├── crds/                     Gateway API v1.5.1 + GAIE v1.5.0 manifests
├── values/                   router values layers (base, httproute, monitoring…)
├── manifests/
│   ├── kustomize/            self-contained guides root (precise-prefix + recipes)
│   └── rendered/             kustomize build output; reference/ = helm template
├── scripts/                  ordered 00–05 install path, mirror-images, uninstall
├── docs/                     VERSIONS.md, IMAGES.md, GATEWAY-MODE.md
├── chart/                    ← the UMBRELLA chart (see §5)
└── guides/
    └── deepseek-v4-flash-pd/ P/D + wide-EP + CPU offload + P2P, as a Helm chart
```

Two independent deliverables live here. The **kustomize kit** (`manifests/`,
`scripts/`) mirrors the upstream guides. The **umbrella chart** (`chart/`) is a
Helm-native alternative that wraps the same components. They do not depend on
each other.

---

## 2. Version matrix (v0.9.0)

| Component | Version | Set in |
| --- | --- | --- |
| llm-d release | `v0.9.0` | this tree |
| Gateway API CRDs | `v1.5.1` | `env.sh` |
| GAIE CRDs | `v1.5.0` | `env.sh` |
| Router charts + EPP | **`v0.10.0`** | `env.sh`, `chart/charts/llm-d-router/` |
| vLLM | `v0.26.0` | image components, `global.llmd.vllmVersion` |
| Routing sidecar | `v0.10.0` | image components |
| Envoy sidecar (standalone only) | `distroless-v1.33.2` | router chart default |
| agentgateway | `v1.1.0` | `env.sh` |
| Istio | `1.29.2` | `env.sh` |

**The router component is `v0.10.0` while llm-d is `v0.9.0`.** They are versioned
independently. This is not a typo, and it trips people up every time.

---

## 3. What is actually new in v0.9.0

Substance, not version numbers:

**KV-event replay socket.** vLLM v0.26 binds a second ZMQ socket (ROUTER, port
`5559`) and keeps the last ~10,000 event batches. The router's
`precise-prefix-cache-producer` requests the buffer on first connect or after an
EPP restart, so the KV-block index rebuilds immediately instead of staying cold
until live traffic refills it. Requires `replay_endpoint` in the engine's
`--kv-events-config` **and** `podDiscoveryConfig.replaySocketPort: 5559` on the
router. Missing either one degrades silently — routing still works, it is just
cold after every restart.

**Tokenization moved off the EPP sidecar.** `vllm serve` now exposes
`/v1/completions/render` and `/v1/chat/completions/render`, so the v0.9.0 guides
front the model server pods with a plain Service instead of running a renderer
pool or an EPP sidecar. Render capacity then scales with the serving fleet. This
matters because the render call sits **inside TTFT** — a separately-scheduled
pool saturates before the model servers do. Upstream's chart default for
`router.tokenizer.enabled` is now `false`.

**agentgateway is the preferred self-installed gateway.** `kgateway` and
`kgateway-openshift` are deprecated and slated for removal next release. Both
recipes are still in the tree for migrations only.

**EPP image renamed.** The v0.9.0 chart defaulted to
`ghcr.io/llm-d/llm-d-router-endpoint-picker-dev`; v0.10.0 drops the `-dev`
suffix. Anything relying on the chart default gets a different image.

**New chart values (all additive):** `router.epp.podAnnotations`,
`router.tokenizer.extraArgs` / `.initContainers` / `.volumes`,
`provider.gke.preferredBackends.*`.

**No API migration.** `InferencePool` is `inference.networking.k8s.io/v1` in both
v0.9.0 and v0.10.0 charts — verified by diffing the rendered objects, not
assumed. Upgrading the router does **not** require touching the Gateway.

---

## 4. Why a router needs a tokenizer (asked often)

The EPP routes on prefix reuse: *which pod already holds the KV blocks for this
prompt's prefix?* vLLM keys those blocks by hashing **token IDs**, in groups of
`--block-size`. Not characters — token IDs from that model's vocabulary.

So the EPP must first turn the prompt into exactly the token IDs the engine
would produce, then hash them the same way. The EPP has no tokenizer of its own
(they are model-specific artifacts), so the `token-producer` plugin HTTP-calls a
vLLM render endpoint. Consequences:

* `token-producer.modelName` must equal the served model — a different vocabulary
  produces different IDs, so **every lookup misses silently**;
* the block size on both sides must match — same IDs, different grouping, no hash
  ever lines up;
* render latency is request latency.

**Which plugins need it:** `precise-prefix-cache-producer` and
`p2p-source-producer` — yes. `approx-prefix-cache-producer` — **no**, it models
the cache from the router's own routing history (upstream's `optimized-baseline`
guide runs it with no tokenizer at all). Metric scorers (`queue-scorer`,
`kv-cache-utilization-scorer`, `active-request-scorer`) — no.

---

## 5. The umbrella chart (`chart/`)

One release deploying Router (EPP) + model servers. **Gateway mode only** — it
vendors `llm-d-router-gateway`.

### Identity lives in `global.llmd`, not YAML anchors

The previous version used anchors (`&model` / `*model`). Anchors resolve inside
**one file**, so they die the moment a second `-f` is layered or someone wraps
the chart. Helm propagates `global` through the whole dependency tree, so this
works from a parent chart's values or a bare `--set`:

```yaml
llm-d:
  global:
    llmd:
      model: meta-llama/Llama-3.1-8B-Instruct
      modelLabel: Llama-3.1-8B-Instruct
      guide: my-team-serving
```

Precedence everywhere: **explicit subchart value > `global.llmd.*` > built-in
default**.

### The vendored router is a maintained fork

`chart/charts/llm-d-router/charts/llm-d-router-gateway-v0.10.0.tgz` is patched
in place. Full detail in `chart/charts/llm-d-router/PATCHES.md`. Two patch
families:

1. **bring-your-own EPP ClusterRole** — upstream hardcodes a cluster-scoped
   ClusterRole + binding with no opt-out; both need cluster-admin.
2. **`global.llmd.*` fan-out** — an additive `_identity.tpl` plus five anchored
   call-site edits. Two of those five are upstream's *own* validation guards
   (`matchLabels is required`, `tokenizer.modelName is required`), which read raw
   values and therefore fire before any fallback would apply. Without patching
   them, a correctly-configured identity still fails the render.

`patches/build-variants.sh` **asserts every patch target before editing** and
aborts with `PATCH DRIFT in <file>`, printing the text it expected. A version
bump that drifted fails the build instead of silently shipping half a patch.

### Render modes

`llm-d-modelserver.render.mode`:

| mode | Deploys | |
| --- | --- | --- |
| `service` *(default)* | a Service with **no pods**, fronting the model servers | the v0.9.0 recommendation. A Service is not a workload, so leaving it on costs nothing |
| `standalone` | a GPU-less `vllm launch render` Deployment | **required for SGLang** (no render endpoints). Runs real pods |
| `none` | nothing | when the EPP tokenizes in its own sidecar |

The guards are deliberately asymmetric: `service` is never rejected for being
unused; `standalone` and the EPP sidecar are, because they run containers nobody
would call.

Under P/D, `service` fronts the **prefill** pods — decode's port 8000 belongs to
the routing sidecar, not vLLM. Derived from `prefill.enabled`.

### vLLM args are deliberately not modelled

`decode.spec` / `prefill.spec` render **verbatim** — they are the upstream
kustomize patch `spec:`. The chart does not model tensor parallelism,
kv-transfer configs, all2all backends or MoE flags: those change per model and
per release, and a chart that guessed would be wrong more often than right.

---

## 6. Traps

Ordered by how much time they cost.

**`helm dependency update` wipes the router patches.** It re-fetches the pristine
upstream tgz. Always follow with `patches/build-variants.sh`.

**`helm upgrade` does not inherit values.** Re-supply every `-f` and `--set` from
the original install, or they revert to chart defaults.

**Deployment selectors are immutable.** If pod selector labels change between
chart versions, `helm upgrade` fails and the Deployment must be deleted and
recreated. Verified stable across v0.9.0 → v0.10.0 here; re-check on any future
label change.

**`PYTHONHASHSEED=0` on every P2P peer.** vLLM seeds KV block hashes per process.
Without a shared value no block hash matches across pods and **every** P2P lookup
misses — while everything looks healthy and pulls are attempted.

**`mode: off` is a YAML boolean.** YAML 1.1 parses bare `off` as `false`. Quote
it (`"off"`), or templates comparing it to a string blow up with "incompatible
types for comparison".

**`*/` terminates a Go template comment.** Writing `/v1/*/render` inside
`{{- /* … */ -}}` closes the comment early and produces a parse error pointing at
line 1. Write the paths out, or keep them outside comments.

**Block size and model name must match in two unrelated places each.** The EPP
plugin config is an opaque string and vLLM args are hand-authored, so nothing
can single-source them. `chart/templates/validations.yaml` checks both and fails
the render. Note the block-size key is spelled **both** `blockSize` and
`blockSizeTokens` upstream depending on the guide — the guard matches either
(an earlier version matched only the first and went silently dead).

**EPP Service port 80 was removed** from the umbrella. It pointed at the Envoy
sidecar, which is off in gateway mode, so it resolved to nothing. If anything
targets `<release>-epp:80`, re-add `router.extraServicePorts`.

**Standalone mode is not available in the umbrella.** Setting
`router.proxy.enabled=true` on the vendored *gateway* chart does not work: it has
no proxy image defaults and never emits the Envoy config ConfigMap, so the
sidecar renders unnamed and imageless. Verified. Use `llm-d-router-standalone`
directly (`scripts/03-install-router.sh` with `ROUTER_MODE=standalone`).

**Two floating `main` tags** in `guides/deepseek-v4-flash-pd/`: the EPP (the
v0.10.0 tag does not register `p2p-source-producer`) and the routing sidecar (the
v0.9.0 tag predates offloading P2P pull). Both come from upstream guides carrying
the same pins. Resolve to digests before benchmarking.

---

## 7. `guides/deepseek-v4-flash-pd/` specifics

DeepSeek-V4-Flash-0731 (304B MoE), H100, P/D disaggregated, DEP with TP=1, no
LeaderWorkerSet, CPU offload + P2P. Two things to know:

**4-GPU decode does not fit the FP8 checkpoint.** At EP4 each rank carries ~71 GB
of expert shard plus ~21 GB replicated on an 80 GB card. It OOMs during weight
load. Shipped as specified because that was the requirement; the one-line fix is
`-f values/decode-dep8.values.yaml`. Arithmetic is in that guide's README.

**`dp.lbMode` is the one structural choice.** `internal` (default) gives one port
per pod and allows prefill DP ≠ decode DP, but per-rank KV events are
unreachable, so routing uses the **approximate** index. `multiport` gives
per-rank endpoints and the precise index, but an InferencePool carries one
`targetPorts` list for the whole pool, so prefill and decode DP sizes must match.

---

## 8. Workflows

```bash
# always
source INFRA/env.sh

# cluster prerequisites (once)
./INFRA/scripts/00-install-crds.sh            # --local to use INFRA/crds/

# kustomize kit
./INFRA/scripts/03-install-router.sh          # ROUTER_MODE=standalone|gateway
./INFRA/scripts/04-install-modelserver.sh
./INFRA/scripts/05-verify.sh

# umbrella chart
helm template t INFRA/chart -n ns                       # render
helm template t INFRA/chart -f INFRA/chart/examples/values-precise-prefix-cache-routing.yaml
helm lint INFRA/chart

# bump the vendored router (order matters)
cd INFRA/chart/charts/llm-d-router
$EDITOR Chart.yaml                            # dependencies[0].version
helm dependency update .                      # wipes the patches
./patches/build-variants.sh                   # puts them back, or reports drift

# regenerate rendered manifests after editing kustomize/
kustomize build INFRA/manifests/kustomize/precise-prefix-cache-routing/modelserver/gpu/vllm/base \
  > INFRA/manifests/rendered/01-modelserver-gpu-vllm.yaml

# sync the fork with upstream (fast-forward; it has no commits of its own)
git fetch upstream && git checkout main && git merge --ff-only upstream/main && git push origin main
```

---

## 9. Status

**Verified:** every chart renders (`helm template`, `helm lint` clean); all 14
umbrella examples render; all kustomize overlays build; the identity fan-out was
tested end to end including the wrapping-chart path; the validation guards were
tested against a matrix of good and bad inputs; the v0.9.0 → v0.10.0 comparison
(HTTPRoute identical, InferencePool spec identical, Deployment selectors stable)
was done by diffing actual renders.

**Not verified:** nothing here has been deployed to a GPU cluster. No benchmark
numbers in this tree are reproductions — the two `main` image tags float, so they
could not be reproduced exactly even in principle.

**Calibration values are carried over, not measured.** `minCachedTokenDelta` and
`peakPrefillThroughput` in the deepseek guide come from other hardware. Measure
them with `guides/recipes/router/calibration/` before trusting the routing gates.
