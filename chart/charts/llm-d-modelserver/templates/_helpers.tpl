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
Selector labels for the decode pods. `llm-d.ai/guide` is what the router's
InferencePool selects on, so it must appear on the pod template AND the
Deployment selector.
*/}}
{{- define "llm-d-modelserver.decodeSelectorLabels" -}}
llm-d.ai/role: decode
llm-d.ai/guide: {{ .Values.guideLabel | quote }}
llm-d.ai/model: {{ .Values.model.label | quote }}
llm-d.ai/accelerator-variant: {{ .Values.accelerator.variant | quote }}
llm-d.ai/accelerator-vendor: {{ .Values.accelerator.vendor | quote }}
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
