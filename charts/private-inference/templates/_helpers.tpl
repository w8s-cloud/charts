{{- define "pi.name" -}}
{{- .Release.Name | trunc 45 | trimSuffix "-" -}}
{{- end -}}

{{- define "pi.labels" -}}
app.kubernetes.io/name: private-inference
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "pi.gpu" -}}
{{- if or (eq .Values.role "gpu") (eq .Values.role "both") }}true{{ end -}}
{{- end -}}

{{- define "pi.client" -}}
{{- if or (eq .Values.role "client") (eq .Values.role "both") }}true{{ end -}}
{{- end -}}

{{- define "pi.secretName" -}}
{{- .Values.apiKey.existingSecret | default (printf "%s-key" (include "pi.name" .)) -}}
{{- end -}}

{{/* Fails the render on values that cannot work, naming what to fix. */}}
{{- define "pi.validate" -}}
{{- if not (has .Values.role (list "gpu" "client" "both")) -}}
{{- fail (printf "role must be gpu, client or both (got %q)" .Values.role) -}}
{{- end -}}
{{- if and (not .Values.apiKey.existingSecret) (not .Values.apiKey.value) -}}
{{- fail "set apiKey.existingSecret (key apiKey) or apiKey.value; it must be the same in every cluster" -}}
{{- end -}}
{{- if and (eq .Values.role "client") (not .Values.client.gpuCluster) (not .Values.client.gpuHost) -}}
{{- fail "role client needs client.gpuCluster: the w8s cluster id of the cluster running role gpu" -}}
{{- end -}}
{{- if eq .Values.role "client" -}}
{{- $_ := include "pi.upstream" . -}}
{{- end -}}
{{- end -}}

{{/*
The GPU gateway as the client side reaches it. With role both, the local
gateway Service. Otherwise the Service the w8s agent materialises for the
GPU cluster's export, <service>--<namespace>--<cluster>
(crates/w8s-agent/src/service_imports.rs, relay_service_name); the agent
hashes that name when it would pass 63 characters, and then client.gpuHost
has to say it.
*/}}
{{- define "pi.upstream" -}}
{{- if eq .Values.role "both" -}}
{{- printf "%s.%s.svc.cluster.local:80" .Values.gateway.serviceName .Release.Namespace -}}
{{- else if .Values.client.gpuHost -}}
{{- .Values.client.gpuHost -}}
{{- else if not .Values.client.gpuCluster -}}
{{- fail "role client needs client.gpuCluster: the w8s cluster id of the cluster running role gpu" -}}
{{- else -}}
{{- $svc := printf "%s--%s--%s" .Values.gateway.serviceName .Release.Namespace .Values.client.gpuCluster -}}
{{- if or (gt (len $svc) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .Values.client.gpuCluster)) -}}
{{- fail (printf "the imported Service name %q would not fit a DNS label, so w8s names it w8s-import-<hash>; set client.gpuHost to that Service's host:port" $svc) -}}
{{- end -}}
{{- printf "%s.%s.svc.cluster.local:80" $svc .Values.client.importNamespace -}}
{{- end -}}
{{- end -}}
