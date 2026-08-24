# Charts

Pulled from their OCI registries at the versions llm-d v0.9.0 pins. Kept here so
the whole stack can be installed without registry access (`CHART_SOURCE=local`).

| File | Chart | Version | Digest | Installs |
| --- | --- | --- | --- | --- |
| `llm-d-router-standalone-v0.10.0.tgz` | `oci://ghcr.io/llm-d/charts/llm-d-router-standalone` | `v0.10.0` | `sha256:72e2478ffe79d0310bf56aaabc3655ec2028ce6fae809674c826c07a5808936e` | EPP + Envoy sidecar + InferencePool + RBAC + Service |
| `llm-d-router-gateway-v0.10.0.tgz` | `oci://ghcr.io/llm-d/charts/llm-d-router-gateway` | `v0.10.0` | `sha256:20b1c145c78f57ceb48ef9ca6e32fa134263b1e6cbebacb7eadfc9f84f0d9601` | EPP + InferencePool + HTTPRoute + provider extras |
| `agentgateway-crds-v1.1.0.tgz` | `oci://cr.agentgateway.dev/charts/agentgateway-crds` | `v1.1.0` | `sha256:fc90564fd2f37e9dc1aee992d3ace0482906ea37efc3d0a79c13c827dfed90c8` | agentgateway CRDs (gateway mode only) |
| `agentgateway-v1.1.0.tgz` | `oci://cr.agentgateway.dev/charts/agentgateway` | `v1.1.0` | `sha256:f623fe7ee05528eecbfb541ef4cbb03fbd2a4daedb033a72e88884ebd09d0bef` | agentgateway control plane (gateway mode only) |

Both router charts depend on the same bundled `routerlib` subchart, so the
plugin config in `values/precise-prefix-cache-routing.values.yaml` is byte-identical
across modes — the only difference is the data plane.

Verify a chart before use:

```bash
helm show chart charts/llm-d-router-standalone-v0.10.0.tgz
helm template test charts/llm-d-router-standalone-v0.10.0.tgz \
  -f values/base.values.yaml -f values/precise-prefix-cache-routing.values.yaml | less
```
