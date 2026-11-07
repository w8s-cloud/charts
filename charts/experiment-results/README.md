# experiment-results

Serves an experiments bucket (see `w8s-artifacts`) read-only over HTTP, so
a dashboard, a notebook or `curl` can read each run's files by URL. Every
request needs a bearer token.

Install it once and keep it. Experiments come and go; this stays.

```sh
helm install results oci://oci.w8s.cloud/charts/experiment-results -n experiments \
  --set artifacts.bucket=experiments,artifacts.endpoint=https://<s3 endpoint> \
  --set artifacts.existingSecret=experiment-bucket \
  --set hostname=results-<cluster slug>.w8s.cloud
```

With `hostname`, the chart applies an `HTTPRoute` that w8s publishes. The
token is generated once and kept. NOTES prints how to read it.

```
GET /                                   orgs (HTML listing)
GET /<org>/<experiment>/                runs, by UTC start time
GET /<org>/<experiment>/<run>/<file>    the file as stored
```

`rclone serve http` reads the bucket. In the same pod, nginx checks
`Authorization: Bearer <token>` and allows only `GET` and `HEAD`.
