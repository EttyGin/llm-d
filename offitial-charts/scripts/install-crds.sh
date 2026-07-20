#!/usr/bin/env bash
# Install (or delete) the cluster-scoped CRDs required by these charts.
#
#   ./scripts/install-crds.sh              # install (vendored copies)
#   ./scripts/install-crds.sh --remote     # install straight from upstream
#   ./scripts/install-crds.sh delete       # remove
#   ./scripts/install-crds.sh fetch        # re-download vendored copies
#
# Pinned to the versions llm-d 0.8.1 is tested against (guides/env.sh +
# guides/recipes/gateway/install-gateway-crds.sh).
#
# This script does NOT install Istio — that is assumed to be present already
# (e.g. via OLM / the Sail operator).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRD_DIR="${REPO_DIR}/crds"

# Gateway API (standard channel: GA APIs only — Gateway, HTTPRoute, ...)
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"

# Gateway API Inference Extension — provides InferencePool
# (inference.networking.k8s.io/v1).
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"

# llm-d router's own CRD bundle — provides InferenceObjective and
# InferenceModelRewrite (llm-d.ai/v1alpha2). InferenceObjective is required by
# the flowControl feature gate to map requests to priority bands.
ROUTER_VERSION="${ROUTER_VERSION:-v0.9.0}"

GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
GAIE_URL="https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml"
ROUTER_URL="https://github.com/llm-d/llm-d-router/releases/download/${ROUTER_VERSION}/manifests.yaml"

GATEWAY_API_LOCAL="${CRD_DIR}/gateway-api-${GATEWAY_API_VERSION}-standard-install.yaml"
GAIE_LOCAL="${CRD_DIR}/gaie-${GAIE_VERSION}-v1-manifests.yaml"
ROUTER_LOCAL="${CRD_DIR}/llm-d-router-${ROUTER_VERSION}-crds.yaml"

# apply_bundle <label> <local-path> <remote-url>
# Uses the vendored copy unless --remote was passed or the copy is missing.
apply_bundle() {
  local label="$1" local_path="$2" remote_url="$3"
  echo "==> ${label}"
  if [[ "$REMOTE" -eq 1 ]]; then
    kubectl "$MODE" -f "$remote_url"
  elif [[ -f "$local_path" ]]; then
    echo "    vendored: ${local_path#"$REPO_DIR"/}"
    kubectl "$MODE" -f "$local_path"
  else
    echo "    no vendored copy - falling back to upstream (run '$0 fetch' to vendor)"
    kubectl "$MODE" -f "$remote_url"
  fi
}

MODE="apply"
REMOTE=0
for arg in "$@"; do
  case "$arg" in
    apply|delete|fetch) MODE="$arg" ;;
    --remote)           REMOTE=1 ;;
    *) echo "usage: $0 [apply|delete|fetch] [--remote]" >&2; exit 1 ;;
  esac
done

if [[ "$MODE" == "fetch" ]]; then
  mkdir -p "$CRD_DIR"
  echo "==> Fetching Gateway API ${GATEWAY_API_VERSION}"
  curl -sSL -o "$GATEWAY_API_LOCAL" "$GATEWAY_API_URL"
  echo "==> Fetching GAIE ${GAIE_VERSION}"
  curl -sSL -o "$GAIE_LOCAL" "$GAIE_URL"
  echo "==> Fetching llm-d-router ${ROUTER_VERSION}"
  curl -sSL -o "$ROUTER_LOCAL" "$ROUTER_URL"
  echo
  ( cd "$CRD_DIR" && sha256sum ./*.yaml )
  echo
  echo "Update the sha256 table in crds/README.md if anything changed."
  exit 0
fi

apply_bundle "Gateway API ${GATEWAY_API_VERSION}" "$GATEWAY_API_LOCAL" "$GATEWAY_API_URL"
apply_bundle "Gateway API Inference Extension ${GAIE_VERSION} (InferencePool)" "$GAIE_LOCAL" "$GAIE_URL"
apply_bundle "llm-d router ${ROUTER_VERSION} (InferenceObjective, InferenceModelRewrite)" "$ROUTER_LOCAL" "$ROUTER_URL"

if [[ "$MODE" == "apply" ]]; then
  echo
  echo "==> Verifying"
  for crd in \
    gateways.gateway.networking.k8s.io \
    httproutes.gateway.networking.k8s.io \
    inferencepools.inference.networking.k8s.io \
    inferenceobjectives.llm-d.ai \
    inferencemodelrewrites.llm-d.ai
  do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
      echo "  ok    $crd"
    else
      echo "  MISS  $crd"
    fi
  done
  echo
  echo "==> GatewayClasses available (need 'istio'):"
  kubectl get gatewayclass 2>/dev/null || echo "  (none — is Istio installed?)"
fi
