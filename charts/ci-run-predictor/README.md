# ci-run-predictor

An experiment. It trains a small neural network (PyTorch, on CPU) on a CSV
of CI runs, to predict a run's duration and whether it fails from what is
known when it starts: pipeline, main or branch, push or manual, hour,
weekday and number of steps.

The newest 20% of runs are held out for validation. The run's
`summary.json` compares the network with a baseline that uses each
pipeline's median duration and failure rate.

The run writes, using `w8s-artifacts`:
- `metrics.csv` (per epoch);
- `summary.json`;
- `predictions.csv` (each validation run: actual, predicted, baseline);
- `loss.png` and `duration.png`;
- `model/model.pt`;
- `train.log`.

## Try it

You need a bucket (any S3 API), and a Secret named `experiment-bucket`
with the keys `access-key-id` and `secret-access-key` in the namespace.
Without a bucket of your own, `examples/demo-bucket.yaml` is a stand-in:
rclone's S3 server on a 5 GiB volume.

```sh
kubectl create namespace experiments
kubectl -n experiments create secret generic experiment-bucket \
  --from-literal=access-key-id=experiments \
  --from-literal=secret-access-key="$(openssl rand -hex 20)"
kubectl apply -f examples/demo-bucket.yaml

# the data: a CSV at <bucket>/datasets/ci-runs.csv, with columns
# created_at,pipeline,branch,trigger,hour_utc,weekday,steps,duration_s,failed
kubectl -n experiments exec -i deploy/demo-bucket -- \
  sh -c 'mkdir -p /data/experiments/datasets && cat > /data/experiments/datasets/ci-runs.csv' < ci-runs.csv

# the results server, once
helm install results ../experiment-results -n experiments \
  -f examples/demo-bucket-values.yaml --set hostname=results-<slug>.w8s.cloud

# an experiment: deploy, wait, tear down
helm install ci-run-predictor . -n experiments -f examples/demo-bucket-values.yaml
kubectl -n experiments wait --for=condition=complete job/ci-run-predictor --timeout=15m
helm uninstall ci-run-predictor -n experiments

# the results outlive it
TOKEN=$(kubectl -n experiments get secret results-token -o jsonpath='{.data.token}' | base64 -d)
curl -H "Authorization: Bearer $TOKEN" https://results-<slug>.w8s.cloud/w3t/ci-run-predictor/
```

To try other settings, deploy again with `--set train.epochs=600` (or
`train.hidden`, `train.learningRate`). Each run gets its own folder.

On GKE Autopilot, the Job requests 4 GiB of ephemeral storage, because
the pip install of torch does not fit in the default 1 GiB.
