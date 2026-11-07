{{/*
w8s-artifacts: the experiment artifact contract (w8s docs/experiments.md §3).

A chart lists this one as a dependency and, in the pod spec of the Job
that does the work:

  volumes:
    {{- include "w8s-artifacts.volumes" . | nindent 4 }}
  containers:
    - name: work
      volumeMounts:
        {{- include "w8s-artifacts.mount" . | nindent 8 }}
      # write outputs to /artifacts, then end with
      #   echo $? > /artifacts/.w8s-exit
    {{- include "w8s-artifacts.uploader" . | nindent 4 }}

The uploader waits for /artifacts/.w8s-exit, adds inputs.json, and copies
everything to
  <bucket>/<prefix>/<org>/<experiment>/<UTC start time>/
It reads its settings from the including chart's `.Values.artifacts`
(see values.example.yaml in this chart).
*/}}

{{- define "w8s-artifacts.validate" -}}
{{- $a := .Values.artifacts | default dict -}}
{{- range $k := list "bucket" "endpoint" "existingSecret" "experiment" -}}
{{- if not (index $a $k) -}}
{{- fail (printf "artifacts.%s is required (w8s-artifacts)" $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Where a run's objects go, without the start time the uploader adds. */}}
{{- define "w8s-artifacts.path" -}}
{{- $a := .Values.artifacts -}}
{{- $parts := list -}}
{{- with $a.prefix }}{{ $parts = append $parts (trimAll "/" .) }}{{ end -}}
{{- with $a.org }}{{ $parts = append $parts . }}{{ end -}}
{{- $parts = append $parts $a.experiment -}}
{{- join "/" $parts -}}
{{- end -}}

{{/* rclone's remote "bucket", configured from the environment. */}}
{{- define "w8s-artifacts.rcloneEnv" -}}
{{- $a := .Values.artifacts -}}
- name: RCLONE_CONFIG_BUCKET_TYPE
  value: s3
- name: RCLONE_CONFIG_BUCKET_PROVIDER
  value: {{ $a.provider | default "Other" | quote }}
- name: RCLONE_CONFIG_BUCKET_ENDPOINT
  value: {{ $a.endpoint | quote }}
- name: RCLONE_CONFIG_BUCKET_REGION
  value: {{ $a.region | default "us-east-1" | quote }}
- name: RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE
  value: {{ ne ($a.pathStyle | toString) "false" | quote }}
- name: RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ $a.existingSecret }}
      key: access-key-id
- name: RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $a.existingSecret }}
      key: secret-access-key
{{- end -}}

{{- define "w8s-artifacts.image" -}}
{{- (.Values.artifacts | default dict).image | default "rclone/rclone:1.68.2" -}}
{{- end -}}

{{- define "w8s-artifacts.volumes" -}}
- name: w8s-artifacts
  emptyDir: {}
{{- end -}}

{{- define "w8s-artifacts.mount" -}}
- name: w8s-artifacts
  mountPath: /artifacts
{{- end -}}

{{/*
The uploader. inputs.json says what produced the run: the experiment, the
chart and its version, the values' SHA-256 (never the values, which may
hold secrets), the start time and the job's exit code.
*/}}
{{- define "w8s-artifacts.uploader" -}}
{{- include "w8s-artifacts.validate" . -}}
- name: w8s-artifacts-uploader
  image: {{ include "w8s-artifacts.image" . }}
  command: ["/bin/sh", "-c"]
  args:
    - |
      set -eu
      start=$(date -u +%Y-%m-%dT%H-%M-%SZ)
      echo "waiting for /artifacts/.w8s-exit"
      until [ -f /artifacts/.w8s-exit ]; do sleep 5; done
      code=$(cat /artifacts/.w8s-exit)
      cat > /artifacts/inputs.json <<JSON
      {"experiment": "$W8S_EXPERIMENT", "chart": "$W8S_CHART", "valuesSha256": "$W8S_VALUES_SHA256", "startedAt": "$start", "exitCode": $code}
      JSON
      dest="bucket:$W8S_BUCKET/$W8S_PATH/$start/"
      echo "job exited $code; copying /artifacts to $dest"
      rclone copy /artifacts "$dest" --exclude .w8s-exit --no-update-modtime --stats-one-line -v
      echo "done: $dest"
  env:
    - name: W8S_EXPERIMENT
      value: {{ .Values.artifacts.experiment | quote }}
    - name: W8S_CHART
      value: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
    - name: W8S_VALUES_SHA256
      value: {{ .Values | toJson | sha256sum | quote }}
    - name: W8S_BUCKET
      value: {{ .Values.artifacts.bucket | quote }}
    - name: W8S_PATH
      value: {{ include "w8s-artifacts.path" . | quote }}
    {{- include "w8s-artifacts.rcloneEnv" . | nindent 4 }}
  volumeMounts:
    {{- include "w8s-artifacts.mount" . | nindent 4 }}
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits: { memory: 256Mi }
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    runAsUser: 65532
    capabilities: { drop: [ALL] }
    seccompProfile: { type: RuntimeDefault }
{{- end -}}

{{/*
An init container that copies one object from the bucket into /data, for
a job whose input lives in the same bucket. `object` is the key under the
bucket, e.g. "datasets/ci-runs.csv".
*/}}
{{- define "w8s-artifacts.fetch" -}}
- name: w8s-artifacts-fetch
  image: {{ include "w8s-artifacts.image" .root }}
  command: ["rclone", "copyto", {{ printf "bucket:%s/%s" .root.Values.artifacts.bucket .object | quote }}, {{ printf "/data/%s" (base .object) | quote }}, "-v"]
  env:
    {{- include "w8s-artifacts.rcloneEnv" .root | nindent 4 }}
  volumeMounts:
    - name: data
      mountPath: /data
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits: { memory: 256Mi }
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    runAsUser: 65532
    capabilities: { drop: [ALL] }
    seccompProfile: { type: RuntimeDefault }
{{- end -}}
