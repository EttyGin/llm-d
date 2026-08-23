# DeepSeek-V4-Flash — P/D Disaggregation + Wide EP + CPU Offloading + P2P KV Sharing

A deployable llm-d guide that composes four upstream well-lit paths into one
stack, packaged as a Helm chart with layered value overrides.

| | |
| --- | --- |
| **Model** | [`deepseek-ai/DeepSeek-V4-Flash-0731`](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731) — 304B MoE, 1M context, ships a DSpark speculative-decoding head |
| **Accelerator** | NVIDIA H100 (80 GB) |
| **Topology** | P/D disaggregated — **8 GPUs prefill**, **4 GPUs decode** |
| **Parallelism** | DEP on both legs: TP=1, DP=EP=8 (prefill) / 4 (decode) |
| **All-to-all** | `deepep_high_throughput` (prefill), `deepep_low_latency` (decode) |
| **MoE backend** | `deep_gemm_mega_moe` |
| **KV transfer** | NIXL (`NixlConnector`) under `MultiConnector` |
| **KV offloading** | CPU tier via `OffloadingConnector`, 88 GiB per DP rank |
| **KV sharing** | Peer-to-peer pull from a peer's CPU tier, port 7777 |
| **Orchestration** | Plain `Deployment`s — **no LeaderWorkerSet** |
| **llm-d release** | v0.9.0 (router chart / EPP `v0.10.0`) |

## What this composes

Four upstream guides, merged into one deployment:

| Upstream guide | What is taken from it |
| --- | --- |
| [`wide-ep-lws` / `vllm-glm-5.2`](../../../guides/wide-ep-lws/modelserver/gpu/vllm-glm-5.2/README.md) | The DEP shape: TP=1, DP=EP, split all-to-all backends (high-throughput prefill / low-latency decode), `deep_gemm` MoE backend, the `OffloadingConnector` CPU tier under `MultiConnector`, and the dual GPU+CPU prefix scoring in the EPP |
| [`wide-ep-lws` / `vllm-deepseek-v4`](../../../guides/wide-ep-lws/modelserver/gpu/vllm-deepseek-v4/README.md) | DeepSeek-V4 engine specifics: `--tokenizer-mode deepseek_v4`, `--enable-ep-weight-filter`, the MegaMoE backend, FP8 KV cache |
| [`pd-disaggregation`](../../../guides/pd-disaggregation/README.md) | The P/D split itself: `always-disagg-pd-decider`, `prefill`/`decode` scheduling profiles, and the routing sidecar in front of the decode engine |
| [`p2p-kv-cache-sharing`](../../../guides/p2p-kv-cache-sharing/README.md) | The P2P secondary tier, `PYTHONHASHSEED=0`, the sidecar's `--enable-p2p-pull`, and the `p2p-source-producer` plugin |

**The deliberate departure from `wide-ep-lws` is LeaderWorkerSet.** Upstream uses
LWS because a DEP group spans nodes. Here each Deployment replica is one
self-contained DP group that fits on a single node, so there is no leader, no
`LWS_GROUP_SIZE`, no supervisor rendezvous, and no LWS controller to install.
Scaling out means `replicas: N` — N independent DP groups the EPP balances
across, not one wider group.

## Request path

