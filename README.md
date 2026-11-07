# w8s charts

The Helm charts behind [w8s.cloud](https://w8s.cloud), published to
`oci://oci.w8s.cloud/charts`.

| Chart | What it is |
|---|---|
| [`w8s-agent`](charts/w8s-agent) | What you install in a cluster to connect it to w8s: the agent, its relay, a NATS leaf, Envoy Gateway and an OpenTelemetry Collector. |
| [`couchdb-replicated`](charts/couchdb-replicated) | A CouchDB per cluster, replicating between clusters over w8s exported Services, with a small app in front. The *CouchDB* reference architecture. |
| [`private-inference`](charts/private-inference) | An LLM on the GPUs of one cluster, used by name from all the others over exported Services. The *Inference* reference architecture. |
| [`w8s-artifacts`](charts/w8s-artifacts) | A library chart for experiments: the Job writes to `/artifacts`, and an uploader copies it to your own S3 bucket when the Job ends. |
| [`experiment-results`](charts/experiment-results) | Serves an experiments bucket read-only over HTTP behind a bearer token, for dashboards and notebooks. |
| [`ci-run-predictor`](charts/ci-run-predictor) | An experiment: a small PyTorch network trained on CI runs to predict duration and failure. |

Install the agent with the command the w8s app shows under **Clusters →
Connect a cluster**, or see the [documentation](https://docs.w8s.cloud).
The reference architectures that deploy the other two are in
[w8s-cloud/reference-architectures](https://github.com/w8s-cloud/reference-architectures).

## Licence

Apache-2.0 (`LICENSE`). Each chart's dependencies keep their own licences.
