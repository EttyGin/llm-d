#!/usr/bin/env bash
# Namespace + the llm-d-hf-token secret the EPP and model servers read.
#
#   export HF_TOKEN=hf_xxx
#   ./02-namespace-and-secret.sh
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env.sh"

: "${HF_TOKEN:?export HF_TOKEN=<your HuggingFace token> first}"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN}" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "==> secret llm-d-hf-token ready in ${NAMESPACE}"