```
                 ┌───────────────────────────────────────────────┐
   client ──────▶│ Envoy sidecar (standalone) or Gateway proxy    │
                 └───────────────┬───────────────────────────────┘
                                 │ ext_proc
                        ┌────────▼─────────┐
                        │       EPP        │  1. token-producer renders the prompt
                        │  (llm-d Router)  │     against the prefill pods
                        │                  │  2. prefill profile: GPU+CPU prefix
                        │                  │     scorers pick the prefill pod
                        │                  │  3. p2p-source-producer names a peer
                        │                  │     that out-caches it
                        │                  │  4. decode profile picks the decode pod
                        └────────┬─────────┘
                                 │ headers: prefill target + KV source
                    ┌────────────▼────────────┐
                    │  decode pod :8000       │
                    │  routing-proxy sidecar  │
                    └──────┬───────────┬──────┘
             (a) prefill   │           │  (b) decode
                           ▼           ▼
        ┌──────────────────────┐   ┌──────────────────────┐
        │ prefill pod          │   │ decode engine :8200  │
        │ DP8/EP8, 8x H100     │   │ DP4/EP4, 4x H100     │
        │ deepep_high_thruput  │   │ deepep_low_latency   │
        │                      │   │                      │
        │ CPU tier (shm) ◀─────┼───┼─────▶ CPU tier (shm) │
        │ P2P :7777 ◀──────────┼───┼──────▶ P2P :7777     │
        └──────────┬───────────┘   └──────────────────────┘
                   │ NIXL KV transfer (prompt KV → decode)
                   └──────────────────────▶
```

Three distinct KV movements happen here, and it is worth keeping them apart:

1. **NIXL P/D transfer** — every request ships its prompt KV from the prefill
   pod to the decode pod. Unconditional, on the critical path, and typically
   the topology's throughput ceiling.
2. **CPU offloading** — each pod spills its own KV blocks to a `/dev/shm` mmap
   and reads them back on a later prefix hit. Local to the pod.
3. **P2P pull** — the prefill pod fetches blocks it never computed from
   *another* pod's CPU tier, instead of recomputing them. Cross-pod, and the
   only one of the three that is conditional (it fires when a peer leads by
   `minCachedTokenDelta` cached tokens).

The multi-turn agentic case is where (3) pays: decode generates the session
history, so on the next turn the prefill pod faces KV it never computed and no
routing decision could have made local. `offload_prompt_only: false` is what
makes decode's generated blocks pullable.

## ⚠️ Does it fit? Read this before deploying

**Decode on 4 × H100 does not fit the full-precision checkpoint.** The
configuration is shipped as specified, but here is the arithmetic:

DeepSeek-V4-Flash-0731 is 304B parameters. At FP8 (`F8_E4M3`, the checkpoint's
native serving dtype) that is roughly **304 GB of weights**. Expert weights
shard across EP ranks; dense/attention weights are replicated per rank. Taking
~93% of parameters as experts — typical for a 304B/13B-active MoE, and worth
verifying against the checkpoint's actual shard sizes:

| Leg | EP | Expert shard / GPU | Replicated / GPU | Total / GPU | Usable at util 0.90 | Left for KV + activations |
| --- | --- | --- | --- | --- | --- | --- |
| Prefill | 8 | ~35 GB | ~21 GB | **~56 GB** | 72 GB | ~16 GB ✅ |
| Decode | 4 | ~71 GB | ~21 GB | **~92 GB** | 72 GB | **negative ❌** |

Prefill at DEP8 has room. Decode at DEP4 is over budget before a single KV
block is allocated. Expect `torch.OutOfMemoryError` during weight load.

Three ways out, in order of how little they change:

1. **`-f values/decode-dep8.values.yaml`** — decode on 8 GPUs (DEP8). One line,
   halves the per-rank expert shard to ~35 GB, brings decode in line with
   prefill. Total becomes 16 GPUs.
2. **A quantized checkpoint** — a 4-bit or NVFP4 variant cuts weight memory
   roughly 4×, which does fit DEP4. Note that NVFP4 needs Blackwell tensor
   cores; on H100 the practical option is INT4/AWQ-class quantization, and you
   must re-point `model.name` and re-check `moe.backend` support.
3. **Keep 4 GPUs and accept it will not start** — valid only if you are
   deploying against a smaller model. Change `model.name` and the arithmetic
   changes with it.

Everything else in this guide is independent of that choice. The GPU counts are
values, not structure.

## Prerequisites

