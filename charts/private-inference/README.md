# private-inference

Reference deployment: an LLM that runs on the GPUs in one of your clusters
and is used from all the others, over w8s exported Services. The model,
the prompts and the answers stay on your own clusters, with no public
endpoint and no third-party API.

One cluster runs [Ollama](https://ollama.com) on its GPU (`role: gpu`)
and exports a small gateway in front of it. Every cluster that uses the
model runs the client side (`role: client`), which is an in-cluster
endpoint that apps call by name, plus a chat page. The client side reaches
the GPU cluster through the Service w8s imports for it: directly between
the clusters' relays when NAT punch-through works, and through the hub
relay otherwise (`docs/direct-connectivity.md`). A cluster that has its
own GPU and also wants the chat page uses `role: both`.

```
 edge-a                       gpu-home (role: gpu)
 ┌───────────────────────┐    ┌──────────────────────────────────┐
 │ app ─▶ inference:80 ──┼─w8s─┼▶ inference-gpu:80 ─▶ ollama (GPU) │
 │        (adds the key) │    │  (checks the key)                │
 └───────────────────────┘    └──────────────────────────────────┘
```

## What it installs

| Role | Object | What for |
|---|---|---|
| gpu, both | Deployment `<release>-ollama` | Ollama on `127.0.0.1` only; a `models` sidecar that keeps `ollama.models` pulled (`files/models.sh`); and the `gateway` nginx, the only way in, which refuses any request without the shared key |
| gpu, both | PVC `<release>-models` | the pulled models. It is kept when the release is uninstalled (`helm.sh/resource-policy: keep`), so a reinstall does not download them again |
| gpu, both | Service `inference-gpu` | the gateway |
| gpu | `ServiceExport` | what the other clusters reach |
| client, both | Deployment + Service `inference` | nginx that adds the key and forwards `/api/...` (Ollama's API) and `/v1/...` (OpenAI-compatible) to the GPU cluster, and serves the chat page at `/` |
| client, both | Deployment + Service `open-webui`, PVC `<release>-open-webui` (when `client.openWebui.enabled`) | [Open WebUI](https://openwebui.com) as the chat page, using `inference` as its Ollama. Accounts and chats are on the PVC, which is kept on uninstall |
| client, both | HTTPRoute (when `client.hostname` is set) | publishes the chat page, and with it the API; with Open WebUI, publishes Open WebUI only, behind its sign-in |
| all | Secret `<release>-key` | the shared key, unless `apiKey.existingSecret` names one |

Apps in a client cluster call `http://inference.<namespace>.svc/v1/chat/completions`
with any OpenAI client library and no key. They never hold it, and the key
is never written into a ConfigMap: the nginx containers substitute it from
the Secret when they start (`files/40-render.sh`).

## Install

From the w8s app, go to **Apps → Reference architectures → Private GPU
inference**. Pick the GPU cluster, the clusters that use the model, a
namespace, the model, and optionally a hostname. The page declares one app
deployment per cluster on the hub (`inference-<cluster>`), with a generated
key that all of them share. Each cluster's agent keeps its deployment
installed from then on (docs/app-deployments.md). The agent installs the
chart from `oci://oci.w8s.cloud/charts/private-inference`.

By hand, every cluster needs the w8s agent chart, and the same namespace
and key everywhere:

```sh
# once per cluster, the same value everywhere
kubectl create namespace ai
kubectl -n ai create secret generic inference-key --from-literal=apiKey="$(openssl rand -hex 24)"

# the cluster with the GPU
helm install inference charts/private-inference -n ai \
  --set role=gpu --set apiKey.existingSecret=inference-key \
  --set 'ollama.models={llama3.2:3b}'

# every cluster that uses it
helm install inference charts/private-inference -n ai \
  --set role=client --set clusterId=edge-a --set client.gpuCluster=gpu-home \
  --set apiKey.existingSecret=inference-key
```

`clusterId` and `client.gpuCluster` are w8s cluster ids, as on the Clusters
page. The client reaches `inference-gpu--<namespace>--<gpu cluster>.w8s-system`,
which is the name the w8s agent gives the import. When that name would be
over 63 characters, the agent uses a hashed name instead, and the chart
stops and asks for `client.gpuHost`. You can read the hashed name off the
cluster's Services page.

The GPU node needs the NVIDIA device plugin (or the GPU operator), so that
`nvidia.com/gpu` is schedulable. Set `ollama.runtimeClassName=nvidia` when
the NVIDIA runtime is not the node's default, as on k3s. With
`ollama.gpus=0`, Ollama runs on CPU. That is slow, but it works on any
cluster, which makes it a way to try this without a GPU.

The first start pulls the models, which takes minutes for a few GB:

```sh
kubectl -n ai logs deploy/inference-ollama -c models -f
```

## Seeing it work

In a client cluster, open the hostname, or
`kubectl -n ai port-forward svc/inference 8080:80` and then
http://localhost:8080. The chat page streams the answer. It shows which
cluster served the page and which one ran the model, and the time to the
first token and the tokens per second, which show whether the path is
direct or relayed. From an app:

```sh
curl http://inference.ai.svc/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"Hello"}]}'
```

## Tests

`test/docker-sites.sh` runs the chart's own nginx files on one Docker host
in front of a stub that stands in for Ollama, so no GPU and no model
download are needed. A Docker network stands in for the tunnel. It checks
six things:

1. The gateway refuses a request with no key or a wrong one.
2. The key is not passed on to Ollama.
3. The client adds the key for `/api` and `/v1`, and serves nothing else.
4. Tokens stream through both proxies, rather than arriving at the end.
5. The client serves the chat page, and says which cluster answered.
6. The render hook refuses a key that it could not substitute safely.

```sh
charts/private-inference/test/docker-sites.sh   # about fifteen seconds
```

It does not run Ollama or a model, and it does not exercise w8s itself:
there are no relays, no NAT and no hub.

## Limits

- **Relayed traffic is readable by the hub, including the key.** Between
  the clusters this is plain HTTP with a bearer key. On a relayed path the
  hub terminates QUIC on both legs, so it can read prompts, answers and
  the key (direct-connectivity.md §5.5). A direct path is TLS between the
  two relays. TLS on the gateway would close this gap; this chart does not
  set it up yet.
- **A published hostname is open.** Anyone who can reach `client.hostname`
  can use the model, because the client side adds the key for them. Leave
  it empty, or put it behind access control.
- **One GPU cluster.** There is no failover to a second GPU cluster, and no
  spreading of load across two. Each client points at one `gpuCluster`.
- **One Ollama replica.** It serves requests concurrently up to its own
  limits (`OLLAMA_NUM_PARALLEL`), and queues the rest.
- **Models are only added.** Removing a model from `ollama.models` does not
  delete it from the volume.
