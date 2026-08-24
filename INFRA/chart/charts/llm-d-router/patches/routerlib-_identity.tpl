{{- /*
  VENDORED PATCH (llm-d umbrella) — ADDITIVE FILE, no upstream counterpart.

  Single-sources the identity fields (model, guide, model label, gateway) into
  `global.llmd.*`, so they are written ONCE and fan out to every consumer —
  including a parent chart that wraps this umbrella, because Helm propagates
  `global` down through every level of the dependency tree. YAML anchors cannot
  do this: they resolve inside one file and die at the `-f` boundary.

  Precedence is always: an explicit local value wins, `global.llmd.*` is the
  fallback. Nothing here overrides a value someone deliberately set.

  Consumed by the three patched call sites listed in PATCHES.md.
*/ -}}

{{- /* The global.llmd dict, or an empty dict when the umbrella is not in use. */ -}}
{{- define "llmd.identity.dict" -}}
{{- (.Values.global | default dict).llmd | default dict | toYaml -}}
{{- end -}}

{{- define "llmd.identity.model" -}}
{{- dig "llmd" "model" "" (.Values.global | default dict) -}}
{{- end -}}

{{- define "llmd.identity.modelLabel" -}}
{{- dig "llmd" "modelLabel" "" (.Values.global | default dict) -}}
{{- end -}}

{{- define "llmd.identity.guide" -}}
{{- dig "llmd" "guide" "" (.Values.global | default dict) -}}
{{- end -}}

{{- define "llmd.identity.gateway" -}}
{{- dig "llmd" "gateway" "" (.Values.global | default dict) -}}
{{- end -}}

{{- /*
  InferencePool / EPP endpoint selector labels.

  Explicit `router.modelServers.matchLabels` wins outright. Otherwise the
  selector is derived from the identity: the guide label alone if only the guide
  is set, plus the model label when one is given. Keys are the llm-d
  conventions the model servers stamp on their pods.
*/ -}}
{{- define "llmd.modelServers.matchLabels" -}}
{{- if .Values.router.modelServers.matchLabels -}}
{{- toYaml .Values.router.modelServers.matchLabels -}}
{{- else -}}
{{- $out := dict -}}
{{- $guide := include "llmd.identity.guide" . -}}
{{- $label := include "llmd.identity.modelLabel" . -}}
{{- if $guide }}{{- $_ := set $out "llm-d.ai/guide" $guide -}}{{- end -}}
{{- if $label }}{{- $_ := set $out "llm-d.ai/model" $label -}}{{- end -}}
{{- toYaml $out -}}
{{- end -}}
{{- end -}}
