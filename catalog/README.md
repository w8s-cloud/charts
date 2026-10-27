# The vetted chart catalog

One file per upstream Helm chart that the w8s Apps page offers as it
comes: `catalog/<id>.yaml`. The file name is the entry's id and its
directory under `vetted/`, so use lowercase letters, digits and `-`.

## Proposing a chart

Add one file here in a pull request. **Submit** on the w8s Apps page opens
GitHub's new-file page with the file filled in from a form. It is your
own pull request, from your own GitHub account.

```yaml
# catalog/valkey.yaml
artifacthub: valkey/valkey   # <repository>/<package> on artifacthub.io, when it is listed there
name: Valkey
tagline: One line for the card.
description: |
  A short paragraph for the entry's page: what it runs, and what it
  keeps on its volume.
tags: [Key/value, Cache]     # at most 8, each up to 30 characters
category: db                 # db, ai, messaging, observability, storage, web, security, business,
                             # project, productivity, knowledge, data, devtools or other
git: {repo: valkey-io/valkey-helm, path: valkey, ref: <commit or release tag>}
chart: {url: https://…/valkey-0.12.0.tgz, version: 0.12.0}   # an https:// archive or an oci:// reference
source: https://valkey.io
logo: https://raw.githubusercontent.com/…/logo.svg            # SVG or PNG, at most 256 KiB
logo_background: "#ffffff"   # optional: puts a one-colour logo on a tile of this colour
values: {dataStorage: {enabled: true, requestedSize: 5Gi}}    # what the deploy page starts from
```

`git:` is the chart's own `Chart.yaml` at a pinned ref: what was vetted.
Anything written in the entry wins over what that file says.

## What a chart needs

A chart is accepted when it installs as an ordinary app on any cluster:

- **It renders only app objects:**
  - Deployments, StatefulSets and Services;
  - ConfigMaps and Secrets;
  - PersistentVolumeClaims, ServiceAccounts and NetworkPolicies.
  
  The w8s agent does not install an operator, a CRD, a ClusterRole, a Job, a DaemonSet or a PodDisruptionBudget for an app, so a chart that renders one fails. Often a value turns it off: MinIO's `users: []` drops its post-install Job.
- **It keeps its data.** Most charts ship with persistence off, so a restart loses everything. Turn it on in `values:`.
- **It runs on its own.** It needs an embedded database, or a bundled one from an official image. A chart that needs a database you bring is a reference architecture, not a vetted chart. So is a chart whose bundled database is a Bitnami subchart: Bitnami stopped publishing free images in 2025.
- **It needs nothing typed in to start.** A vetted entry cannot ask for a client id or an identity provider.
- **Its version is pinned,** in `chart.version` and `git.ref`.

## What a maintainer does

1. Read the chart at its pinned ref.
2. Run `python3 tools/import_charts.py --out vetted --only <id> --check-kinds`. It needs helm and PyYAML. It renders the chart with the entry's values and refuses kinds an app may not create.
3. Commit the generated `vetted/<id>/` with the entry.

The w8s hub ships `vetted/` at the commit of this repository it pins, so a merged entry shows up with the next w8s release.

## Looked at and not accepted

Listed so nobody probes them again. Each was refused for the reason given, at the time; a chart that has changed since is worth another look.

- **Prometheus:** ClusterRole, ClusterRoleBinding and a DaemonSet. Victoria Metrics covers metrics.
- **NATS:** a PodDisruptionBudget. The `nats-supercluster` reference architecture covers it.
- **Zitadel:** Jobs for init and setup.
- **Gitea:** a Job.
- **passbolt-ha:** a Pod, a PDB and a Role.
- **flame:** a ClusterRole.
- **keydb:** its values schema refuses its defaults.
- **oauth2-proxy:** needs a client id, a secret and an identity provider.
- **paperless-ngx:** bundles Bitnami's Redis.
- **miniflux:** bundles Bitnami's Postgres, and cannot run without one.
- **bookstack, monica, baserow, shlink-backend, tandoor, wordpress:** need a MySQL or Postgres you bring.
- **kutt, polr, typo3, umami:** a PodDisruptionBudget and a database each.
- **ProxySQL, Podgrab:** no logo under 256 KiB.
- **CloudNativePG:** an operator.
