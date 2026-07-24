{{- /*
Shared model-server Deployment, rendered for BOTH decode and prefill. The two
roles are the same Deployment shape with a different `llm-d.ai/role` label — this
partial is the single seam. Call as:
    (dict "root" $ "role" "decode"  "cfg" .Values.decode)
    (dict "root" $ "role" "prefill" "cfg" .Values.prefill)

The chart owns ONLY what the upstream kustomize base + labels transformer own:
metadata, the guide/role labels (InferencePool selector + P/D filter), the
selector, the pod-template labels, and the ServiceAccount. `cfg.spec` is YOUR
patch — rendered VERBATIM. Additive knobs (extraArgs/extraEnv/extraVolumeMounts/
extraVolumes/containerSecurityContext/podSecurityContext/imagePullSecrets/image/
podAnnotations/deploymentAnnotations) merge onto it identically for both roles.
*/ -}}
{{- define "llm-d-modelserver.serverDeployment" -}}
{{- $ := .root -}}
{{- $role := .role -}}
{{- $suffix := .nameSuffix | default .role -}}
{{- $d := .cfg -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "llm-d-modelserver.name" $ }}-{{ $suffix }}
  namespace: {{ $.Release.Namespace }}
  labels:
    {{- include "llm-d-modelserver.labels" $ | nindent 4 }}
    {{- include "llm-d-modelserver.roleSelectorLabels" (dict "root" $ "role" $role) | nindent 4 }}
  {{- with $d.deploymentAnnotations }}
  annotations:
    {{- range $k, $v := . }}
    {{ $k }}: {{ $v | quote }}
    {{- end }}
  {{- end }}
spec:
  replicas: {{ dig "spec" "replicas" 1 $d }}
  selector:
    matchLabels:
      {{- include "llm-d-modelserver.roleSelectorLabels" (dict "root" $ "role" $role) | nindent 6 }}
  {{- with dig "spec" "strategy" dict $d }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  template:
    metadata:
      labels:
        {{- include "llm-d-modelserver.roleSelectorLabels" (dict "root" $ "role" $role) | nindent 8 }}
        {{- with dig "spec" "template" "metadata" "labels" dict $d }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        {{- with $d.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- $podAnn := merge (dict) ($d.podAnnotations | default dict) (dig "spec" "template" "metadata" "annotations" dict $d) }}
      {{- with $podAnn }}
      annotations:
        {{- range $k, $v := . }}
        {{ $k }}: {{ $v | quote }}
        {{- end }}
      {{- end }}
    spec:
      # Chart-injected (kustomize base owns this). Override by putting
      # serviceAccountName in {{ $role }}.spec.template.spec.
      serviceAccountName: {{ include "llm-d-modelserver.serviceAccountName" $ }}
      {{- /* Start from your verbatim patch spec, then fold in the additive knobs. */}}
      {{- $ps := omit (deepCopy (dig "spec" "template" "spec" dict $d)) "serviceAccountName" }}
      {{- $cname := $d.containerName | default "modelserver" }}
      {{- $containers := list }}
      {{- range $c := ($ps.containers | default list) }}
        {{- if eq ($c.name | default "") $cname }}
          {{- with $d.extraArgs }}{{- $_ := set $c "args" (concat ($c.args | default list) .) }}{{- end }}
          {{- with $d.extraEnv }}{{- $_ := set $c "env" (concat ($c.env | default list) .) }}{{- end }}
          {{- with $d.extraVolumeMounts }}{{- $_ := set $c "volumeMounts" (concat ($c.volumeMounts | default list) .) }}{{- end }}
          {{- with $d.containerSecurityContext }}{{- $_ := set $c "securityContext" . }}{{- end }}
          {{- if and $d.image $d.image.repository }}{{- $_ := set $c "image" (printf "%s:%s" $d.image.repository ($d.image.tag | default "latest")) }}{{- end }}
        {{- end }}
        {{- $containers = append $containers $c }}
      {{- end }}
      {{- $_ := set $ps "containers" $containers }}
      {{- with $d.extraVolumes }}{{- $_ := set $ps "volumes" (concat ($ps.volumes | default list) .) }}{{- end }}
      {{- with $d.podSecurityContext }}{{- $_ := set $ps "securityContext" . }}{{- end }}
      {{- with $d.imagePullSecrets }}{{- $_ := set $ps "imagePullSecrets" . }}{{- end }}
      {{- $ps | toYaml | nindent 6 }}
{{- end -}}
