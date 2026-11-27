{{/*
The documents of a vendored upstream manifest, rendered as they are.
CustomResourceDefinitions are left out: the chart's crds/ holds them,
because Helm must create a CRD before it can create the resource that
uses it (the KubeVirt and CDI CRs below).
*/}}
{{- define "vmp.vendored" -}}
{{- range regexSplit "(?m)^---[ \t]*$" . -1 }}
{{- if and (regexMatch "(?m)^kind: " .) (not (regexMatch "(?m)^kind: CustomResourceDefinition[ \t]*$" .)) }}
---
{{ trim . }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "vmp.labels" -}}
app.kubernetes.io/name: w8s-vm-platform
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Fails the render on values that cannot work, naming what to fix. */}}
{{- define "vmp.validate" -}}
{{- if has .Release.Namespace (list "kubevirt" "cdi" "local-path-storage") -}}
{{- fail (printf "install into a namespace of its own, not %q: the chart creates the kubevirt, cdi and local-path-storage namespaces itself" .Release.Namespace) -}}
{{- end -}}
{{- if not (has .Values.storage (list "none" "local-path")) -}}
{{- fail (printf "storage must be none or local-path, not %q" .Values.storage) -}}
{{- end -}}
{{- if and (eq .Values.storage "local-path") (not (hasPrefix "/" .Values.localPath.path)) -}}
{{- fail "localPath.path must be an absolute path on the nodes" -}}
{{- end -}}
{{- end -}}
