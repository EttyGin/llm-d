#!/usr/bin/env bash
# Removes the guide. Leaves the namespace's CRDs and any Gateway alone.
set -uo pipefail
GUIDE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INFRA_ROOT=$(cd "${GUIDE_DIR}/../.." && pwd)
source "${INFRA_ROOT}/env.sh"
export GUIDE_NAME=deepseek-v4-flash
export NAMESPACE=${NAMESPACE:-llm-d-${GUIDE_NAME}}

helm uninstall "${GUIDE_NAME}-modelserver" -n "${NAMESPACE}"
helm uninstall "${GUIDE_NAME}" -n "${NAMESPACE}"
kubectl delete secret llm-d-hf-token -n "${NAMESPACE}" --ignore-not-found

if [[ "${1:-}" == "--namespace" ]]; then
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found
fi
