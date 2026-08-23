# Gateway mode — what changes vs standalone

Both modes run the **same EPP with the same routing config**. What differs is
the data plane in front of it.

| | Standalone | Gateway |
| --- | --- | --- |
| Chart | `llm-d-router-standalone` | `llm-d-router-gateway` |
| Data plane | Envoy sidecar **inside** the EPP pod (`docker.io/envoyproxy/envoy:distroless-v1.33.2`) | The Gateway provider's own proxy, outside the pod |
| Entry point | `Service ${GUIDE_NAME}-epp`, port `80` → sidecar `:8081` | `Gateway llm-d-inference-gateway`, `.status.addresses[0].value` |
| `HTTPRoute` | none | created by the chart when `httpRoute.create=true` |
| Extra CRDs | Gateway API + GAIE | same, plus whatever the provider installs |
| Cluster-admin needed | only for the CRDs | CRDs **and** the provider control plane |
| Provider-specific extras rendered | — | Istio: `DestinationRule`; GKE: `GCPBackendPolicy` + `HealthCheckPolicy` |
| Extra images | Envoy | provider control plane + data plane (see [IMAGES.md](./IMAGES.md)) |

## Request path

```
Standalone:  client ──▶ Service :80 ──▶ Envoy sidecar ──ext_proc──▶ EPP ──▶ chosen vLLM pod
Gateway:     client ──▶ Gateway (agentgateway/Istio/GKE) ──ext_proc──▶ EPP ──▶ chosen vLLM pod
                                    │
                              HTTPRoute ──▶ InferencePool ──▶ pods labelled llm-d.ai/guide
```

The routing decision itself — tokenize via the render Service, filter to
cache-warm pods with `prefix-cache-affinity-filter`, score with
`token-load-scorer` — is identical. The Gateway only replaces the hop that asks
the EPP where to go.

## Installing gateway mode

```bash
source INFRA/env.sh
export GATEWAY_PROVIDER=agentgateway          # agentgateway | istio | gke | envoy-ai-gateway
export ROUTER_MODE=gateway

./INFRA/scripts/00-install-crds.sh            # cluster-admin
export HF_TOKEN=hf_xxx
./INFRA/scripts/02-namespace-and-secret.sh
./INFRA/scripts/01-install-gateway.sh         # provider control plane + Gateway object
./INFRA/scripts/03-install-router.sh          # EPP + InferencePool + HTTPRoute
./INFRA/scripts/04-install-modelserver.sh
./INFRA/scripts/05-verify.sh
```

`01-install-gateway.sh` must run before `03-install-router.sh`: the chart-created
`HTTPRoute` references `llm-d-inference-gateway` by name via
`values/httproute-flags.yaml`, and stays un-accepted until that Gateway exists.

## Values layering (gateway mode)

```
values/base.values.yaml                            # shared: EPP resources, proxy args, failureMode
  + values/httproute-flags.yaml                    # httpRoute.create=true, gateway name, requestTimeout 0s
  + values/precise-prefix-cache-routing.values.yaml # the routing plugin chain — the actual guide content
  + --set provider.name=${GATEWAY_PROVIDER}        # provider-specific extras
```

`base.values.yaml` still carries the Envoy `router.proxy.args`; the gateway chart
ignores them since it deploys no sidecar. Harmless, and it keeps a single base
file for both modes.

## Provider notes

* **agentgateway v1.1.0** — the preferred self-installed provider in llm-d v0.9.0.
  On OpenShift apply `recipes/gateway/agentgateway-openshift` instead (drops the
  fixed `runAsUser`, keeps the Service `ClusterIP`).
* **Istio 1.29.2** — the Gateway carries `istio.io/enable-inference-extproc: "true"`
  and a ConfigMap `infrastructure.parametersRef` that tunes the `istio-proxy`
  resources (2–8 CPU, 4–16Gi) and drops log level to `warn`.
* **GKE** — `gke-l7-rilb` (internal) or `gke-l7-regional-external-managed`
  (external). Nothing to install; `provider.name=gke` adds the GCP backend and
  health-check policies.
* **kgateway / kgateway-openshift** — deprecated in llm-d v0.9.0 and slated for
  removal in the next release. Recipes are still in the tree for migrations only;
  do not build on them.

Rendered output for each provider (for review/GitOps) is under
[`../manifests/rendered/reference/`](../manifests/rendered/reference/).
