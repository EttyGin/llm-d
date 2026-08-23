#!/usr/bin/env bash
# Pull the image set and re-push it into a private registry (air-gapped installs).
#
#   TARGET_REGISTRY=registry.internal/llm-d ./mirror-images.sh
#   TARGET_REGISTRY=... LISTS="images.txt images-gateway.txt" ./mirror-images.sh
#
# After mirroring, point the deployment at the mirror:
#   * model server / render: edit the `images:` entry in the matching
#     manifests/kustomize/recipes/modelserver/components/images/*/release/kustomization.yaml
#   * EPP: helm ... --set router.epp.image.repository=<mirror>/llm-d-router-endpoint-picker
#   * Envoy sidecar: --set router.proxy.image.repository=<mirror>/envoy
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env.sh"

: "${TARGET_REGISTRY:?set TARGET_REGISTRY=<host>/<path>}"
LISTS=${LISTS:-images.txt}
RUNTIME=${RUNTIME:-docker}

for list in ${LISTS}; do
  while read -r image; do
    [[ -z "${image}" || "${image}" =~ ^# ]] && continue
    name=${image##*/}
    target="${TARGET_REGISTRY}/${name}"
    echo "==> ${image}  ->  ${target}"
    "${RUNTIME}" pull "${image}"
    "${RUNTIME}" tag "${image}" "${target}"
    "${RUNTIME}" push "${target}"
  done < "${INFRA_ROOT}/${list}"
done
