#!/usr/bin/env bash
# Rebuild the two vendored router tgz variants from a pristine upstream tgz.
#
#   charts/llm-d-router-gateway-<ver>.tgz         → EPP RBAC created by default
#   variants/llm-d-router-gateway-<ver>-byo.tgz   → uses EXISTING RBAC (create:false)
#
# Both carry the full patch set (see ../PATCHES.md):
#   1. _rbac.yaml           — bring-your-own EPP ClusterRole switch  (file replace)
#   2. _identity.tpl        — global.llmd.* identity fan-out          (file ADD)
#   3. three call sites     — read the identity helpers               (anchored edits)
#
# Every anchored edit ASSERTS its target text first and aborts if upstream
# drifted, so a version bump fails loudly here instead of silently shipping a
# chart with half the patch applied.
#
# Run AFTER `helm dependency update` (which re-fetches the pristine tgz and
# discards everything below).
#
#   ./patches/build-variants.sh [path/to/pristine-upstream.tgz]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
chartdir="$(dirname "$here")"                       # charts/llm-d-router

base="${1:-$(ls "$chartdir"/charts/llm-d-router-gateway-*.tgz 2>/dev/null | grep -v -- -byo | head -1)}"
[[ -f "${base:-}" ]] || { echo "no base tgz found; pass one as \$1" >&2; exit 1; }
ver="$(basename "$base" | sed -E 's/.*-(v[0-9.]+)\.tgz/\1/')"
echo "base: $base (version $ver)"

# Snapshot the pristine base: the first build() overwrites the active
# dependency tgz, which is usually the same path we were handed.
pristine="$(mktemp -d)/base.tgz"
cp -f "$base" "$pristine"
base="$pristine"
trap 'rm -rf "$(dirname "$pristine")"' EXIT

apply_patches() { # $1 = unpacked chart root
  local top="$1"
  local routerlib="$top/charts/router"

  # -- 1. bring-your-own EPP ClusterRole (whole-file replacement) -------------
  cp -f "$here/routerlib-_rbac.yaml" "$routerlib/templates/_rbac.yaml"

  # -- 2. identity helpers (additive; no upstream file is touched) ------------
  cp -f "$here/routerlib-_identity.tpl" "$routerlib/templates/_identity.tpl"

  # -- 3. anchored call-site edits -------------------------------------------
  python3 - "$top" <<'PY'
import sys, pathlib
top = pathlib.Path(sys.argv[1])

def edit(relpath, old, new, label):
    p = top / relpath
    s = p.read_text()
    if new in s:
        print(f"  = {label}: already patched"); return
    if s.count(old) != 1:
        sys.exit(f"PATCH DRIFT in {relpath} ({label}): expected exactly one match, found {s.count(old)}.\n"
                 f"Upstream changed. Re-derive the patch and update PATCHES.md.\n--- expected ---\n{old}")
    p.write_text(s.replace(old, new))
    print(f"  + {label}")

# 3a. InferencePool selector -> identity fallback
edit("charts/router/templates/_inferencepool.yaml",
"""  selector:
    matchLabels:
      {{- if .Values.router.modelServers.matchLabels }}
      {{- range $key, $value := .Values.router.modelServers.matchLabels }}
      {{ $key }}: {{ quote $value }}
      {{- end }}
      {{- end }}""",
"""  selector:
    matchLabels:
      {{- range $key, $value := (include "llmd.modelServers.matchLabels" . | fromYaml) }}
      {{ $key }}: {{ quote $value }}
      {{- end }}""",
"InferencePool selector")

# 3b. EPP --endpoint-selector (standalone mode) -> identity fallback
edit("charts/router/templates/_deployment.yaml",
"""              {{- if and .Values.router.modelServers .Values.router.modelServers.matchLabels }}
                {{- $labels := list }}
                {{- range $k, $v := .Values.router.modelServers.matchLabels }}
                  {{- $labels = append $labels (printf "%s=%s" $k $v) }}
                {{- end }}
                {{- $selector = join "," $labels }}
              {{- end }}""",
"""              {{- $identityLabels := (include "llmd.modelServers.matchLabels" . | fromYaml) }}
              {{- if $identityLabels }}
                {{- $labels := list }}
                {{- range $k, $v := $identityLabels }}
                  {{- $labels = append $labels (printf "%s=%s" $k $v) }}
                {{- end }}
                {{- $selector = join "," $labels }}
              {{- end }}""",
"EPP endpoint selector")

# 3c. tokenizer sidecar model name -> identity fallback
edit("charts/router/templates/_deployment.yaml",
"""            - {{ $tokenizer.modelName | quote }}""",
"""            - {{ $tokenizer.modelName | default (include "llmd.identity.model" .) | quote }}""",
"tokenizer modelName")

# 3e. upstream's own matchLabels guard runs BEFORE our fallback -> teach it
edit("templates/_validations.tpl",
"""{{- if or (empty $.Values.router.modelServers) (not $.Values.router.modelServers.matchLabels) }}
{{- fail ".Values.router.modelServers.matchLabels is required" }}""",
"""{{- if not (include "llmd.modelServers.matchLabels" $ | fromYaml) }}
{{- fail "router.modelServers.matchLabels is required — set it, or set global.llmd.guide so the umbrella can derive it" }}""",
"matchLabels guard")

# 3f. upstream's tokenizer-modelName guard also predates our fallback
edit("charts/router/templates/_helpers.tpl",
"""{{- if and (dig "enabled" false $tokenizer) (not (dig "modelName" "" $tokenizer)) }}
{{- fail ".Values.router.tokenizer.modelName is required when the tokenizer is enabled." }}""",
"""{{- if and (dig "enabled" false $tokenizer) (not (dig "modelName" "" $tokenizer)) (not (include "llmd.identity.model" .)) }}
{{- fail "router.tokenizer.modelName is required when the tokenizer is enabled — set it, or set global.llmd.model." }}""",
"tokenizer modelName guard")

# 3d. HTTPRoute gateway name -> identity fallback
edit("templates/_helpers.tpl",
"""  {{- if .Values.httpRoute.inferenceGatewayName -}}
    {{- .Values.httpRoute.inferenceGatewayName | trunc 63 | trimSuffix "-" -}}""",
"""  {{- $gw := .Values.httpRoute.inferenceGatewayName | default (include "llmd.identity.gateway" .) -}}
  {{- if $gw -}}
    {{- $gw | trunc 63 | trimSuffix "-" -}}""",
"HTTPRoute gateway name")
PY
}

build() { # $1=clusterRole.create default  $2=output tgz
  local create="$1" out="$2" work top
  work="$(mktemp -d)"
  tar xzf "$base" -C "$work"
  top="$work/$(ls "$work")"
  apply_patches "$top"
  # RBAC default baked into the variant.
  yq -i ".rbac.clusterRole.create = $create | .rbac.clusterRole.existingName = \"\"" \
    "$top/charts/router/values.yaml"
  ( cd "$work" && tar czf out.tgz "$(basename "$top")" )
  mkdir -p "$(dirname "$out")"
  cp -f "$work/out.tgz" "$out"
  rm -rf "$work"
  echo "built $out (rbac.clusterRole.create=$create)"
}

build true  "$chartdir/charts/llm-d-router-gateway-$ver.tgz"
build false "$chartdir/variants/llm-d-router-gateway-$ver-byo.tgz"
