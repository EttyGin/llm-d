## llm-d 0.8.1 — Gateway mode, precise prefix-cache routing + flowControl.
##
##   make install NAMESPACE=llm-d HF_TOKEN=hf_xxx
##   make install NAMESPACE=llm-d HF_TOKEN=hf_xxx SMOKE=1     # 1 GPU, Qwen3-0.6B
##   make install NAMESPACE=llm-d HF_TOKEN=hf_xxx SIDECAR=1   # render as EPP sidecar
##   make install NAMESPACE=llm-d HF_TOKEN=hf_xxx AUTOSCALE=1 # KEDA on EPP metrics
##
## The values layering below mirrors the upstream guide install commands:
##   base.values.yaml -> guides/<guide>.yaml -> features/<flag>.yaml

NAMESPACE  ?= llm-d
RELEASE    ?= ppc
HF_TOKEN   ?=
SMOKE      ?=
SIDECAR    ?=
AUTOSCALE  ?=
HELM_EXTRA ?=

HELM := helm --namespace $(NAMESPACE)

# --- values layering -------------------------------------------------------
ROUTER_VALUES := \
  -f values/base.values.yaml \
  -f values/guides/precise-prefix-cache-routing.yaml \
  -f values/guides/flow-control.yaml \
  -f values/features/httproute-flags.yaml

MS_VALUES := \
  -f values/modelserver/base.values.yaml \
  -f values/modelserver/gpu-vllm.yaml

GW_VALUES := -f values/gateway/istio.yaml

ifdef SIDECAR
ROUTER_VALUES += -f values/features/tokenizer-sidecar.yaml
MS_VALUES     += -f values/features/tokenizer-sidecar.yaml
endif

ifdef AUTOSCALE
ROUTER_VALUES += -f values/features/monitoring.values.yaml
MS_VALUES     += -f values/features/monitoring.values.yaml \
                 -f values/features/autoscaling-keda.yaml \
                 --set autoscaling.keda.eppServiceName=$(RELEASE)-epp
endif

# Layered last so they win.
ifdef SMOKE
ROUTER_VALUES += -f values/guides/smoke-test.yaml
MS_VALUES     += -f values/modelserver/smoke-test.yaml
endif

.PHONY: help deps crds namespace secret gateway router modelserver install uninstall \
        template config lint status endpoint smoke

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

deps: ## Pull chart dependencies (official llm-d-router-gateway from OCI)
	helm dependency update charts/llm-d-router

crds: ## Install Gateway API + GAIE + InferenceObjective CRDs
	./scripts/install-crds.sh apply

namespace: ## Create the target namespace
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

secret: ## Create the llm-d-hf-token secret (requires HF_TOKEN=...)
	@test -n "$(HF_TOKEN)" || { echo "HF_TOKEN is required"; exit 1; }
	kubectl create secret generic llm-d-hf-token \
	  --from-literal=HF_TOKEN=$(HF_TOKEN) \
	  --namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

gateway: ## Install/upgrade the Gateway
	$(HELM) upgrade --install $(RELEASE)-gw charts/llm-d-gateway $(GW_VALUES) $(HELM_EXTRA)

router: ## Install/upgrade the Router (EPP + InferencePool + HTTPRoute)
	$(HELM) upgrade --install $(RELEASE) charts/llm-d-router $(ROUTER_VALUES) $(HELM_EXTRA)

modelserver: ## Install/upgrade the model servers (+ render Service)
	$(HELM) upgrade --install $(RELEASE)-ms charts/llm-d-modelserver $(MS_VALUES) $(HELM_EXTRA)

install: namespace secret gateway router modelserver ## Full install (run `make crds` first)
	@echo "Installed. Run 'make status' to watch rollout."

uninstall: ## Remove all releases
	-$(HELM) uninstall $(RELEASE)-ms
	-$(HELM) uninstall $(RELEASE)
	-$(HELM) uninstall $(RELEASE)-gw

template: ## Render everything without installing
	@echo "### gateway";     helm template $(RELEASE)-gw charts/llm-d-gateway     -n $(NAMESPACE) $(GW_VALUES)
	@echo "### router";      helm template $(RELEASE)    charts/llm-d-router      -n $(NAMESPACE) $(ROUTER_VALUES)
	@echo "### modelserver"; helm template $(RELEASE)-ms charts/llm-d-modelserver -n $(NAMESPACE) $(MS_VALUES)

config: ## Print just the generated EndpointPickerConfig
	@helm template $(RELEASE) charts/llm-d-router -n $(NAMESPACE) $(ROUTER_VALUES) \
	  | python3 -c "import sys,yaml; [print(d['data']['plugins.yaml']) for d in yaml.safe_load_all(sys.stdin) if d and d['kind']=='ConfigMap' and 'plugins.yaml' in d.get('data',{})]"

lint: ## Lint all charts
	@for c in charts/*/; do helm lint $$c; done

status: ## Show deployed resources
	kubectl get gateway,httproute,inferencepool,inferenceobjective,deploy,pod -n $(NAMESPACE)

endpoint: ## Print the Gateway address
	@kubectl get gateway llm-d-inference-gateway -n $(NAMESPACE) \
	  -o jsonpath='{.status.addresses[0].value}{"\n"}'

smoke: ## Send a test completion through the Gateway
	@IP=$$(kubectl get gateway llm-d-inference-gateway -n $(NAMESPACE) -o jsonpath='{.status.addresses[0].value}'); \
	MODEL=$$(helm get values $(RELEASE)-ms -n $(NAMESPACE) -a -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["model"]["name"])'); \
	kubectl run curl-smoke-$$RANDOM --rm -i --restart=Never \
	  --image=cfmanteiga/alpine-bash-curl-jq -n $(NAMESPACE) -- \
	  curl -sS -X POST http://$$IP/v1/completions \
	    -H 'Content-Type: application/json' \
	    -H 'x-llm-d-inference-objective: premium-traffic' \
	    -d "{\"model\":\"$$MODEL\",\"prompt\":\"How are you today?\"}"
