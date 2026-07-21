# RUNBOOK — from an empty cluster to a working stack

Every command below was **actually run** on minikube (8 CPU / 12 GiB,
Kubernetes v1.35.1) on 2026-07-21. Where something broke, the real error text
is included along with the fix.

Read [Status of this run](#status-of-this-run) first — one step did not
complete, for an environmental reason.

---

## 0. Prerequisites

| Tool | Used here |
|---|---|
| minikube | running, 8 CPU / 12 GiB |
| kubectl | v1.35.1 |
| helm | v3.17.2 |
| Network egress | to ghcr.io, registry.k8s.io, docker.io, **huggingface.co and its CDN** |

That last row is not a formality. See [Step 7](#7-where-this-run-stopped).

```bash
cd offitial-charts
export NAMESPACE=llm-d
```

---

## 1. Chart dependencies

`charts/llm-d-router` declares the **official** llm-d chart as an OCI
dependency. Pull it before anything else:

```bash
make deps
# helm dependency update charts/llm-d-router
# -> Pulled: ghcr.io/llm-d/charts/llm-d-router-gateway:v0.9.0
# -> Digest: sha256:60f4533be587496faee9eb24a3ad8f91f4efda49b7800ee200a1d918d9aba54b
```

Creates `charts/llm-d-router/charts/llm-d-router-gateway-v0.9.0.tgz` and
`Chart.lock`. Both are committed, so this step is only needed after a version
bump.

**Where it falls over:** if your shell has a broken helm plugin you will see
`failed to load plugins: ...` on every helm command. It is noise, not a
failure — helm still works. (Seen on this machine with `helm-diff`.)

---

## 2. CRDs

```bash
./scripts/install-crds.sh
```

Applies the three vendored, sha256-pinned bundles from `crds/`:

```
==> Gateway API v1.5.1
    vendored: crds/gateway-api-v1.5.1-standard-install.yaml
==> Gateway API Inference Extension v1.5.0 (InferencePool)
    vendored: crds/gaie-v1.5.0-v1-manifests.yaml
==> llm-d router v0.9.0 (InferenceObjective, InferenceModelRewrite)
    vendored: crds/llm-d-router-v0.9.0-crds.yaml

==> Verifying
  ok    gateways.gateway.networking.k8s.io
  ok    httproutes.gateway.networking.k8s.io
  ok    inferencepools.inference.networking.k8s.io
  ok    inferenceobjectives.llm-d.ai
  ok    inferencemodelrewrites.llm-d.ai
```

**Where it falls over:** if `inferenceobjectives.llm-d.ai` is missing, the
router chart's `InferenceObjective` resources fail to apply and **every request
silently lands in the default priority band** — flow control appears to do
nothing. That CRD is not part of GAIE; it only ships in the llm-d-router
bundle.

---

## 3. Istio

The charts assume Istio already exists (the task said OLM; here it is Helm —
all the chart needs is the `istio` GatewayClass).

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

helm upgrade --install istio-base istio/base -n istio-system \
  --create-namespace --version 1.30.3 --wait

helm upgrade --install istiod istio/istiod -n istio-system --version 1.30.3 \
  --set pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
  --wait --timeout 6m
```

Verify — **do not continue until this shows `istio` with `ACCEPTED=True`**:

```bash
kubectl get gatewayclass
# istio          istio.io/gateway-controller   True
# istio-remote   istio.io/unmanaged-gateway    True
```

**Where it falls over:**

* `ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true` is what lets Istio resolve an
  `InferencePool` as an HTTPRoute `backendRef`. Without it the HTTPRoute gets
  `ResolvedRefs=False` and traffic never reaches the EPP.
* Install the CRDs (step 2) **before** istiod, or istiod will not register the
  Gateway API controller on first boot.

---

## 4. KEDA and Prometheus

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install keda kedacore/keda -n keda --create-namespace --wait

helm upgrade --install prom prometheus-community/kube-prometheus-stack -n monitoring \
  --create-namespace \
  --set grafana.enabled=false --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus-node-exporter.enabled=false --set kubeStateMetrics.enabled=false \
  --wait --timeout 8m
```

**Where it falls over:** the two `...SelectorNilUsesHelmValues=false` flags are
mandatory. By default kube-prometheus-stack only picks up ServiceMonitors
carrying its own release label, so the chart's `ServiceMonitor` is created,
looks healthy, and is silently never scraped. KEDA's HPA then reports
`<unknown>` forever.

---

## 5. Namespace and HF token

```bash
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
```

For a **public** model, do not create a token secret — set
`hfTokenSecret.enabled: false` (the CPU overlay already does).

> **Do not put a placeholder value in the secret.** An invalid `HF_TOKEN` is
> worse than none: `huggingface_hub` sends it as `Authorization: Bearer …`, and
> the weights download stalls at a 0-byte `.incomplete` blob with no error. The
> pod sits at `Starting to load model` forever. This cost real time in this run.

For a gated model:

```bash
kubectl create secret generic llm-d-hf-token -n $NAMESPACE \
  --from-literal=HF_TOKEN="$HF_TOKEN"
```

---

## 6. The three charts

```bash
# Gateway
helm upgrade --install ppc-gw charts/llm-d-gateway -n $NAMESPACE \
  -f values/gateway/istio.yaml

# Router (EPP + InferencePool + HTTPRoute + InferenceObjectives)
helm upgrade --install ppc charts/llm-d-router -n $NAMESPACE \
  -f values/base.values.yaml \
  -f values/guides/precise-prefix-cache-routing.yaml \
  -f values/guides/flow-control.yaml \
  -f values/features/httproute-flags.yaml \
  -f values/features/monitoring.values.yaml \
  -f values/guides/cpu-smoke.yaml

# Model servers + render + ScaledObject
helm upgrade --install ppc-ms charts/llm-d-modelserver -n $NAMESPACE \
  -f values/modelserver/base.values.yaml \
  -f values/modelserver/cpu-vllm.yaml \
  -f values/features/monitoring.values.yaml \
  -f values/features/autoscaling-keda.yaml \
  --set autoscaling.keda.eppServiceName=ppc-epp \
  --set autoscaling.keda.prometheus.serverAddress=http://prom-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090 \
  --set autoscaling.keda.maxReplicas=3
```

### Three failures hit here, all now fixed in the values

**6a. Duplicate Service port — install aborted**

```
Error: Service "ppc-epp" is invalid: spec.ports[3]: Duplicate value:
{"Name":"","Protocol":"TCP","Port":9090,...}
```

Router chart v0.9.0's `_service.yaml` **always** emits `http-metrics` on 9090.
Upstream's own `guides/flow-control/router/flow-control.values.yaml` adds a
second `metrics` port on 9090 via `extraServicePorts`, which collides. This is
an upstream bug; `values/guides/flow-control.yaml` here deliberately omits it.

**6b. Decode pod Pending forever**

```
0/1 nodes are available: 1 Insufficient memory, 1 Insufficient nvidia.com/gpu.
```

**Helm merges maps, it does not replace them.** The chart's default
`decode.resources` carries `nvidia.com/gpu: 1`, which survives into a CPU
overlay unless explicitly nulled:

```yaml
decode:
  resources:
    requests:
      nvidia.com/gpu: null
    limits:
      nvidia.com/gpu: null
```

**6c. Old ReplicaSet pods wedge the rollout**

With `replicas: 1` and the default RollingUpdate strategy, `maxUnavailable`
resolves to 0, so the old ReplicaSet stays at 1 until the new pod is Ready. On
a memory-tight node the new pod then cannot schedule — deadlock. Clear it:

```bash
kubectl delete rs -n $NAMESPACE <old-rs> --cascade=foreground
```

---

## 7. Verification

### Gateway and route

```bash
kubectl get gateway -n $NAMESPACE -o jsonpath='{.items[0].status.conditions[?(@.type=="Programmed")].status}'
# True

kubectl get httproute -n $NAMESPACE -o jsonpath='{.items[0].status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'
# True     <- proves Istio resolved the InferencePool backendRef
```

### EPP loaded the generated config

```bash
kubectl logs -n $NAMESPACE deploy/ppc-epp -c epp | head -5
```

Observed:

```
"msg":"GIE build","build-ref":"v0.9.0"
"config-file":"/config/../llmd-plugins/plugins.yaml"
"msg":"Loaded raw configuration","config":"{FeatureGates: {flowControl}, Plugins: [
  {Type: token-producer, Parameters: {"modelName":"Qwen/Qwen2.5-0.5B-Instruct",
     "vllm":{"url":"http://precise-prefix-cache-routing-render:8000"}}}
  {Type: endpoint-notification-source}
  {Type: precise-prefix-cache-producer, Parameters: {...,"tokenProcessorConfig":{"blockSize":64}}}
  {Type: prefix-cache-scorer, Parameters: {"prefixMatchInfoProducerName":"precise-prefix-cache-producer"}}
  {Type: no-hit-lru-scorer, ...} {Type: round-robin-fairness-policy}
  {Type: fcfs-ordering-policy} {Type: concurrency-detector, ...}],
  FlowControl: {MaxRequests: 1000, PriorityBands: [{Priority: 100, MaxRequests: 32}, ...]}}"
"msg":"Data layer: ENABLED"
"msg":"Starting sharded event processing pool","workers":8
```

This confirms end-to-end: the `..` path escape works, `flowControl` is gated
on, the precise-prefix producer is wired to the scorer, the render URL resolved
from the guide label, and the KV-event ZMQ pool started.

### Autoscaler chain

```bash
kubectl get scaledobject,hpa -n $NAMESPACE
```

```
scaledobject.keda.sh/ppc-ms-decode   ...  READY=True   ACTIVE=False
hpa/keda-hpa-ppc-ms   Deployment/ppc-ms-decode   0/16 (avg)   1   3   1
```

`0/16` rather than `<unknown>` is the thing to look for: KEDA reached
Prometheus and got a number. `ACTIVE=False` is correct with no traffic.

Flow-control metrics confirmed live on the EPP:

```
llm_d_epp_flow_control_pool_saturation
llm_d_epp_flow_control_dispatch_cycle_duration_seconds
llm_d_epp_ready_endpoints
llm_d_epp_info
```

`llm_d_epp_request_running` and `llm_d_epp_flow_control_queue_size` only appear
once requests actually flow — an empty Prometheus result for them before any
traffic is expected, not a fault.

---

## Status of this run

| Step | Result |
|---|---|
| Chart dependency from official OCI | ✅ verified |
| CRDs (all 5) | ✅ verified |
| Istio + `istio` GatewayClass | ✅ verified |
| KEDA + Prometheus | ✅ verified |
| Gateway `Programmed=True` | ✅ verified |
| HTTPRoute `ResolvedRefs=True` (InferencePool resolved) | ✅ verified |
| EPP running, generated config loaded, `flowControl` on | ✅ verified |
| All 10 plugins instantiated, weights 2/2/3/2 | ✅ verified |
| KV-event ZMQ pool started (8 workers) | ✅ verified |
| render (tokenizer) Service Ready | ✅ verified |
| Prometheus scraping EPP | ✅ verified |
| KEDA → Prometheus → HPA reading a real value | ✅ verified |
| vLLM accepts `--block-size 64` + KV events on CPU | ✅ verified |
| Model weights loaded (via pre-seed) | ✅ verified |
| **Inference served through the Gateway (HTTP 200)** | ✅ **verified** |
| EPP subscribed to the pod's ZMQ KV socket (`tcp://<pod>:5556`) | ✅ verified |
| **Autoscaler scaled up on live EPP load** (desired 1→2→3) | ✅ **verified** |

### The network hurdle (and how it was cleared)

This network runs a **Netspark / etrog content filter that TLS-intercepts and
blocks the Hugging Face weights CDN**. The main site is untouched, but every
weights fetch 302-redirects to `us.aws.cdn.hf.co`, whose cert is issued by
`O = Netspark, CN = www.netspark.com`, and the appliance returns an **HTTP 200
787-byte HTML block page** instead of the file. vLLM then dies at init with:

```
httpx.ConnectError: [SSL: CERTIFICATE_VERIFY_FAILED] self-signed certificate in certificate chain
...later, after trusting the CA...
OSError: Consistency check failed: file should be of size 988097824 but has size 787
```

Three things were needed, all now expressed as chart values / overlays:

**7a. HF token must be real or absent, never a placeholder.** A dummy token
stalls the download at a 0-byte blob. `hfTokenSecret.enabled: false` for public
models (the CPU overlay sets it).

**7b. Trust the network CA** so httpx TLS verification passes
(`values/features/network-ca.yaml` + a `network-ca-bundle` ConfigMap). This
alone was not enough here — the in-image `huggingface_hub` ignores
`HF_HUB_DISABLE_XET` and still pulls from the blocked Xet CDN, so it downloaded
the 787-byte block page and failed the size check.

**7c. Pre-seed the weights** past the filter. A throwaway pod with a *current*
`huggingface_hub` (which honours `HF_HUB_DISABLE_XET` and reaches the
un-blocked classic CDN) downloads the model to a node `hostPath`; the decode
pod then mounts it and runs offline. This is what the new
`extraVolumes` / `extraVolumeMounts` chart knobs are for.

```bash
# seed once (node hostPath /data/hf-models, HF_HOME=/data/hf inside)
kubectl run hf-seed ... snapshot_download('Qwen/Qwen2.5-0.5B-Instruct')
# then layer the pre-seed overlay AFTER cpu-vllm.yaml
helm upgrade ppc-ms ... -f values/modelserver/cpu-preseed.yaml
```

`values/modelserver/cpu-preseed.yaml` mounts the node dir at `/hf-home`, sets
`HF_HOME=/hf-home/hf` (note the `hf` subdir the seed's `HF_HOME` created) and
`HF_HUB_OFFLINE=1`. With that, decode loaded weights in ~60s and went Ready.

> **Two Helm-list gotchas hit here.** `decode.extraEnv` and `decode.extraVolumes`
> are lists, and Helm **replaces** lists — it does not merge them. Layering a
> second `-f` that also sets `extraEnv` silently drops the first set. Keep all
> `extraEnv` entries in one file. `values/features/network-ca.yaml` documents
> this and deliberately puts the CA env vars in the CPU overlay instead.

**7d. Fit the CPU worker in memory.** On a 12 GiB node the worker was OOM-ish at
init (`WorkerProc initialization failed`, exit 1). `VLLM_CPU_KVCACHE_SPACE=1`
and `--max_model_len=2048` (down from upstream's 32 / 8192) bring total usage
under the 6 GiB limit.

### What "it works" looked like

```bash
curl -s -X POST http://<gateway>/v1/completions -d '{
  "model":"Qwen/Qwen2.5-0.5B-Instruct","prompt":"The capital of France is","max_tokens":10}'
# HTTP 200
# {"choices":[{"text":" ______.\nA. Paris\nB. London\n"}], ... }
```

EPP subscribed to the pod's KV socket:

```
"logger":"zmq-subscriber","msg":"Connected subscriber socket","endpoint":"tcp://10.244.0.29:5556"
```

Autoscaler acted on live load (threshold temporarily lowered to 2 to force it
under a small model's fast completions):

```
llm_d_epp_request_running{...} 22          # live EPP metric under load
t=15s | cur= rep=1 desired=2 | decode_pods=2   # HPA raised desiredReplicas, new pod created
```

The 2nd/3rd replicas stayed `Pending` (a single 12 GiB node has no room for
another CPU vLLM) — the **scaling decision and pod creation** are the proof, not
their placement. Restoring `threshold: 16` settles the pool back to 1.

> **Note on the prefix scorer with one pod / short prompts.** The EPP logs
> `PrefixCacheMatchInfo not found ... assigning score 0`. That is expected here:
> KV-cache blocks are hashed per 64 tokens, the smoke prompts are shorter than
> one block, and with a single decode pod there is no second endpoint to score
> against. Differential prefix routing needs ≥2 pods and prompts spanning
> multiple blocks — a benchmark, not a smoke test. The integration itself (EPP
> reading `CacheBlockSize:64 CacheNumBlocks:1365` from the pod, ZMQ subscribed)
> is proven.

## Teardown## Teardown

```bash
helm uninstall ppc-ms ppc ppc-gw -n $NAMESPACE
kubectl delete ns $NAMESPACE
helm uninstall prom -n monitoring; helm uninstall keda -n keda
helm uninstall istiod istio-base -n istio-system
./scripts/install-crds.sh delete
```
