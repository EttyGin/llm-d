{{- /*
LeaderWorkerSet render mode (wide-EP / multi-node DP). Same role/name/label
wiring and additive-knob surface as serverDeployment, but emits a
kind: LeaderWorkerSet whose workerTemplate holds the (authored, verbatim) pod
spec. Selected per role with `<role>.workload: leaderWorkerSet`. Params match
serverDeployment: (dict "root" $ "role" R "nameSuffix" S "cfg" .Values.<role>).
Requires the LeaderWorkerSet controller (lws.sigs.k8s.io).
*/ -}}
{{- define "llm-d-modelserver.serverLeaderWorkerSet" -}}
{{- $ := .root -}}
{{- $role := .role -}}
{{- $suffix := .nameSuffix | default .role -}}
{{- $d := .cfg -}}
{{- $lws := $d.leaderWorkerSet | default dict -}}
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
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
  {{- with $lws.startupPolicy }}
  startupPolicy: {{ . }}
  {{- end }}
  leaderWorkerTemplate:
    size: {{ dig "size" 2 $lws }}
    {{- with $lws.restartPolicy }}
    restartPolicy: {{ . }}
    {{- end }}
    workerTemplate:
      metadata:
        labels:
          {{- include "llm-d-modelserver.roleSelectorLabels" (dict "root" $ "role" $role) | nindent 10 }}
          {{- with $d.podLabels }}
          {{- toYaml . | nindent 10 }}
          {{- end }}
        {{- with $d.podAnnotations }}
        annotations:
          {{- range $k, $v := . }}
          {{ $k }}: {{ $v | quote }}
          {{- end }}
        {{- end }}
      spec:
        {{- /* Start from the verbatim pod spec, inject the SA + fold in the additive knobs. */}}
        {{- $ps := deepCopy (dig "spec" "template" "spec" dict $d) }}
        {{- $_ := set $ps "serviceAccountName" (include "llm-d-modelserver.serviceAccountName" $) }}
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
        {{- $ps | toYaml | nindent 8 }}
{{- end -}}
