# CRDs

Cluster-scoped prerequisites, pinned to the versions llm-d v0.9.0 ships.

| File | Release | Provides |
| --- | --- | --- |
| `gateway-api-v1.5.1-standard-install.yaml` | Gateway API `v1.5.1` (standard channel) | `gatewayclasses`, `gateways`, `httproutes`, `grpcroutes`, `referencegrants`, `backendtlspolicies`, `listenersets`, `tlsroutes` |
| `gaie-v1.5.0-v1-manifests.yaml` | Gateway API Inference Extension `v1.5.0` | `inferencepools.inference.networking.k8s.io` (v1) |

Standalone mode needs both: the router chart creates an `InferencePool`, and the
Gateway API CRDs are a hard dependency of the GAIE manifests.

```bash
./scripts/00-install-crds.sh apply --local    # from these files
./scripts/00-install-crds.sh apply            # from GitHub, same pinned versions
./scripts/00-install-crds.sh delete           # careful: cluster-scoped and shared
```
