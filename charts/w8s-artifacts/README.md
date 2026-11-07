# w8s-artifacts

A library chart. It adds the experiment artifact contract to a chart's
Job: the Job writes its outputs to `/artifacts`, and an uploader
container copies them to your own S3-compatible bucket when the Job ends,
whether it succeeded or failed.

Where the files land:

```
<bucket>/<prefix>/<org>/<experiment>/<UTC start time>/
  inputs.json      added by the uploader: chart, values SHA-256, start, exit code
  ...              whatever the job wrote
```

The convention, for tools that chart results:

- `metrics.csv`, one row per step or epoch;
- `summary.json`, the final numbers;
- `*.png`, plots;
- `model/`, the weights.

## Using it

```yaml
# Chart.yaml
dependencies:
  - name: w8s-artifacts
    version: 0.1.0
    repository: oci://oci.w8s.cloud/charts
```

In the Job's pod spec:

```yaml
containers:
  - name: work
    volumeMounts:
      {{- include "w8s-artifacts.mount" . | nindent 6 }}
    # ...and when the work is done, however it ended:
    #   echo $code > /artifacts/.w8s-exit
  {{- include "w8s-artifacts.uploader" . | nindent 2 }}
volumes:
  {{- include "w8s-artifacts.volumes" . | nindent 2 }}
```

`w8s-artifacts.fetch` is an init container that copies one object from
the same bucket into `/data`, for input data.

The including chart's `artifacts:` values name the bucket. See
`values.example.yaml`. The credential is a Secret you create in the
release's namespace, with the keys `access-key-id` and
`secret-access-key`.

Nothing here talks to w8s. The uploader is rclone's official image.