* Everything under [`INFRA/README.md`](../../README.md#דרישות-מקדימות) — CRDs
  installed (`scripts/00-install-crds.sh`), `kubectl`/`helm`/`kustomize`.
* **12 H100 GPUs** as specified (8 prefill + 4 decode), or 16 with
  `decode-dep8`. All GPUs of one DP group must be on one node — there is no LWS
  to span nodes.
* Nodes with enough RAM for the CPU tier: the offload region is
  `offloading.cpuBytes` **per DP rank**, so a prefill pod at DP8 with the
  default 88 GiB reserves ~704 GiB of `/dev/shm`. `prefill.dshmSize` and
  `prefill.resources` are sized for that; shrink `cpuBytes` if your nodes are
  smaller.
* ~1 TB of ephemeral storage per pod for the HuggingFace cache (304B of
  weights).
* A HuggingFace token with access to the model.

## Install

```bash
source INFRA/env.sh
export HF_TOKEN=hf_xxx
export NAMESPACE=llm-d-deepseek-v4-flash

# CRDs, once per cluster
./INFRA/scripts/00-install-crds.sh

# The recommended shape: decode on 8 GPUs (see "Does it fit?" above)
MODELSERVER_VALUES="decode-dep8.values.yaml" \
  ./INFRA/guides/deepseek-v4-flash-pd/scripts/install.sh

./INFRA/guides/deepseek-v4-flash-pd/scripts/verify.sh
```

To deploy exactly as specified (4-GPU decode), drop `MODELSERVER_VALUES`.

### What the script does, in Helm terms

```bash
# 1. Router — EPP + InferencePool. Release name MUST be `deepseek-v4-flash`.
helm upgrade --install deepseek-v4-flash \
  oci://ghcr.io/llm-d/charts/llm-d-router-standalone --version v0.10.0 \
  -f INFRA/values/base.values.yaml \
  -f INFRA/guides/deepseek-v4-flash-pd/router/deepseek-v4-flash.values.yaml \
  -n ${NAMESPACE}

# 2. Model servers + render Service.
helm upgrade --install deepseek-v4-flash-modelserver \
  INFRA/guides/deepseek-v4-flash-pd/chart \
  -f INFRA/guides/deepseek-v4-flash-pd/values/decode-dep8.values.yaml \
  -n ${NAMESPACE}
```

The router goes first so the `InferencePool` exists before pods try to join it.
The render Service ships with the model server chart and selects the prefill
pods, so it has endpoints as soon as the first prefill pod is `Ready` — no
ordering step of its own.

### Gateway mode

```bash
export ROUTER_MODE=gateway
export GATEWAY_PROVIDER=agentgateway
./INFRA/scripts/01-install-gateway.sh          # provider control plane + Gateway
MODELSERVER_VALUES="decode-dep8.values.yaml" \
  ROUTER_MODE=gateway ./INFRA/guides/deepseek-v4-flash-pd/scripts/install.sh
```

The Gateway must exist before the router: the chart-created `HTTPRoute`
references `llm-d-inference-gateway` by name. Full comparison in
[`INFRA/docs/GATEWAY-MODE.md`](../../docs/GATEWAY-MODE.md).

## Values layers

The chart's own `values.yaml` is the base. Layer overrides with `-f`; later
files win.

| Layer | Effect |
| --- | --- |
| `values/decode-dep8.values.yaml` | Decode on 8 GPUs (DEP8) instead of 4. **The capacity fix.** |
| `values/offloading-tiered.values.yaml` | Adds an NVMe tier below the CPU tier |
| `values/offloading-off.values.yaml` | NIXL only — no CPU tier, no P2P (also disables it) |
| `values/p2p-disabled.values.yaml` | Keeps CPU offloading, drops the peer pull (control arm) |
| `values/infiniband.values.yaml` | RDMA for multi-node fabrics; requests `rdma/ib` |
| `values/dp-multiport.values.yaml` | Per-rank endpoints + KV events (see below) |
| `values/no-spec-decode.values.yaml` | Turns off the DSpark draft head |
| `values/moe-backend-deep-gemm.values.yaml` | `deep_gemm` instead of `deep_gemm_mega_moe` |
| `values/monitoring.values.yaml` | `PodMonitor` + node-exporter sidecars |

Router side:

| File | Effect |
| --- | --- |
| `router/deepseek-v4-flash.values.yaml` | P/D profiles, dual GPU+CPU prefix scoring, `p2p-source-producer`. **Default.** |
| `router/precise-routing.values.yaml` | Swaps the approximate index for the precise KV-event one. Layer *after* the file above. |

### The one structural choice: DP load-balancing mode

`dp.lbMode` decides how the EPP addresses DP ranks, and it has consequences
well beyond port numbers.

| | `internal` (default) | `multiport` |
| --- | --- | --- |
| API servers | one per pod | one per DP rank |
| Ports exposed | 8000 | 8000..8000+DP-1 |
| Who balances across ranks | vLLM | the EPP |
| Prefill DP ≠ decode DP | fine | **not allowed** |
| KV-cache events | unusable | per-rank, usable |
| Prefix index | approximate | precise |

The constraint that forces the choice: an `InferencePool` carries **one**
`targetPorts` list for the whole pool. In `multiport` mode that list has to
cover both legs, so a DP8 prefill and a DP4 decode would make the EPP invent
four decode endpoints that do not exist. Hence: `multiport` requires equal DP
sizes.

And the reason `internal` cannot use the precise index: vLLM offsets each DP
rank's ZMQ KV-event publisher by the rank number, but with one API server per
pod only rank 0's socket is addressable at the pod IP. The router would index
one eighth of the prefill fleet's cache and score the rest as permanently cold
— worse than not indexing at all. The approximate producers model the cache
from the router's own routing history, which is rank-agnostic and therefore
correct in this mode.

To run precise routing:

```bash
MODELSERVER_VALUES="dp-multiport.values.yaml decode-dep8.values.yaml" \
  PRECISE_ROUTING=true ./scripts/install.sh
```

This also needs an EPP build with per-rank KV-event attribution
([llm-d-router#2233](https://github.com/llm-d/llm-d-router/pull/2233)) and
GAIE ≥ v1.5.0 for multi-`targetPort` InferencePools.

## Parameters that must stay in sync

| Parameter | Where it appears | Consequence of a mismatch |
| --- | --- | --- |
| Model name | `model.name` **and** the router's `token-producer.modelName` | Render calls land on the model servers, so a mismatch is rejected outright — a loud failure, not a silent one |
| Release name | model server `guideName` **and** the router Helm release name | The InferencePool selects nothing; the EPP has no endpoints |
| `kvEvents.blockSize` | engines **and** `tokenProcessorConfig.blockSizeTokens` | No block hash ever matches; the precise index stays empty and every endpoint scores zero |
| `kvEvents.basePort` | engines **and** `podDiscoveryConfig.socketPort` | The router subscribes to a socket nobody publishes on |
| `p2p.port` | engine tier config **and** the sidecar's `--p2p-connector-port` | Pulls are requested and never complete |
| `PYTHONHASHSEED` | every pod, all legs | Block hashes differ per process; **no** P2P lookup ever hits |
| `offloading.cpuBytes` × DP size | must be ≤ `dshmSize` | The mmap fails to allocate at startup |

`PYTHONHASHSEED=0` is set automatically whenever `p2p.enabled`, and it is the
single most silent failure mode in this stack: everything comes up healthy,
pulls are attempted, and nothing ever hits.

## Calibration — do this before trusting the numbers

Two values in the router config are carried over from other hardware and are
**not** calibrated for DeepSeek-V4-Flash on H100:

* **`minCachedTokenDelta: 12288`** — the lead in cached tokens a peer must hold
  before a pull is worth it. It is the measured pull-vs-recompute crossover,
  and it is model-, hardware- and transport-specific (the p2p guide measured
  2,048 on gpt-oss-120b over RDMA and 12,288 on wide-EP GLM-5.2). Measure it:

  ```bash
  guides/recipes/router/calibration/calibrate-min-cached-token-delta.sh
  ```

* **`peakPrefillThroughput: 3585`** (precise routing only) — the gate that
  decides when a cache-warm pod is too saturated to keep receiving affinity
  traffic. Too high and saturated pods never get bypassed; too low and affinity
  never engages.

  ```bash
  guides/recipes/router/calibration/calibrate.sh
  ```

## Verification

```bash
./scripts/verify.sh
```

It checks, in order: pods and the InferencePool, that the render Service has
prefill-only endpoints, that the EPP registered both profiles and the P2P
plugin, a completion through the router, NIXL handoffs in the decode sidecar's
log, and P2P pulls in the prefill engine's log.

An empty P2P section is not a failure — it means no peer led the scheduled pod
by `minCachedTokenDelta`, which is the expected steady state under prefix
affinity. To see pulls, drive a multi-turn workload or lower the delta.

## Images

| Image | Role |
| --- | --- |
| `docker.io/vllm/vllm-openai:v0.27.1` | Both legs. v0.27.1 is the first tagged release with the full `OffloadingConnector` P2P secondary-tier fix set (vllm#48021, #49671, #49823, #49877, #50302). |
| `ghcr.io/llm-d/llm-d-router-disagg-sidecar:main` | Routing sidecar on decode. `main` because v0.9.0's tag predates offloading P2P pull support ([llm-d-router#1937](https://github.com/llm-d/llm-d-router/pull/1937)). |
| `ghcr.io/llm-d/llm-d-router-endpoint-picker:main` | EPP. `main` because the v0.10.0 tag does not register `p2p-source-producer`. |
| `docker.io/envoyproxy/envoy:distroless-v1.33.2` | Standalone-mode sidecar proxy (from the router chart). |
| `quay.io/prometheus/node-exporter:v1.9.0` | Only with `monitoring.values.yaml`. |

> Two of these are floating `main` tags, and both are marked as such in the
> values files. They come straight from the upstream guides, which carry the
> same pins for the same reason. Resolve them to digests before benchmarking —
> results measured against a floating tag are not reproducible.

This guide's images differ from `INFRA/images.txt` (vLLM v0.27.1 vs v0.26.0,
`main` EPP vs v0.10.0), because the P2P tier and its plugin only exist in the
newer builds. Mirror them separately for air-gapped installs.

## Cleanup

```bash
./scripts/uninstall.sh              # both Helm releases + the HF secret
./scripts/uninstall.sh --namespace  # and the namespace
```

## Known deviations from the upstream guides

Stated plainly, because each one is a place where this guide is not the
measured configuration:

1. **No LeaderWorkerSet.** Requested, and it means DP groups cannot span nodes.
   Upstream's multi-node DEP16 configurations have no equivalent here.
2. **`deep_gemm_mega_moe`, not GLM-5.2's `deep_gemm`.** The MegaMoE path is
   what DeepSeek-V4-Flash's own model card and the repo's DeepSeek-V4 recipe
   use. `values/moe-backend-deep-gemm.values.yaml` switches to the GLM value.
3. **Approximate prefix index by default.** The p2p guide measures the pull
   against the *precise* index. Here `dp.lbMode: internal` rules that out; see
   the DP mode section for the reasoning and the opt-in path.
4. **Uncalibrated thresholds.** `minCachedTokenDelta` and
   `peakPrefillThroughput` are carried over from other hardware.
5. **4-GPU decode does not fit the FP8 checkpoint.** See "Does it fit?".
6. **Untested against live hardware.** The manifests render and validate; no
   part of this has been run on a GPU cluster.
