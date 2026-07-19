# llm-d EPP-metrics autoscaling with KEDA (minikube)

End-to-end autoscaling for the vLLM decode deployment, driven by **EPP (inference-scheduler v0.8.0)
metrics** scraped by an in-cluster Prometheus and consumed by **KEDA**. Written for this specific
setup so it can be re-derived without re-discovering everything.

- **Cluster:** minikube, namespace `default`, ~10GB RAM total.
- **EPP:** Helm release `optimized-baseline` (chart `inferencepool` v1.5.0), image
  `ghcr.io/llm-d/llm-d-inference-scheduler:v0.8.0`. Deployment `optimized-baseline-epp`,
  metrics service `optimized-baseline-epp:9090` (port name `http-metrics`).
- **Model:** `qwen-modelservice-llm-d-modelservice-decode` (vLLM CPU), served model name `qwen-0.5b`.
- **Gateway:** Istio, `llm-d-inference-gateway-istio` (`:80`).
- **Prometheus:** plain `prom/prometheus` deployment (NOT the operator — no ServiceMonitor CRDs),
  static config in ConfigMap `prometheus-config`. Runs as the `default` ServiceAccount.
- **KEDA:** already installed; `v1beta1.external.metrics.k8s.io` APIService is Available.

Files added by this work (all under `own/`):
- `metrics-rbac.yaml` — RBAC so the EPP `/metrics` endpoint can be scraped.
- `prometheus.yml` + the `prometheus-config` ConfigMap — adds the `epp-metrics` scrape job.
- `scaledobject.yaml` — the KEDA ScaledObject.

---

## 1. The real metric names (v0.8.0) — and why they seemed "missing"

**The metric names did NOT change between the 0.7.0 docs and v0.8.0.** The names in the docs exist
verbatim on the live endpoint:

- `inference_extension_flow_control_queue_size` — exists.
- `inference_objective_running_requests` — exists.

