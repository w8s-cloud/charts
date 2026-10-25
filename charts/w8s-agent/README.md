# w8s-agent

Installs the w8s edge agent into a Kubernetes cluster: it dials the hub relay over
QUIC, applies the Gateway API resources published services need, and reconciles the
`CloudflareTunnel` connector.

## Prerequisites

- Any conformant Kubernetes cluster (managed, k3s, kind).
- Nothing else — the chart's `envoy-gateway` dependency (`envoy-gateway.enabled: true`
  by default) installs both the upstream Gateway API CRDs and the Envoy Gateway
  controller, so a bare cluster is enough.
  - If you set `envoy-gateway.enabled: false` because the cluster already runs a
    different Gateway API implementation, you're responsible for the CRDs and a
    working controller being present yourself. If they aren't, the agent fails at
    startup with an explicit "Gateway API CRDs are not installed" error rather than
    a raw Kubernetes API error — see `ensure_gateway` in `crates/w8s-agent/src/cloudflared.rs`.

## Install

```sh
helm install w8s-agent oci://oci.w8s.cloud/charts/w8s-agent \
  --set joinToken.value=<your join token>
```

## Trust

The cluster's relay verifies our iroh relay's certificate against the system
roots plus the CA bundle in `certificates.caBundle` (default: ISRG Root X1, the
Let's Encrypt root behind `relay.w8s.cloud`), which the chart writes into a
`<release>-relay-ca` Secret. Set `certificates.existingSecret` to use your own
Secret instead, for example a private CA from `generate_ca.sh` for a hub of your
own. Where the hub is comes with the join token; nothing else is configured.

## Values

See `values.yaml` for the full list. The ones worth knowing about up front:

| Key | Default | Notes |
| --- | --- | --- |
| `image.repository` | `oci.w8s.cloud/w8s/w8s-agent` | A separate public registry (docs/public-registry.md), anonymous-pull by construction - not `registry.w8s.cloud`, the hub's own private CI registry. `imagePullSecrets` exists for a private mirror. |
| `certificates.existingSecret` | empty | Empty renders a Secret from `certificates.caBundle`; set it to bring your own CA. |
| `joinToken.value` / `joinToken.existingSecret` | — | One of these must be set; there is no default token. |
| `envoy-gateway.enabled` | `true` | Set to `false` only if the cluster already has a working Gateway API implementation. |
| `envoy-gateway.crds.enabled` | `true` | Set to `false` on clusters whose provider owns the Gateway API CRDs (GKE). Then also enable `envoy-gateway-crds.enabled`. |
| `envoy-gateway-crds.enabled` | `false` | Installs only Envoy Gateway's own CRDs (`gateway.envoyproxy.io`), for use with `envoy-gateway.crds.enabled=false`. Never enable both. |

## GKE

GKE clusters with Gateway API enabled own the standard-channel Gateway API CRDs and
reject any other copy. Install with:

```sh
helm upgrade --install w8s-agent oci://oci.w8s.cloud/charts/w8s-agent \
  --namespace w8s-system --create-namespace \
  --set joinToken.value=<your join token> \
  --set envoy-gateway.crds.enabled=false \
  --set envoy-gateway-crds.enabled=true
```

Run that command twice the first time. The first run installs Envoy Gateway's own
CRDs; the `ClientTrafficPolicy` that strips the `Server` header is skipped until a run
where its CRD is already served (Helm validates the manifest before applying it), so
the second run adds it. GKE's own Gateway API CRDs are never touched.
