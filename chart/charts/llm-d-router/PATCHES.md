# Vendored router — patched tgz + two RBAC variants

This wrapper depends on the upstream OCI chart `oci://ghcr.io/llm-d/charts/
llm-d-router-gateway`. We vendor it as a tgz and **patch it directly inside**, so
it is a maintained fork of one template (`charts/router/templates/_rbac.yaml`).

> ⚠ **Do NOT run `helm dependency update`/`build` casually** — it re-fetches the
> pristine upstream tgz and **discards the patch**. After a deliberate version
> bump, rebuild with `patches/build-variants.sh`.

## The patch — bring-your-own EPP ClusterRole
Upstream hardcodes the EPP `/metrics`-auth ClusterRole + ClusterRoleBinding
(created when `router.monitoring.prometheus.enabled=true`, named
`<release>-<ns>-epp`) with no opt-out. The patch (source of truth:
`patches/routerlib-_rbac.yaml`) adds one switch, surfaced as
`llm-d-router.llmd.router.rbac.*`:

| value | default | effect |
|-------|---------|--------|
| `rbac.clusterRole.create` | *(per variant, below)* | **ONE switch.** `false` = create NEITHER the ClusterRole NOR the ClusterRoleBinding (both need cluster-admin). Pre-provision yourself. |
| `rbac.clusterRole.existingName` | `""` | only used if the chart creates the binding |
| `rbac.clusterRoleBinding.create` | `= clusterRole.create` | advanced: create the binding even when `create:false` (needs bind permission) |

Only those two cluster-scoped objects are affected. The EPP ServiceAccount and
its namespaced Roles/RoleBindings are always created in-namespace (no admin).

## Two tgz variants (the DEFAULT is baked in)
`patches/build-variants.sh` produces both from a base upstream tgz:

| tgz | `rbac.clusterRole.create` default | use it when |
|-----|-----------------------------------|-------------|
| `charts/llm-d-router-gateway-<ver>.tgz` (active dependency) | `true` — **creates** the RBAC | you have cluster-admin |
| `variants/llm-d-router-gateway-<ver>-byo.tgz` | `false` — **uses existing** | admin-less install; pre-apply `examples/rbac/epp-rbac.yaml` first |

Either variant can still be overridden per-install via the values above.

### Switch to the BYO-by-default variant
```bash
cp charts/llm-d-router/variants/llm-d-router-gateway-<ver>-byo.tgz \
   charts/llm-d-router/charts/llm-d-router-gateway-<ver>.tgz
```
(then `helm template`/`install` — no values needed).

## Bumping the OCI chart version
1. `Chart.yaml` dependency `version:` → `helm dependency update .` (from `charts/llm-d-router/`).
2. Review upstream `charts/router/templates/_rbac.yaml`; update `patches/routerlib-_rbac.yaml` if it drifted.
3. `patches/build-variants.sh` — rebuilds BOTH tgz variants.
4. `helm template` and diff to confirm.