The reason `curl localhost:9090/metrics | grep flow_control_queue_size` returned **nothing** was
**not** a rename — it was **HTTP 401**. In v0.8.0 the EPP serves `/metrics` behind authentication
(controller-runtime's authn/authz filter → Kubernetes `TokenReview`/`SubjectAccessReview`). A bare
curl gets `401 Unauthorized`, and `grep` on an empty body finds nothing. See §2 for the fix.

### Metrics relevant to autoscaling (read live off the endpoint)

Pool-level aggregates (label `name="optimized-baseline"`, emitted by the single EPP pod):

| Metric | Type | Meaning |
|---|---|---|
| `inference_pool_average_running_requests` | gauge | Avg in-flight requests across pool (EMA, ~15s lag) |
| `inference_pool_average_queue_size` | gauge | Avg requests **waiting** for a backend |
| `inference_pool_average_kv_cache_utilization` | gauge | Avg vLLM KV-cache utilization (0–1) |
| `inference_pool_per_pod_queue_size` | gauge | Per-pod queue depth (label `model_server_pod`) |
| `inference_pool_ready_pods` | gauge | Ready model-server pods |

Objective-level (label `model_name="qwen-0.5b"`):

| Metric | Type | Meaning |
|---|---|---|
| `inference_objective_running_requests` | gauge | In-flight requests for the model (reacts **fast**) |
| `inference_objective_request_total` | counter | Total requests |

Flow-control (label set includes `inference_pool`, `model_name`, `priority`, `fairness_id`):

| Metric | Type | Meaning |
|---|---|---|
| `inference_extension_flow_control_queue_size` | gauge | Requests queued in the flow-control layer |
| `inference_extension_flow_control_queue_bytes` | gauge | Bytes queued |
| `inference_extension_flow_control_pool_saturation` | gauge | Pool saturation (0–1) |

### The key empirical finding (drives the whole trigger design)

Under a burst of **12 concurrent** completions, sampled every 2s:

```
t= 4s  pool_avg_queue=0  pool_avg_running=0   flow_queue=0  obj_running=12  kv_util=0
t=20s  pool_avg_queue=0  pool_avg_running=12  flow_queue=0  obj_running=12  kv_util=0.017
```

**Queue-depth metrics stayed flat at 0.** A single vLLM CPU pod admits all concurrent requests
straight into its running batch (KV util only ~0.017 — nowhere near full), so nothing ever *waits*.
The flow-control / pool queue only grows once demand exceeds what vLLM will admit concurrently, which
light demo load never reaches.

**What actually moves is running requests.** `inference_objective_running_requests` hit 12 within
~4s; `inference_pool_average_running_requests` reached 12 but lagged ~15s (it's an EMA).

Consequence: **queue-depth as the *primary* scaling trigger would never fire here.** So this setup
scales on **running-requests** (primary) and keeps **queue-depth** only as a secondary backpressure
trigger for heavier, real load.

---

## 2. Make `/metrics` scrapeable (RBAC) — `own/metrics-rbac.yaml`

Two grants are needed. The `inferencepool` chart provides **neither**:

1. **Caller** (Prometheus, running as SA `default`) needs `get` on the `/metrics` nonResourceURL.
2. **EPP's own SA** (`optimized-baseline-epp`) needs `system:auth-delegator` so it can *validate*
   incoming tokens via `TokenReview`. Without this, even a valid token yields
   `HTTP 500 "Authentication failed"` and the EPP logs:
   `tokenreviews.authentication.k8s.io is forbidden: User "system:serviceaccount:default:optimized-baseline-epp" cannot create resource "tokenreviews"`.

```bash
kubectl apply -f own/metrics-rbac.yaml
```

Verify from a laptop:
```bash
kubectl port-forward -n default svc/optimized-baseline-epp 19090:9090 &
TOKEN=$(kubectl create token default -n default --duration=1h)
curl -s -H "Authorization: Bearer $TOKEN" localhost:19090/metrics | grep '^inference_pool_'
# 401 -> grant #1 missing; 500 "Authentication failed" -> grant #2 missing; 200 -> good.
```

---

## 3. Prometheus scrape — `own/prometheus.yml`

This Prometheus only scraped `otel-collector` and `jaeger`; it did **not** scrape the EPP at all.
Added a third job (`epp-metrics`) that authenticates with Prometheus's own SA token. The two tracing
jobs are preserved unchanged.

```yaml
- job_name: epp-metrics
  scheme: http                       # controller-runtime metrics filter serves plain HTTP on :9090
  authorization:
    type: Bearer
    credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
  static_configs:
    - targets: ['optimized-baseline-epp:9090']
```

Apply + reload (this Prometheus has no `--web.enable-lifecycle`, so restart the pod):
```bash
kubectl create configmap prometheus-config -n default \
  --from-file=prometheus.yml=own/prometheus.yml --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/prometheus -n default
kubectl rollout status  deploy/prometheus -n default
```

Verify the target is up and metrics landed:
```bash
kubectl port-forward -n default svc/prometheus 19091:9090 &
curl -s 'localhost:19091/api/v1/targets?state=active' | grep -o '"job":"epp-metrics"[^}]*"health":"[a-z]*"'
curl -s 'localhost:19091/api/v1/query?query=inference_pool_average_running_requests'
```
In Prometheus the series carry `job="epp-metrics"`, `instance="optimized-baseline-epp:9090"`,
plus `name="optimized-baseline"` (pool metrics) or `model_name="qwen-0.5b"` (objective metrics).

---

## 4. The ScaledObject — `own/scaledobject.yaml`

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: qwen-decode-epp
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: qwen-modelservice-llm-d-modelservice-decode
  minReplicaCount: 1
  maxReplicaCount: 2          # HARD cap: ~10GB RAM, each vLLM pod ~4GB. Never raise.
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0      # react immediately
          policies: [{type: Pods, value: 1, periodSeconds: 15}]
        scaleDown:
          stabilizationWindowSeconds: 30     # short, so scale-back is observable
          policies: [{type: Pods, value: 1, periodSeconds: 15}]
  triggers:
    - type: prometheus                        # PRIMARY: running requests
      metadata:
        serverAddress: http://prometheus.default.svc.cluster.local:9090
        metricName: epp_pool_running_requests
        query: inference_pool_average_running_requests{name="optimized-baseline"}
        threshold: "3"
    - type: prometheus                        # SECONDARY: queue depth / backpressure
      metadata:
        serverAddress: http://prometheus.default.svc.cluster.local:9090
        metricName: epp_pool_queue_size
        query: inference_pool_average_queue_size{name="optimized-baseline"}
        threshold: "1"
```

### Why each value

- **`minReplicaCount: 1`** — keep the model always warm (vLLM cold start ~100s; scale-to-zero would
  make every first request time out).
- **`maxReplicaCount: 2`** — hard RAM ceiling. ~10GB total, each vLLM pod ~4GB. **Do not raise.**
- **Primary trigger — `inference_pool_average_running_requests`, `threshold: "3"`.** KEDA maps
  `threshold` to the HPA target as an **AverageValue**, so
  `desiredReplicas = ceil(queryValue / threshold)`.
  - Idle: `0/3` → `ceil(0/3)=0` → clamped to `minReplicaCount` = **1**.
  - ~10 in-flight: `10/3` → `ceil ≈ 4` → clamped to `maxReplicaCount` = **2**.
  - Threshold 3 (not 1) avoids scaling on incidental single requests, but >3 concurrent trivially
    triggers — demo-friendly. This is the trigger that actually fires (see §1).
- **Secondary trigger — `inference_pool_average_queue_size`, `threshold: "1"`.** Fires the instant a
  request *waits* for a backend (real backpressure). Stays 0 under demo load. KEDA emits each trigger
  as a separate external metric; the HPA takes the **max** desired across them, so a dormant 0 trigger
  is harmless.
- **`scaleUp.stabilizationWindowSeconds: 0`** — no damping; scale up as soon as the metric crosses.
- **`scaleDown.stabilizationWindowSeconds: 30`** — brief, so scale-back is visible in a demo without
  waiting the 5-min HPA default.
- **`pollingInterval`/`cooldownPeriod` intentionally omitted** — KEDA only honors them when scaling
  to/from zero (`minReplicaCount: 0`). With min=1 the underlying HPA's ~15s sync loop governs cadence;
  setting them just produces a warning.

### KEDA → HPA → Deployment flow

```
EPP /metrics (:9090, auth)
   │  scrape (15s, bearer token)
   ▼
Prometheus (job "epp-metrics")
   │  PromQL query (per trigger)
   ▼
KEDA prometheus scaler  ──registers──▶  external.metrics.k8s.io  (metrics s0-prometheus, s1-prometheus)
   │
   ▼
KEDA creates & owns HPA "keda-hpa-qwen-decode-epp"
   │  desiredReplicas = ceil(metric / threshold), clamped [1,2]
   ▼
Deployment qwen-modelservice-llm-d-modelservice-decode   (spec.replicas 1 ⇄ 2)
```
You manage the **ScaledObject**; KEDA creates/deletes the HPA automatically. Do **not** hand-edit the
`keda-hpa-*` HPA.

Apply + verify readiness:
```bash
kubectl apply -f own/scaledobject.yaml
kubectl get scaledobject qwen-decode-epp -n default          # READY=True
kubectl get hpa keda-hpa-qwen-decode-epp -n default          # created by KEDA
# currentMetrics populated (not <unknown>) after ~1 poll:
kubectl get hpa keda-hpa-qwen-decode-epp -n default -o jsonpath='{.status.currentMetrics}'
```

---

## 5. Trigger and observe scaling

Port-forward the gateway and fire sustained concurrent load:
```bash
kubectl port-forward -n default svc/llm-d-inference-gateway-istio 18080:80 &

# keep ~10 long completions in flight for a couple of minutes
for i in $(seq 1 10); do
  curl -s -m 120 localhost:18080/v1/completions -H 'Content-Type: application/json' \
    -d '{"model":"qwen-0.5b","prompt":"Write an extremely long detailed epic story:","max_tokens":512}' >/dev/null &
done

watch kubectl get hpa,scaledobject,deploy -n default
```

Observed run (this is what "working" looks like):
```
HPA targets=1/3  deploy spec=1          # idle-ish
HPA targets=10/3 deploy spec=2          # metric crossed 3 -> HPA raised replicas 1 -> 2
HPA targets=5/3  deploy spec=2          # settled; EMA ~5, still > 3, holds at 2
```
HPA event:
```
SuccessfulRescale  New size: 2; reason: external metric s0-prometheus above target
```
(`s0-prometheus` = the primary running-requests trigger.)

The **second vLLM pod stays `Pending`**:
```
Unschedulable: 0/1 nodes are available: 1 Insufficient memory.
```
**This is expected and acceptable** — the point is that the HPA *decision* to scale up is observably
made. On ~10GB RAM there isn't room for a second ~4GB vLLM pod.

When load stops, the metric drains to 0 and the HPA scales `2 → 1`, deleting the Pending pod. Note the
scale-down lags ~60–90s because in-flight long generations keep running and the pool metric is an EMA.

---

## 6. Teardown

```bash
kubectl delete -f own/scaledobject.yaml     # removes ScaledObject; KEDA deletes its HPA automatically
```
That returns the deployment to manual replica control (stays at 1). Optional, only if fully reverting:
```bash
# remove the EPP scrape job: restore prometheus.yml to just otel + jaeger, re-apply configmap, restart
# remove RBAC (this re-locks /metrics from scraping):
kubectl delete -f own/metrics-rbac.yaml
```
Leaving the RBAC and scrape job in place is harmless and keeps EPP metrics visible in Prometheus.

---

## 7. Gotchas hit (so future-me doesn't rediscover them)

- **`/metrics` 401, not a metric rename.** v0.8.0 auth-protects `/metrics`. The 0.7.0 metric names
  are unchanged. Fix = the two RBAC grants in §2, then Prometheus scrapes with a bearer token.
- **`500 Authentication failed`** after adding the caller grant = the EPP's own SA lacks
  `system:auth-delegator`. Add the second ClusterRoleBinding.
- **Queue-depth never rises under demo load.** One vLLM CPU pod admits everything into its running
  batch, so scale on **running requests**, not queue depth. (Kept queue depth as a secondary trigger.)
- **`inference_pool_average_running_requests` lags ~15s** (EMA). Fine for HPA (smooths flapping); if
  you want a snappier signal use `inference_objective_running_requests{model_name="qwen-0.5b"}`.
- **2nd pod Pending on RAM** — expected on ~10GB; `maxReplicaCount: 2` is a hard cap, never raise it.
- **Cold start ~100s** — hence `minReplicaCount: 1` (never scale to zero).
- **Benign EPP error** in logs: `extract failed ... metric family "vllm:lora_requests_info" not found`.
  This is harmless — the model server runs without LoRA adapters, so vLLM doesn't emit
  `vllm:lora_requests_info`, and the EPP's core-metrics extractor logs the miss. It does **not** affect
  scheduling, the pool/objective metrics, or autoscaling. Ignore it.
- **Prometheus has no hot reload** (`--web.enable-lifecycle` absent) → `rollout restart` after editing
  the ConfigMap. Brief scrape gap only; tracing jobs resume automatically.
- **Untouched on purpose:** OTel→Jaeger tracing (both scrape jobs preserved), the EPP Flow Control
  config in `own/all-values.yaml`, and the single running vLLM pod. All verified still working after
  the autoscaling changes.
