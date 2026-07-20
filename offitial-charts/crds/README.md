# Vendored CRDs

Cluster-scoped CRDs these charts depend on. Vendored so an install is
reproducible and auditable without reaching out to GitHub at deploy time.

`scripts/install-crds.sh` applies these local copies by default; pass
`--remote` to fetch from upstream instead.

## Contents

All three are verbatim copies of the pinned upstream releases:

| File | Upstream | sha256 |
|---|---|---|
| `gateway-api-v1.5.1-standard-install.yaml` | `kubernetes-sigs/gateway-api` `v1.5.1` `standard-install.yaml` | `751002b3b91a87f7…` |
| `gaie-v1.5.0-v1-manifests.yaml` | `kubernetes-sigs/gateway-api-inference-extension` `v1.5.0` `v1-manifests.yaml` | `cd7cc63149943627…` |
| `llm-d-router-v0.9.0-crds.yaml` | `llm-d/llm-d-router` `v0.9.0` `manifests.yaml` | `b709d07a856f44fc…` |

Full digests:

```
751002b3b91a87f7ae3bd2517c79a47a8d7ed6702901808a1cf9bd97d284f9b8  gateway-api-v1.5.1-standard-install.yaml
cd7cc63149943627f92d401991886a631d938de28edb416312c443a1b7f42ded  gaie-v1.5.0-v1-manifests.yaml
b709d07a856f44fccdd7289ab35f453c9f284324d70cc07afc9d950225c05d6c  llm-d-router-v0.9.0-crds.yaml
```

## `llm-d-router-v0.9.0-crds.yaml`

This is the **llm-d-router project's own CRD bundle** — it is *not* part of
Gateway API or GAIE, and it is not installed by any of the Helm charts. It
contains two namespaced CRDs, both in group `llm-d.ai`, version `v1alpha2`:

| CRD | Purpose | Used by |
|---|---|---|
| `inferenceobjectives.llm-d.ai` | `spec.priority` + `spec.poolRef`. Maps a request to a flow-control priority band. | **Required** when `eppPlugins.flowControl.enabled: true` |
| `inferencemodelrewrites.llm-d.ai` | `spec.rules` + `spec.poolRef`. Rewrites the model name in the request body — traffic splitting, canary and LoRA-adapter rollouts. | Not used by these charts. Ships in the same bundle |

`InferenceObjective` is what makes the `x-llm-d-inference-objective` header
work. Without this CRD the router chart's `llmd.router.inferenceObjectives`
entries fail to apply, and every request lands in the default priority band.

### Not to be confused with

| Resource | Group | Comes from |
|---|---|---|
| `InferencePool` | `inference.networking.k8s.io/v1` | GAIE `v1.5.0` |
| `Gateway`, `HTTPRoute` | `gateway.networking.k8s.io/v1` | Gateway API `v1.5.1` |
| `InferenceObjective`, `InferenceModelRewrite` | `llm-d.ai/v1alpha2` | **this file** |
| `EndpointPickerConfig` | `llm-d.ai/v1alpha1` | **not a CRD at all** — an EPP config-file format read from a ConfigMap at startup |

### Refreshing

```bash
./scripts/install-crds.sh fetch          # re-download at the pinned version
ROUTER_VERSION=v1.0.0 ./scripts/install-crds.sh fetch
```
