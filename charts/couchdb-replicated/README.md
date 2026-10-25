# couchdb-replicated

Reference deployment: a database that takes writes in every cluster and
replicates between them slowly and incrementally over w8s exported
Services, with a small app published active/active in front of it.

One CouchDB per cluster. Each one pulls the others' changes through the
Service w8s imports for them: directly between the clusters' relays
when NAT punch-through works, through the hub relay otherwise
(`docs/direct-connectivity.md`). Nothing needs a shared network, a VPN or
an open port.

## Why CouchDB

Traffic can land on any site, and a site can be cut off for a long time, so
every site has to accept writes on its own and reconcile afterwards. That
rules out anything built on quorum (CockroachDB, YugabyteDB, Galera,
Postgres with synchronous replicas): a site that cannot reach a majority
stops taking writes. It also rules out anything whose nodes gossip with
each other by address (Cassandra, Scylla, CouchDB's own clustering):
w8s gives one Service per export, never a peer's pod IPs.

CouchDB replication fits what the tunnel offers:

- It is plain HTTP to one URL per peer, which is exactly one imported
  Service.
- It is incremental and checkpointed. A dropped tunnel (a direct path lost,
  a relay restarting) resumes from the last checkpoint, not from zero.
- Its connections are short-lived and reopened. New connections take the
  direct path once w8s has punched one; a long-lived replication stream
  would stay relayed through the hub for its whole life.
- Concurrent edits at two sites are kept as a conflict, not lost. Every
  site picks the same winning revision without talking to the others, and
  keeps the losing ones until someone resolves them.

## What it installs, per cluster

| Object | What for |
|---|---|
| StatefulSet `<release>-couchdb` | one CouchDB node, and a `replication` sidecar that keeps `_replicator` pulling from exactly the configured peers (`files/wire-replication.sh`) |
| Service `couchdb` + `ServiceExport` | what the other clusters pull from |
| Deployment + Service `<release>-guestbook` | nginx serving the page and a narrow API onto CouchDB; the admin credentials stay in the pod |
| HTTPRoute (when `app.hostname` is set) | the same hostname in every cluster, so w8s serves it from all of them |
| NetworkPolicy (when `isolate=true`) | the partition drill |

The sidecar derives everything from values on every pass
(`replication.reconcileSeconds`). It writes one replication document per
peer and deletes any it does not own. It also restarts a pull the moment
its peer answers again, instead of waiting out CouchDB's retry backoff,
which grows with each failure.

## Install

From the w8s app: **Apps → Reference architectures → Replicated
CouchDB**. Pick the clusters, a namespace and optionally a hostname. The
page declares one app deployment per cluster on the hub
(`couchdb-<cluster>`), each told its own id and the others as peers, with
a generated password shared by all of them. Each cluster's agent keeps it
installed from then on, and a cluster that is offline gets its site when
it connects (docs/app-deployments.md). The agent installs the chart from
`oci://oci.w8s.cloud/charts/couchdb-replicated`, which ops/release-public
publishes.

Either way, every cluster needs the w8s agent chart (it brings the
Multi-Cluster Services CRDs and the relay). By hand, use the same
namespace and credentials in every cluster:

```sh
# once per cluster, the same value everywhere
kubectl create namespace guestbook
kubectl -n guestbook create secret generic couchdb-auth \
  --from-literal=username=admin --from-literal=password="$SHARED_PASSWORD"

# cluster edge-a
helm install gb charts/couchdb-replicated -n guestbook \
  --set clusterId=edge-a --set 'peers={edge-b,edge-c}' \
  --set auth.existingSecret=couchdb-auth --set app.hostname=guestbook.example.com

# cluster edge-b
helm install gb charts/couchdb-replicated -n guestbook \
  --set clusterId=edge-b --set 'peers={edge-a,edge-c}' \
  --set auth.existingSecret=couchdb-auth --set app.hostname=guestbook.example.com

# cluster edge-c: likewise
```

`clusterId` and `peers` are w8s cluster ids, as on the Clusters page. A
peer's CouchDB is reached at `couchdb--<namespace>--<peer>.w8s-system`, the
name the w8s agent gives its import. When that name would be over 63
characters, the agent uses a hashed name instead. The chart then stops
and asks for `replication.peerHosts.<peer>`, which you can read off the
cluster's Services page.

A cluster can be installed before its peers: its pulls retry until the
peers' exports appear.

## Seeing it work

Open the hostname (or `kubectl port-forward svc/gb-guestbook 8080:80`).
The page shows which cluster answered, the entries with the site each one
was written at, the shared banner, and the state of each pull into that
site.

To partition a site:

```sh
helm upgrade gb charts/couchdb-replicated -n guestbook --reuse-values --set isolate=true
```

Then, while it is partitioned:

1. Write entries at both the isolated site and another site.
2. Change the banner at both.

The isolated site's pulls go to `crashing`; the other sites keep
replicating with each other. Heal it with `--set isolate=false`. Within a
reconcile pass or two, every site has every entry, and the banner shows
the same winner and the same conflict at all three. "Keep this" at any
one site resolves it everywhere. The drill needs a CNI that enforces
NetworkPolicy (k3s, Calico and Cilium do).

## Tests

`test/docker-three-sites.sh` runs the chart's own files against three
real CouchDB containers on one Docker host. A shared Docker network
stands in for the tunnels: each site's CouchDB answers there under the
name w8s would give its import, and disconnecting a site from it is the
partition. It checks seven things:

1. A write reaches every site.
2. Each site runs one pull per peer.
3. A partitioned site keeps taking writes, and the others keep
   replicating with each other.
4. After healing, all sites catch up and show the same conflict.
5. Resolving the conflict at one site clears it everywhere.
6. A hand-deleted replication document comes back.
7. Removing a peer removes its pull.

```sh
charts/couchdb-replicated/test/docker-three-sites.sh   # about a minute
```

It does not exercise w8s itself: no relays, no NAT, no hub.

## Limits

- **Relayed traffic is readable by the hub, including the credentials.**
  Replication is plain HTTP with basic auth. On a relayed path the hub
  terminates QUIC on both legs, so it can read the traffic, credentials
  included (direct-connectivity.md §5.5). A direct path is TLS between the
  two relays. CouchDB's own TLS on the exported port would close this
  gap; this chart does not set it up yet.
- **The guestbook API is open to anyone who reaches the hostname.** It is a
  demo: it can add entries and edit or resolve the banner, nothing else.
  Put it behind access control before using it for anything real.
- **One CouchDB node per site.** The sites are the replicas. A site's own
  high availability would be CouchDB clustering inside that cluster, which
  this chart does not do.
- **With `replication.continuous=false`**, each pass runs one-shot pulls
  and waits for them. This is the most batch-like shape. It was checked
  by hand against two containers, not by the test script.
