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
      {{- $me := $d.modelExpress | default dict }}
      {{- $meImage := "" }}
      {{- $containers := list }}
      {{- range $c := ($ps.containers | default list) }}
        {{- if eq ($c.name | default "") $cname }}
          {{- with $d.extraArgs }}{{- $_ := set $c "args" (concat ($c.args | default list) .) }}{{- end }}
          {{- with $d.extraEnv }}{{- $_ := set $c "env" (concat ($c.env | default list) .) }}{{- end }}
          {{- with $d.extraVolumeMounts }}{{- $_ := set $c "volumeMounts" (concat ($c.volumeMounts | default list) .) }}{{- end }}
          {{- with $d.containerSecurityContext }}{{- $_ := set $c "securityContext" . }}{{- end }}
          {{- if and $d.image $d.image.repository }}{{- $_ := set $c "image" (printf "%s:%s" $d.image.repository ($d.image.tag | default "latest")) }}{{- end }}
          {{- /* ModelExpress: address env + --load-format + a shared install dir on the target container. */}}
          {{- if $me.enabled }}
            {{- $meEnv := list }}
            {{- with $me.serverAddress }}
              {{- $meEnv = append $meEnv (dict "name" "MODEL_EXPRESS_URL" "value" .) }}
              {{- $meEnv = append $meEnv (dict "name" "MX_SERVER_ADDRESS" "value" .) }}
            {{- end }}
            {{- if $me.artifactTransfer }}{{- $meEnv = append $meEnv (dict "name" "MX_ARTIFACT_TRANSFER" "value" "1") }}{{- end }}
            {{- if $me.install }}{{- $meEnv = append $meEnv (dict "name" "PYTHONPATH" "value" "/mx-client") }}{{- end }}
            {{- with $me.extraEnv }}{{- $meEnv = concat $meEnv . }}{{- end }}
            {{- $_ := set $c "env" (concat ($c.env | default list) $meEnv) }}
            {{- with $me.loadFormat }}{{- $_ := set $c "args" (concat ($c.args | default list) (list (printf "--load-format=%s" .))) }}{{- end }}
            {{- if $me.install }}{{- $_ := set $c "volumeMounts" (concat ($c.volumeMounts | default list) (list (dict "name" "mx-client" "mountPath" "/mx-client"))) }}{{- end }}
            {{- $meImage = ($c.image | default "") }}
          {{- end }}
        {{- end }}
        {{- $containers = append $containers $c }}
      {{- end }}
      {{- $_ := set $ps "containers" $containers }}
      {{- /* ModelExpress install: an init container that pip-installs the client into the shared dir BEFORE the server starts. */}}
      {{- if and $me.enabled $me.install }}
        {{- $meImg := $me.installImage | default $meImage }}
        {{- if not $meImg }}{{- fail (printf "modelExpress.install is on but no image resolved for container %q — set an image on it or modelExpress.installImage" $cname) }}{{- end }}
        {{- $meInit := dict "name" "modelexpress-install" "image" $meImg "imagePullPolicy" "IfNotPresent" "command" (list "sh" "-c" (printf "pip install --target=/mx-client %s" ($me.package | default "modelexpress"))) "volumeMounts" (list (dict "name" "mx-client" "mountPath" "/mx-client")) }}
        {{- $_ := set $ps "initContainers" (concat ($ps.initContainers | default list) (list $meInit)) }}
        {{- $_ := set $ps "volumes" (concat ($ps.volumes | default list) (list (dict "name" "mx-client" "emptyDir" (dict)))) }}
      {{- end }}
      {{- with $d.extraVolumes }}{{- $_ := set $ps "volumes" (concat ($ps.volumes | default list) .) }}{{- end }}
      {{- with $d.podSecurityContext }}{{- $_ := set $ps "securityContext" . }}{{- end }}
      {{- with $d.imagePullSecrets }}{{- $_ := set $ps "imagePullSecrets" . }}{{- end }}
      {{- $ps | toYaml | nindent 6 }}
{{- end -}}
