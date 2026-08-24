{{/*
IDENTITY RESOLUTION.

Every identity field is written ONCE, in `global.llmd.*` at the umbrella level,
and read through these helpers. Precedence is always: an explicit chart-local
value wins, the global is the fallback, and a hardcoded default is the last
resort. Helm propagates `global` through every level of the dependency tree, so
a parent chart that wraps this umbrella can override the identity for a specific
deployment with a single `global.llmd.model=...` — something YAML anchors can
never do, because they resolve inside one file.
*/}}
{{- define "llm-d-modelserver.id.model" -}}
{{- .Values.model.name | default (dig "llmd" "model" "" (.Values.global | default dict)) -}}
{{- end -}}

{{- define "llm-d-modelserver.id.modelLabel" -}}
{{- .Values.model.label | default (dig "llmd" "modelLabel" "" (.Values.global | default dict)) -}}
{{- end -}}

{{- define "llm-d-modelserver.id.guide" -}}
{{- .Values.guideLabel | default (dig "llmd" "guide" "" (.Values.global | default dict)) -}}
{{- end -}}

{{- define "llm-d-modelserver.id.acceleratorVariant" -}}
{{- .Values.accelerator.variant | default (dig "llmd" "accelerator" "variant" "gpu" (.Values.global | default dict)) -}}
{{- end -}}

{{- define "llm-d-modelserver.id.acceleratorVendor" -}}
{{- .Values.accelerator.vendor | default (dig "llmd" "accelerator" "vendor" "nvidia" (.Values.global | default dict)) -}}
{{- end -}}

{{- define "llm-d-modelserver.id.hfSecretName" -}}
{{- .Values.hfTokenSecret.name | default (dig "llmd" "hfTokenSecret" "name" "llm-d-hf-token" (.Values.global | default dict)) -}}
{{- end -}}

{{- define "llm-d-modelserver.id.hfSecretKey" -}}
{{- .Values.hfTokenSecret.key | default (dig "llmd" "hfTokenSecret" "key" "HF_TOKEN" (.Values.global | default dict)) -}}
{{- end -}}

{{/*
Shared vLLM image tag. Single-sourced so decode, prefill and the render pool all
move together on a release bump.
*/}}
{{- define "llm-d-modelserver.id.vllmVersion" -}}
{{- dig "llmd" "vllmVersion" "v0.26.0" (.Values.global | default dict) -}}
{{- end -}}

{{/* Base name for all resources in this chart. */}}
{{- define "llm-d-modelserver.name" -}}
{{- .Release.Name | trunc 55 | trimSuffix "-" -}}
{{- end -}}

{{/*
Render Service name. Derived from the guide label, NOT the release name, so it
matches what the router's token-producer defaults to (and what upstream's
kustomize namePrefix produces: `<guide>-render`). This lets the router and
modelserver charts be installed under different release names.
*/}}
{{- define "llm-d-modelserver.renderName" -}}
{{- printf "%s-render" (include "llm-d-modelserver.id.guide" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels for a role's pods, parameterized by role ("decode" / "prefill").
`llm-d.ai/role` is how the EPP's prefill-filter/decode-filter split traffic, and
`llm-d.ai/guide` is what the router's InferencePool selects on — so these must
appear on the pod template AND the Deployment selector, kept identical (a role
can never half-apply). Call as: (dict "root" $ "role" "decode").
*/}}
{{- define "llm-d-modelserver.roleSelectorLabels" -}}
llm-d.ai/role: {{ .role }}
llm-d.ai/guide: {{ include "llm-d-modelserver.id.guide" .root | quote }}
llm-d.ai/model: {{ include "llm-d-modelserver.id.modelLabel" .root | quote }}
llm-d.ai/accelerator-variant: {{ include "llm-d-modelserver.id.acceleratorVariant" .root | quote }}
llm-d.ai/accelerator-vendor: {{ include "llm-d-modelserver.id.acceleratorVendor" .root | quote }}
{{- end -}}

{{/* Back-compat alias — decode pods. Same output as roleSelectorLabels role=decode. */}}
{{- define "llm-d-modelserver.decodeSelectorLabels" -}}
{{- include "llm-d-modelserver.roleSelectorLabels" (dict "root" . "role" "decode") -}}
{{- end -}}

{{/*
Naming/role for the primary model server. When prefill is OFF the single server
handles BOTH phases, so it is role=prefill-decode (the llm-d "both-capable"
value) and named "<release>-modelserver" — NOT "decode", which only makes sense
under disaggregation. When prefill is ON (P/D) it is the decode role, named
"<release>-decode".
*/}}
{{- define "llm-d-modelserver.decodeRole" -}}
{{- if .Values.prefill.enabled -}}decode{{- else -}}prefill-decode{{- end -}}
{{- end -}}
{{- define "llm-d-modelserver.decodeSuffix" -}}
{{- if .Values.prefill.enabled -}}decode{{- else -}}modelserver{{- end -}}
{{- end -}}
{{- define "llm-d-modelserver.decodeName" -}}
{{- printf "%s-%s" (include "llm-d-modelserver.name" .) (include "llm-d-modelserver.decodeSuffix" .) -}}
{{- end -}}

{{/* Common metadata labels. */}}
{{- define "llm-d-modelserver.labels" -}}
app.kubernetes.io/name: {{ include "llm-d-modelserver.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/*
Render pod selector labels — intentionally WITHOUT `llm-d.ai/guide`.
See the note in values.yaml.
*/}}
{{- define "llm-d-modelserver.renderSelectorLabels" -}}
app.kubernetes.io/component: vllm-render
app.kubernetes.io/part-of: {{ include "llm-d-modelserver.name" . }}
{{- end -}}

{{/*
ServiceAccount name. Set `serviceAccount.name` to bind an existing SA (with
`serviceAccount.create: false`); otherwise one is created as <release>-sa.
*/}}
{{- define "llm-d-modelserver.serviceAccountName" -}}
{{- if .Values.serviceAccount.name -}}
{{- .Values.serviceAccount.name -}}
{{- else -}}
{{- printf "%s-sa" (include "llm-d-modelserver.name" .) -}}
{{- end -}}
{{- end -}}

{{/*
Which role the render Service fronts when render.mode=service.
Derived, not restated: under P/D the decode pod's port 8000 belongs to the
routing sidecar (not vLLM), so render must select the prefill pods. Aggregated,
the single server is role=prefill-decode. Override with render.selectorRole.
*/}}
{{- define "llm-d-modelserver.renderSelectorRole" -}}
{{- if .Values.render.selectorRole -}}
{{- .Values.render.selectorRole -}}
{{- else if .Values.prefill.enabled -}}
prefill
{{- else -}}
prefill-decode
{{- end -}}
{{- end -}}
