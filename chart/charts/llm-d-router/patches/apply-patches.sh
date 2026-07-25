#!/usr/bin/env bash
# Re-apply the vendored patches to the OCI llm-d-router-gateway tgz.
# Run this AFTER `helm dependency update` (which re-fetches the pristine upstream
# tgz and DISCARDS these patches). See PATCHES.md.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
chartdir="$(dirname "$here")"
tgz="$(ls "$chartdir"/charts/llm-d-router-gateway-*.tgz | head -1)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
tar xzf "$tgz" -C "$work"
top="$(ls "$work")"
# Patch 1: BYO ClusterRole knob in the routerlib RBAC define.
cp -f "$here/routerlib-_rbac.yaml" "$work/$top/charts/router/templates/_rbac.yaml"
( cd "$work" && tar czf "$(basename "$tgz")" "$top" )
cp -f "$work/$(basename "$tgz")" "$tgz"
echo "re-applied patches to $(basename "$tgz")"
