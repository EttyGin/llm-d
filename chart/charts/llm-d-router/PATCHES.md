# Vendored patches to `llm-d-router-gateway`

This wrapper depends on the upstream OCI chart `oci://ghcr.io/llm-d/charts/
llm-d-router-gateway`, vendored as `charts/llm-d-router-gateway-*.tgz`. We apply
a small local patch **inside that tgz**, so it is a maintained fork of that one
file — not a pristine passthrough.

> ⚠ **Do NOT run `helm dependency update`/`build` casually.** It re-fetches the
> pristine upstream tgz and **discards these patches**. After a deliberate
> version bump, re-apply with `patches/apply-patches.sh`.

## Patch 1 — bring-your-own EPP ClusterRole
`charts/router/templates/_rbac.yaml` (source of truth: `patches/routerlib-_rbac.yaml`).
Upstream hardcodes the EPP `/metrics`-auth ClusterRole + binding (created when
`router.monitoring.prometheus.enabled=true`, named `<release>-<ns>-epp`) with no
opt-out. The patch adds knobs (surfaced as `llm-d-router.llmd.router.rbac.*`):

| value | default | effect |
|-------|---------|--------|
| `router.rbac.clusterRole.create`        | `true` | **ONE switch.** `false` = create NEITHER the ClusterRole NOR the ClusterRoleBinding (all cluster-scoped RBAC — needs admin). Pre-provision yourself. |
| `router.rbac.clusterRole.existingName`  | `""`   | only used if the chart creates the binding — the ClusterRole name it binds to |
| `router.rbac.clusterRoleBinding.create` | `= clusterRole.create` | advanced override: create the binding even when `clusterRole.create` is false (needs bind permission) |

Everything else (namespaced Role/RoleBinding, EPP SA) is unchanged. Default
render is byte-identical to upstream.

## Bumping the OCI chart version
1. Edit `Chart.yaml` dependency `version:` and `helm dependency update .`
   (from `charts/llm-d-router/`).
2. Review upstream changes to `charts/router/templates/_rbac.yaml`; update
   `patches/routerlib-_rbac.yaml` if it drifted.
3. `patches/apply-patches.sh` to re-apply into the new tgz.
4. `helm template` and diff to confirm.
