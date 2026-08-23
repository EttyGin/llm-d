# Version matrix — llm-d v0.9.0

Everything below is taken from tag `v0.9.0` of this repo (`git show v0.9.0:guides/env.sh`
and the `release` image components), not from `main`.

> `main` has since floated `GATEWAY_API_VERSION`, `GAIE_VERSION`, `ROUTER_*_VERSION`
> to `latest` / `v0` / `main`. `INFRA/env.sh` restores the v0.9.0 pins, so this
> tree keeps deploying the same thing after upstream moves.

| Component | Version at v0.9.0 | Where it is set |
| --- | --- | --- |
| llm-d release | `v0.9.0` | this tree |
| Gateway API CRDs | `v1.5.1` | `env.sh` → `GATEWAY_API_VERSION` |
| Gateway API Inference Extension (GAIE) CRDs | `v1.5.0` | `env.sh` → `GAIE_VERSION` |
| llm-d Router chart (`llm-d-router-standalone` / `llm-d-router-gateway`) | `v0.10.0` | `env.sh` → `ROUTER_CHART_VERSION` |
| llm-d Router EPP image | `v0.10.0` | chart default / `ROUTER_EPP_VERSION` |
| llm-d Router release (CRDs, flow-control only) | `v0.10.0` | `env.sh` → `ROUTER_RELEASE_VERSION` |
| vLLM (model server + render) | `v0.26.0` | `components/images/gpu-vllm/release` |
| Envoy sidecar (standalone mode) | `distroless-v1.33.2` | router chart default |
| agentgateway (gateway mode) | `v1.1.0` | `docs/infrastructure/gateway/agentgateway.md` |
| Istio (gateway mode) | `1.29.2` | `docs/infrastructure/gateway/istio.md` |

The router component version (`v0.10.0`) is intentionally ahead of the llm-d
release version (`v0.9.0`) — they are versioned independently.

## Why `v0.26.0` of vLLM matters here

The GPU vLLM backend at v0.26.0+ binds a ZMQ ROUTER socket on port `5559` and keeps
the last 10,000 KV-event batches in a replay buffer. The router's
`precise-prefix-cache-producer` uses that on first connect (or after an EPP
restart) to rebuild its KV-block index without waiting for live traffic. Older
vLLM images publish events on `5556` but cannot replay.

## Client tooling minimums

| Binary | Minimum |
| --- | --- |
| `kubectl` | v1.28.0+ |
| `helm` | v3.12.0+ |
| `kustomize` | v5.0.0+ |
| `yq` | v4+ |
| `jq` | any |
| `istioctl` | 1.29.2 (only for gateway mode with Istio) |
