#!/usr/bin/env bash
# Build the two router tgz variants from a base upstream tgz:
#   charts/llm-d-router-gateway-*.tgz            → EPP RBAC created by default
#   variants/llm-d-router-gateway-*-byo.tgz      → uses EXISTING RBAC by default (create:false)
# Both get the BYO-ClusterRole template patch (patches/routerlib-_rbac.yaml).
# Run AFTER `helm dependency update` (which re-fetches the pristine upstream tgz).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
chartdir="$(dirname "$here")"                       # charts/llm-d-router
base="${1:-$(ls "$chartdir"/charts/llm-d-router-gateway-*.tgz | grep -v -- -byo | head -1)}"
ver="$(basename "$base" | sed -E 's/.*-(v[0-9.]+)\.tgz/\1/')"
build() { # $1=create  $2=out.tgz
  local create="$1" out="$2" work; work="$(mktemp -d)"
  tar xzf "$base" -C "$work"; local top; top="$(ls "$work")"
  cp -f "$here/routerlib-_rbac.yaml" "$work/$top/charts/router/templates/_rbac.yaml"   # patch 1: template
  yq -i ".rbac.clusterRole.create = $create | .rbac.clusterRole.existingName = \"\"" \
    "$work/$top/charts/router/values.yaml"                                             # patch 2: default
  ( cd "$work" && tar czf out.tgz "$top" ); cp -f "$work/out.tgz" "$out"; rm -rf "$work"
  echo "built $out (clusterRole.create=$create)"
}
mkdir -p "$chartdir/variants"
build true  "$chartdir/charts/llm-d-router-gateway-$ver.tgz"
build false "$chartdir/variants/llm-d-router-gateway-$ver-byo.tgz"
