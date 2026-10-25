{{- define "cr.name" -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{- define "cr.labels" -}}
app.kubernetes.io/name: couchdb-replicated
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "cr.dnsLabel" -}}
{{- regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" . -}}
{{- end -}}

{{/* Fails the render on values that cannot work, naming what to fix. */}}
{{- define "cr.validate" -}}
{{- if not .Values.clusterId -}}
{{- fail "clusterId is required: this cluster's w8s cluster id" -}}
{{- end -}}
{{- if ne (include "cr.dnsLabel" .Values.clusterId) "true" -}}
{{- fail (printf "clusterId %q is not a cluster id: w8s cluster ids are lowercase DNS labels" .Values.clusterId) -}}
{{- end -}}
{{- if has .Values.clusterId .Values.peers -}}
{{- fail (printf "peers lists this cluster's own id %q" .Values.clusterId) -}}
{{- end -}}
{{- if and (not .Values.auth.existingSecret) (not .Values.auth.password) -}}
{{- fail "set auth.existingSecret (keys username, password) or auth.password; it must be the same in every cluster" -}}
{{- end -}}
{{- range .Values.peers -}}
{{- $_ := include "cr.peerHost" (dict "root" $ "peer" .) -}}
{{- end -}}
{{- end -}}

{{- define "cr.secretName" -}}
{{- .Values.auth.existingSecret | default (printf "%s-auth" (include "cr.name" .)) -}}
{{- end -}}

{{/*
Where a peer's CouchDB answers from inside this cluster: the Service the
w8s agent materialises for the peer's export, named
<service>--<namespace>--<cluster> (crates/w8s-agent/src/service_imports.rs,
relay_service_name). The agent hashes the name instead when it would not
fit 63 characters or the cluster id is not a DNS label; the chart cannot
reproduce that hash, so it asks for replication.peerHosts.
*/}}
{{- define "cr.peerHost" -}}
{{- $root := .root -}}
{{- $peer := .peer -}}
{{- $override := index $root.Values.replication.peerHosts $peer -}}
{{- if $override -}}
{{- $override -}}
{{- else -}}
{{- $svc := printf "%s--%s--%s" $root.Values.couchdb.serviceName $root.Release.Namespace $peer -}}
{{- if or (gt (len $svc) 63) (ne (include "cr.dnsLabel" $peer) "true") -}}
{{- fail (printf "peer %q: the imported Service name %q would not fit a DNS label, so w8s names it w8s-import-<hash>; set replication.peerHosts.%s to that Service's host" $peer $svc $peer) -}}
{{- end -}}
{{- printf "%s.%s.svc.cluster.local" $svc $root.Values.replication.importNamespace -}}
{{- end -}}
{{- end -}}
