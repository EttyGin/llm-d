{{/*
Common labels. `llm-d.ai/guide` is the InferencePool selector — it must match
the router chart's router.modelServers.matchLabels, and the router release
name must equal .Values.guideName.
*/}}
{{- define "dsv4.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
llm-d.ai/guide: {{ .Values.guideName }}
llm-d.ai/model: {{ .Values.model.label }}
llm-d.ai/accelerator-variant: gpu
llm-d.ai/accelerator-vendor: nvidia
llm-d.ai/engine-type: vllm
{{- end -}}

{{/*
Pod selector labels for one role. Kept minimal and stable — changing these on
an existing release requires deleting the Deployment (selectors are immutable).
*/}}
{{- define "dsv4.selectorLabels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
llm-d.ai/guide: {{ .root.Values.guideName }}
llm-d.ai/role: {{ .role }}
{{- end -}}

{{- define "dsv4.serviceAccountName" -}}
{{ .Release.Name }}-sa
{{- end -}}

{{/*
kv_transfer_config for either leg.

  offloading.mode=off        -> NixlConnector alone
  otherwise                  -> MultiConnector{ NixlConnector, OffloadingConnector }

NIXL always carries the P/D handoff. The OffloadingConnector owns the CPU tier
and, when p2p.enabled, the P2P listener peers pull from. Both legs run the same
connector set: a pod answers pulls regardless of its role.
*/}}
{{- define "dsv4.kvTransferConfig" -}}
{{- $off := .Values.offloading -}}
{{- $p2p := .Values.p2p -}}
{{- $nixl := dict "kv_connector" "NixlConnector" "kv_role" "kv_both" -}}
{{- if or (eq (toString $off.mode) "off") (eq (toString $off.mode) "false") (eq (toString $off.mode) "none") -}}
{{- toJson (merge (dict "kv_load_failure_policy" "fail") $nixl) -}}
{{- else -}}
  {{- $extra := dict
        "cpu_bytes_to_use" (atoi $off.cpuBytes)
        "eviction_policy" $off.evictionPolicy
        "offload_prompt_only" $off.offloadPromptOnly -}}
  {{- $tiers := list -}}
  {{- if $p2p.enabled -}}
    {{- $tiers = append $tiers (dict "type" "p2p" "host" "$(POD_IP)" "port" (int $p2p.port)) -}}
  {{- end -}}
  {{- if eq (toString $off.mode) "tiered" -}}
    {{- $tiers = append $tiers (dict "type" "fs" "root_dir" $off.nvmePath "n_read_threads" 16 "n_write_threads" 16) -}}
  {{- end -}}
  {{- if $tiers -}}
    {{- $extra = merge $extra (dict "spec_name" "TieringOffloadingSpec" "secondary_tiers" $tiers) -}}
  {{- end -}}
  {{- $offloader := dict "kv_connector" "OffloadingConnector" "kv_role" "kv_both" "kv_connector_extra_config" $extra -}}
  {{- toJson (dict
        "kv_connector" "MultiConnector"
        "kv_role" "kv_both"
        "kv_load_failure_policy" "fail"
        "kv_connector_extra_config" (dict "connectors" (list $nixl $offloader))) -}}
{{- end -}}
{{- end -}}

{{/*
speculative-config JSON (DSpark MTP head shipped with the checkpoint).
*/}}
{{- define "dsv4.speculativeConfig" -}}
{{- toJson (dict
      "method" .Values.speculative.method
      "num_speculative_tokens" (int .Values.speculative.numTokens)
      "draft_sample_method" .Values.speculative.draftSampleMethod) -}}
{{- end -}}

{{/*
vLLM launch args for one leg.
Context: { root, role, cfg, port }
*/}}
{{- define "dsv4.vllmArgs" -}}
{{- $r := .root -}}
{{- $cfg := .cfg -}}
- {{ $r.Values.model.name | quote }}
- "--port={{ .port }}"
{{- if $r.Values.model.trustRemoteCode }}
- "--trust-remote-code"
{{- end }}
- "--tokenizer-mode={{ $r.Values.model.tokenizerMode }}"
- "--kv-cache-dtype={{ $r.Values.model.kvCacheDtype }}"
- "--block-size={{ $r.Values.model.blockSize }}"
- "--max-model-len={{ $r.Values.model.maxModelLen }}"
- "--disable-access-log-for-endpoints=/health,/metrics,/v1/models"
- "--gpu-memory-utilization={{ $cfg.gpuMemoryUtilization }}"
- "--tensor-parallel-size={{ $cfg.tensorParallelSize }}"
- "--data-parallel-size={{ $cfg.dataParallelSize }}"
- "--data-parallel-size-local={{ $cfg.dataParallelSize }}"
{{- if eq $r.Values.dp.lbMode "multiport" }}
# One API server per DP rank; the EPP addresses ranks individually.
- "--data-parallel-multi-port-external-lb"
- "--data-parallel-supervisor-port=8208"
{{- else }}
- "--api-server-count={{ $cfg.apiServerCount }}"
{{- end }}
{{- if $r.Values.moe.enableExpertParallel }}
- "--enable-expert-parallel"
{{- end }}
{{- if $r.Values.moe.enableEpWeightFilter }}
- "--enable-ep-weight-filter"
{{- end }}
- "--moe-backend={{ $r.Values.moe.backend }}"
- "--all2all-backend={{ $cfg.all2allBackend }}"
- "--max-num-batched-tokens={{ $cfg.maxNumBatchedTokens }}"
- "--max-num-seqs={{ $cfg.maxNumSeqs }}"
{{- if $cfg.enforceEager }}
- "--enforce-eager"
{{- end }}
{{- if $r.Values.speculative.enabled }}
- "--speculative-config"
- {{ include "dsv4.speculativeConfig" $r | quote }}
{{- end }}
- "--kv-transfer-config"
- {{ include "dsv4.kvTransferConfig" $r | quote }}
{{- end -}}

{{/*
Environment shared by both legs.
Context: { root, role }
*/}}
{{- define "dsv4.commonEnv" -}}
{{- $r := .root -}}
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: HF_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ $r.Values.hfTokenSecret }}
      key: HF_TOKEN
- name: HF_HOME
  value: /var/cache/huggingface
# NIXL binds its side channel to the pod IP so the peer leg can reach it;
# the default is localhost, which makes cross-pod P/D transfer fail silently.
- name: VLLM_NIXL_SIDE_CHANNEL_HOST
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
{{- if $r.Values.p2p.enabled }}
- name: VLLM_P2P_SIDE_CHANNEL_HOST
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
# vLLM seeds KV block hashes per process. Every peer MUST share this value or
# no block hash matches across pods and every P2P lookup misses.
- name: PYTHONHASHSEED
  value: "0"
{{- end }}
- name: VLLM_USE_DEEP_GEMM
  value: "1"
- name: VLLM_SKIP_P2P_CHECK
  value: "1"
- name: VLLM_RANDOMIZE_DP_DUMMY_INPUTS
  value: "1"
- name: TRITON_LIBCUDA_PATH
  value: /usr/lib64
- name: NVIDIA_GDRCOPY
  value: enabled
- name: GLOO_SOCKET_IFNAME
  value: eth0
- name: NCCL_SOCKET_IFNAME
  value: eth0
- name: VLLM_HTTP_TIMEOUT_KEEP_ALIVE
  value: "120"
- name: VLLM_LOGGING_LEVEL
  value: INFO
# vLLM usage telemetry writes to /.config, which fails under restricted
# SecurityContexts (e.g. OpenShift).
- name: DO_NOT_TRACK
  value: "1"
- name: CUDA_CACHE_PATH
  value: /var/cache/vllm/cuda
- name: VLLM_CACHE_ROOT
  value: /var/cache/vllm/vllm
- name: FLASHINFER_WORKSPACE_BASE
  value: /var/cache/vllm/flashinfer
{{- if $r.Values.infiniband.enabled }}
- name: NCCL_IB_HCA
  value: {{ $r.Values.infiniband.hcaPrefix | quote }}
- name: NVSHMEM_HCA_PREFIX
  value: {{ $r.Values.infiniband.hcaPrefix | quote }}
- name: NVSHMEM_REMOTE_TRANSPORT
  value: ibgda
- name: NVSHMEM_IB_ENABLE_IBGDA
  value: "true"
- name: NVSHMEM_BOOTSTRAP_UID_SOCK_IFNAME
  value: eth0
{{- end }}
{{- end -}}

{{/*
Cache volumes shared by both legs.
*/}}
{{- define "dsv4.cacheVolumeMounts" -}}
- name: dshm
  mountPath: /dev/shm
- name: hf-cache
  mountPath: /var/cache/huggingface
- name: jit-cache
  mountPath: /var/cache/vllm
- name: vllm-config
  mountPath: /.config
{{- end -}}
