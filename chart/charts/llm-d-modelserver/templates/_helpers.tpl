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
{{- printf "%s-render" .Values.guideLabel | trunc 63 | trimSuffix "-" -}}
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
llm-d.ai/guide: {{ .root.Values.guideLabel | quote }}
llm-d.ai/model: {{ .root.Values.model.label | quote }}
llm-d.ai/accelerator-variant: {{ .root.Values.accelerator.variant | quote }}
llm-d.ai/accelerator-vendor: {{ .root.Values.accelerator.vendor | quote }}
{{- end -}}

{{/* Back-compat alias — decode pods. Same output as roleSelectorLabels role=decode. */}}
{{- define "llm-d-modelserver.decodeSelectorLabels" -}}
{{- include "llm-d-modelserver.roleSelectorLabels" (dict "root" . "role" "decode") -}}
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
