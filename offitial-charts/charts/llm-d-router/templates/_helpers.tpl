{{/* Base name for resources this parent chart owns. */}}
{{- define "llm-d-router.name" -}}
{{- printf "%s-epp" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
