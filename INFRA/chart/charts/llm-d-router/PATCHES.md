# Vendored router — patched tgz + two RBAC variants

This wrapper depends on the upstream OCI chart
`oci://ghcr.io/llm-d/charts/llm-d-router-gateway` (**v0.10.0**, the version
llm-d v0.9.0 ships). We vendor it as a tgz and **patch it in place**, so it is a
maintained fork of a handful of templates.

> **Do NOT run `helm dependency update`/`build` casually** — it re-fetches the
> pristine upstream tgz and **discards every patch**. After a deliberate version
> bump, rebuild with `patches/build-variants.sh`.

The build script **asserts each patch target before editing it** and aborts with
`PATCH DRIFT in <file>` if upstream moved. A version bump therefore fails loudly
here instead of silently shipping a half-patched chart.

## Patch 1 — bring-your-own EPP ClusterRole

*File replacement:* `charts/router/templates/_rbac.yaml`
(source of truth: `patches/routerlib-_rbac.yaml`).

Upstream hardcodes the EPP `/metrics`-auth ClusterRole + ClusterRoleBinding
(created when `router.monitoring.prometheus.enabled=true`, named
`<release>-<ns>-epp`) with no opt-out. Both need cluster-admin. The patch adds
one switch, surfaced as `llm-d-router.llmd.router.rbac.*`:

| value | default | effect |
|-------|---------|--------|
| `rbac.clusterRole.create` | *(per variant, below)* | **ONE switch.** `false` = create NEITHER the ClusterRole NOR the binding. Pre-provision them yourself. |
| `rbac.clusterRole.existingName` | `""` | with `create:false`, bind the EPP SA to THIS existing ClusterRole |
| `rbac.clusterRoleBinding.create` | `= clusterRole.create` | advanced: create the binding even when `create:false` (needs bind permission) |

Only those two cluster-scoped objects are affected. The EPP ServiceAccount and
its namespaced Role/RoleBinding are always created in-namespace.

## Patch 2 — `global.llmd.*` identity fan-out

*Additive file:* `charts/router/templates/_identity.tpl`
(source: `patches/routerlib-_identity.tpl`). No upstream counterpart, so it
cannot drift.

Defines the identity helpers the call sites below read. The umbrella writes the
model / guide / gateway **once** in `global.llmd`, and Helm propagates `global`
through every level of the dependency tree — including into a chart that wraps
the umbrella. YAML anchors cannot do this: they resolve inside one file and are
gone the moment a second `-f` is layered.

Precedence is always **explicit local value > `global.llmd.*` > built-in
default**. Nothing here overrides a value someone deliberately set.

## Patch 3 — five anchored call sites

Each is a small, exact replacement applied by `build-variants.sh`:

| # | File | What changes |
|---|------|--------------|
| 3a | `charts/router/templates/_inferencepool.yaml` | InferencePool `selector.matchLabels` reads `llmd.modelServers.matchLabels` (explicit value, else `{guide, model}` from the identity) |
| 3b | `charts/router/templates/_deployment.yaml` | the EPP `--endpoint-selector` flag (standalone path) uses the same helper |
| 3c | `charts/router/templates/_deployment.yaml` | tokenizer sidecar model arg falls back to `global.llmd.model` |
| 3e | `templates/_validations.tpl` | upstream's `matchLabels is required` guard runs BEFORE the fallback would apply — taught to accept a derivable identity |
| 3f | `charts/router/templates/_helpers.tpl` | same for upstream's `tokenizer.modelName is required` guard |
| 3d | `templates/_helpers.tpl` | HTTPRoute gateway name falls back to `global.llmd.gateway` |

3e and 3f are the non-obvious ones: upstream validates the raw values, so
without them a correctly-configured identity still fails the render.

## Two tgz variants (the DEFAULT is baked in)

`patches/build-variants.sh` produces both from one pristine upstream tgz:

| tgz | `rbac.clusterRole.create` default | use it when |
|-----|-----------------------------------|-------------|
| `charts/llm-d-router-gateway-<ver>.tgz` (the active dependency) | `true` — **creates** the RBAC | you have cluster-admin |
| `variants/llm-d-router-gateway-<ver>-byo.tgz` | `false` — **uses existing** | admin-less install; pre-apply `examples/rbac/epp-rbac.yaml` first |

Either variant can still be overridden per-install via the values above.

### Switch to the BYO-by-default variant

```bash
cp charts/llm-d-router/variants/llm-d-router-gateway-<ver>-byo.tgz \
   charts/llm-d-router/charts/llm-d-router-gateway-<ver>.tgz
```

## Bumping the upstream chart version

1. Edit `Chart.yaml` → `dependencies[0].version`.
2. `helm dependency update .` from `charts/llm-d-router/` — re-fetches the
   pristine tgz and **wipes the patches**.
3. `patches/build-variants.sh` — re-applies everything and rebuilds both
   variants. If upstream drifted it stops with `PATCH DRIFT in <file>` and prints
   the text it expected; re-derive that one hunk and update the table above.
4. `helm template` the umbrella and diff against the previous render.

### Drift status at v0.10.0

Checked when moving v0.9.0 → v0.10.0: `_rbac.yaml` was **unchanged** upstream,
so patch 1 applied verbatim. The v0.10.0 chart adds `epp.podAnnotations`,
`tokenizer.extraArgs/initContainers/volumes` and `provider.gke.preferredBackends`
— all additive — and renames the default EPP image from
`llm-d-router-endpoint-picker-dev` to `llm-d-router-endpoint-picker`. The
wrapper pins the image explicitly, so that rename cannot surprise this chart.
