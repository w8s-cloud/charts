{{- define "w8s-agent.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "w8s-agent.fullname" -}}{{ if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name (include "w8s-agent.name" .) | trunc 63 | trimSuffix "-" }}{{ end }}{{- end }}
{{- define "w8s-agent.serviceAccountName" -}}{{ if .Values.serviceAccount.name }}{{ .Values.serviceAccount.name }}{{ else }}{{ include "w8s-agent.fullname" . }}{{ end }}{{- end }}
{{/*
The install profiles (values.yaml `profile`): capability presets, from
least to most. `capabilities` set by hand is applied on top, key by key.

  connect  the cluster is connected and routes publish; nothing else
  observe  read-only: Explorer without Secrets, logs, the scan
  manage   observe, plus changing things - but only in manage.namespaces
           (RoleBindings there, not cluster-wide), plus kubectl as the
           person, a pod shell, the cluster terminal, apps into those
           namespaces, CI, internal-route tunnels
  admin    every feature, cluster-wide (the default: what 0.16 and earlier
           could already do, less what 0.16 took away for good)
*/}}
{{- define "w8s-agent.profiles" -}}
connect:
  explorer: {read: false, write: false, secrets: false, namespaces: []}
  logs: false
  exec: false
  shell: false
  kubectl: {enabled: false}
  apps: {enabled: false}
  ci: false
  tunnels: {mode: "off"}
  selfUpgrade: {mode: "off"}
observe:
  explorer: {read: true, write: false, secrets: false, namespaces: []}
  logs: true
  exec: false
  shell: false
  kubectl: {enabled: false}
  apps: {enabled: false}
  ci: false
  tunnels: {mode: "off"}
  selfUpgrade: {mode: "off"}
manage:
  explorer: {read: true, write: true, secrets: false}
  logs: true
  exec: true
  shell: true
  kubectl: {enabled: true}
  apps: {enabled: true}
  ci: true
  tunnels: {mode: internalRoutesOnly}
  selfUpgrade: {mode: "off"}
relay:
  explorer: {read: false, write: false, secrets: false, namespaces: []}
  logs: false
  exec: false
  shell: false
  kubectl: {enabled: false}
  apps: {enabled: false}
  ci: false
  tunnels: {mode: "off"}
  selfUpgrade: {mode: "off"}
admin:
  explorer: {read: true, write: true, secrets: true, namespaces: []}
  logs: true
  exec: true
  shell: true
  kubectl: {enabled: true}
  apps: {enabled: true}
  ci: true
  tunnels: {mode: internalRoutesOnly}
  selfUpgrade: {mode: "off"}
{{- end }}
{{/*
The capabilities this release grants, as YAML for `fromYaml`: what
templates/rbac.yaml renders RBAC for, and what the agent gets as
W8S_CAPABILITIES. The profile's preset, then `capabilities` over it key by
key (a plain merge would not let `false` override `true`), then the rules
settled here once: `manage` writes and installs apps only in
manage.namespaces, the pre-0.17 `selfUpgrade.enabled: true` still means
`auto`, and an unknown profile or mode fails the render instead of
silently granting nothing (or everything).
*/}}
{{- define "w8s-agent.capabilities" -}}
{{- if and (eq (.Values.profile | default "admin") "relay") (index .Values "envoy-gateway" "enabled") }}
{{- fail "profile relay renders nothing cluster-wide: set envoy-gateway.enabled=false" }}
{{- end }}
{{- $profiles := include "w8s-agent.profiles" . | fromYaml }}
{{- $profile := .Values.profile | default "admin" }}
{{- if not (hasKey $profiles $profile) }}
{{- fail (printf "profile must be connect, observe, manage, admin or relay, not %q" $profile) }}
{{- end }}
{{- $caps := deepCopy (get $profiles $profile) }}
{{- $kubectl := $caps.kubectl }}
{{- $_ := set $kubectl "allowedGroups" (list "w8s:users" "w8s:org-admins" "w8s:developers") }}
{{- $apps := $caps.apps }}
{{- $_ := set $apps "chartSources" list }}
{{- if eq $profile "manage" }}
{{- $ns := .Values.manage.namespaces | default list }}
{{- if not $ns }}
{{- fail "profile manage needs manage.namespaces: the namespaces w8s may change" }}
{{- end }}
{{- $_ := set $caps.explorer "namespaces" $ns }}
{{- $_ := set $apps "namespaces" $ns }}
{{- else }}
{{- $_ := set $apps "namespaces" list }}
{{- end }}
{{- range $k, $v := (.Values.capabilities | default dict) }}
{{- if kindIs "map" $v }}
{{- $sub := get $caps $k | default dict }}
{{- range $k2, $v2 := $v }}{{- $_ := set $sub $k2 $v2 }}{{- end }}
{{- $_ := set $caps $k $sub }}
{{- else }}
{{- $_ := set $caps $k $v }}
{{- end }}
{{- end }}
{{- $_ := set $caps "profile" $profile }}
{{- $su := $caps.selfUpgrade | default dict }}
{{- $mode := toString ($su.mode | default "off") }}
{{- if eq $mode "false" }}{{- $mode = "off" }}{{- end }}
{{- if and .Values.selfUpgrade.enabled (eq $mode "off") }}{{- $mode = "auto" }}{{- end }}
{{- if not (has $mode (list "off" "approve" "auto")) }}
{{- fail (printf "capabilities.selfUpgrade.mode must be off, approve or auto, not %q" $mode) }}
{{- end }}
{{- $_ := set $su "mode" $mode }}
{{- $_ := set $caps "selfUpgrade" $su }}
{{- $tunnels := $caps.tunnels | default dict }}
{{- $tmode := toString ($tunnels.mode | default "internalRoutesOnly") }}
{{- if eq $tmode "false" }}{{- $tmode = "off" }}{{- end }}
{{- if not (has $tmode (list "off" "internalRoutesOnly")) }}
{{- fail (printf "capabilities.tunnels.mode must be internalRoutesOnly or off, not %q" $tmode) }}
{{- end }}
{{- $_ := set $tunnels "mode" $tmode }}
{{- $_ := set $caps "tunnels" $tunnels }}
{{- toYaml $caps }}
{{- end }}
{{/*
The agent's own objects in cloudflared.namespace: the cloudflared
Deployment and its token Secret, the CloudflareTunnel it reconciles, and
the Gateway routes attach to (templates/rbac.yaml says where they land).
*/}}
{{- define "w8s-agent.ownNamespaceRules" -}}
- apiGroups: [""]
  resources: ["secrets"]
  verbs: {{ toJson .rw }}
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: {{ toJson .rw }}
- apiGroups: ["w8s.cloud"]
  resources: ["cloudflaretunnels", "cloudflaretunnels/status"]
  verbs: {{ toJson .rw }}
# The CloudflareTunnel's group before chart 0.25.0: read to move a
# cluster's object over, and delete it after.
- apiGroups: ["w8s.dev"]
  resources: ["cloudflaretunnels"]
  verbs: ["get", "list", "delete"]
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["gateways"]
  verbs: {{ toJson .rw }}
{{- end }}
{{/*
capabilities.explorer.write's rules, cluster-wide or per namespace.
*/}}
{{- define "w8s-agent.writeRules" -}}
- apiGroups: [""]
  resources: ["pods", "services", "persistentvolumeclaims", "serviceaccounts", "configmaps"{{ if .secrets }}, "secrets"{{ end }}]
  verbs: {{ toJson .rw }}
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
  verbs: {{ toJson .rw }}
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: {{ toJson .rw }}
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies"]
  verbs: {{ toJson .rw }}
{{- end }}
{{/*
What an app's Helm release writes (the kinds the charts the hub offers
contain), and Secrets, where Helm keeps its releases.
*/}}
{{- define "w8s-agent.appRules" -}}
- apiGroups: [""]
  resources: ["services", "configmaps", "secrets", "persistentvolumeclaims", "serviceaccounts"]
  verbs: {{ toJson .rw }}
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets"]
  verbs: {{ toJson .rw }}
- apiGroups: ["multicluster.x-k8s.io"]
  resources: ["serviceexports"]
  verbs: {{ toJson .rw }}
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies"]
  verbs: {{ toJson .rw }}
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes"]
  verbs: {{ toJson .rw }}
{{- end }}
{{/*
CI builds in w8s-ci: the registry and its Service, claim and credentials,
one Job per build, and reading its pods, events and logs.
*/}}
{{- define "w8s-agent.ciRules" -}}
- apiGroups: [""]
  resources: ["pods", "events"]
  verbs: {{ toJson .ro }}
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["services", "secrets", "persistentvolumeclaims"]
  verbs: {{ toJson .rw }}
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: {{ toJson .rw }}
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: {{ toJson .rw }}
{{- end }}
{{- define "w8s-agent.upgradeServiceAccountName" -}}{{ printf "%s-upgrade" (include "w8s-agent.fullname" .) | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "w8s-agent.caSecretName" -}}{{ if .Values.certificates.existingSecret }}{{ .Values.certificates.existingSecret }}{{ else }}{{ printf "%s-relay-ca" (include "w8s-agent.fullname" .) }}{{ end }}{{- end }}
{{/*
OTEL_RESOURCE_ATTRIBUTES of the agent and the spoke relay with
ownTelemetry: the pod as service.instance.id, then
ownTelemetry.resourceAttributes sorted by key.
*/}}
{{- define "w8s-agent.ownResourceAttributes" -}}
service.instance.id=$(W8S_POD_NAME)
{{- range $k, $v := .Values.ownTelemetry.resourceAttributes | default dict -}}
,{{ $k }}={{ $v }}
{{- end -}}
{{- end }}
{{- define "w8s-agent.otlpHubName" -}}{{ printf "%s-otlp-hub" .Release.Name | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "w8s-agent.otlpHubEndpoint" -}}{{ printf "http://%s:4319" (include "w8s-agent.otlpHubName" .) }}{{- end }}
{{- define "w8s-agent.controlBusSecretName" -}}{{ printf "%s-nats-login" (include "w8s-agent.fullname" .) }}{{- end }}
{{- define "w8s-agent.natsTokenSecretName" -}}{{ printf "%s-nats-token" (include "w8s-agent.fullname" .) }}{{- end }}
{{/*
The token the cluster's NATS leaf asks of its clients (templates/nats-leaf.yaml):
controlBus.token when given, else the one the Secret holds (lookup, so an
upgrade keeps it), else a fresh one. Minted once per render and kept in
.Values for the rest of it: the leaf, the agent and the relay must agree.
*/}}
{{- define "w8s-agent.natsToken" -}}
{{- if not (hasKey .Values "_natsToken") -}}
{{- $t := .Values.controlBus.token | default "" -}}
{{- if not $t -}}
{{- $s := lookup "v1" "Secret" .Release.Namespace (include "w8s-agent.natsTokenSecretName" .) -}}
{{- if and $s $s.data -}}{{- $t = index $s.data "token" | default "" | b64dec -}}{{- end -}}
{{- end -}}
{{- if not $t -}}{{- $t = randAlphaNum 48 -}}{{- end -}}
{{- $_ := set .Values "_natsToken" $t -}}
{{- end -}}
{{- index .Values "_natsToken" -}}
{{- end }}
{{- define "w8s-agent.natsTokenEnv" -}}
- name: W8S_NATS_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ include "w8s-agent.natsTokenSecretName" . }}
      key: token
{{- end }}
{{- define "w8s-agent.joinSecretName" -}}{{ if .Values.joinToken.existingSecret }}{{ .Values.joinToken.existingSecret }}{{ else }}{{ printf "%s-join-token" (include "w8s-agent.fullname" .) }}{{ end }}{{- end }}
{{/*
W3T-56: cloudflared.deploymentName/tunnelResourceName and gateway.name used
to be fixed literals ("cloudflared"/"w8s-gateway"), so any two agent chart
installs landing in the same physical cluster's w8s-system namespace (the
chart's fixed default target namespace) collided on these exact object
names, regardless of cluster_id. Empty (the new default, see values.yaml)
means "derive from this release" - same override-if-set, else-derive-from-
.Release.Name pattern w8s-agent.fullname already uses for fullnameOverride,
so every release gets a distinct identity by default while still allowing a
fixed name for anyone who explicitly wants one (e.g. to intentionally
adopt/share an existing object).
*/}}
{{- define "w8s-agent.cloudflaredDeploymentName" -}}{{ if .Values.cloudflared.deploymentName }}{{ .Values.cloudflared.deploymentName }}{{ else }}{{ printf "%s-cloudflared" .Release.Name | trunc 63 | trimSuffix "-" }}{{ end }}{{- end }}
{{- define "w8s-agent.tunnelResourceName" -}}{{ if .Values.cloudflared.tunnelResourceName }}{{ .Values.cloudflared.tunnelResourceName }}{{ else }}{{ printf "%s-cloudflared" .Release.Name | trunc 63 | trimSuffix "-" }}{{ end }}{{- end }}
{{- define "w8s-agent.gatewayName" -}}{{ if .Values.gateway.name }}{{ .Values.gateway.name }}{{ else }}{{ printf "%s-gateway" .Release.Name | trunc 63 | trimSuffix "-" }}{{ end }}{{- end }}
{{/*
The cluster's OTel Collector (W3T-191, templates/otel-collector.yaml): same
derive-from-release naming as the gateway/cloudflared objects above, so
the in-cluster OTLP endpoint a workload points at is
http://<release>-otel.<namespace>:4318 - http://w8s-agent-otel.w8s-system:4318
for the documented install.
*/}}
{{- define "w8s-agent.otelName" -}}{{ printf "%s-otel" .Release.Name | trunc 63 | trimSuffix "-" }}{{- end }}
{{/*
The spoke relay (W3T-198, templates/relay.yaml): <release>-relay, the
same derive-from-release naming as the gateway and cloudflared objects.
*/}}
{{- define "w8s-agent.relayName" -}}{{ printf "%s-relay" .Release.Name | trunc 63 | trimSuffix "-" }}{{- end }}
{{/*
The import DNS Service (W3T-199, templates/dns-service.yaml): what the
cluster's resolver forwards the cluster.<remote> zones to.
*/}}
{{- define "w8s-agent.dnsServiceName" -}}{{ printf "%s-dns" .Release.Name | trunc 63 | trimSuffix "-" }}{{- end }}
{{/*
An image reference from a values block with repository, tag and digest
(image and relay.image). A digest pins the exact image: the published
chart carries one per chart version, filled in when the chart is packaged
(k8s/pin-images.sh), so a chart version always runs the
binary it was released with. The tag stays in the reference for the
reader; the runtime pulls by digest. An empty digest (the source chart, or
an explicit override) falls back to the tag alone.
*/}}
{{- define "w8s-agent.imageRef" -}}
{{- if .digest -}}
{{ printf "%s:%s@%s" .repository (.tag | default "latest") .digest }}
{{- else -}}
{{ printf "%s:%s" .repository (.tag | default "latest") }}
{{- end -}}
{{- end }}
{{/*
The pull policy for the same block. An explicit pullPolicy wins. Otherwise
IfNotPresent for a digest (nothing can change under that reference),
Always for the moving `latest` tag (a node's cached copy may be a binary
that does not know the chart's new flags - GKE, 2026-09-20), and
IfNotPresent for any other tag.
*/}}
{{- define "w8s-agent.imagePullPolicy" -}}
{{- if .pullPolicy -}}
{{ .pullPolicy }}
{{- else if .digest -}}
IfNotPresent
{{- else if eq (.tag | default "latest") "latest" -}}
Always
{{- else -}}
IfNotPresent
{{- end -}}
{{- end }}

{{/*
"true" unless profile is relay: the relay profile (a Leapfrog org's own hub
in a cluster that is not the org's) renders nothing cluster-scoped and
nothing outside the release namespace - no CRDs, ClusterRoles, admission
policy, GatewayClass, collectors or DNS - only the agent, its relay and
NATS leaf, and a Role in the release namespace.
*/}}
{{- define "w8s-agent.clusterWide" -}}
{{- ne (.Values.profile | default "admin") "relay" -}}
{{- end }}
