# Vetted charts

Generated. Do not edit by hand.

One directory per upstream Helm chart that w8s offers as it comes: a
version somebody checked, with the values a cluster that should keep its
data needs. Each holds the same `architecture.yaml` and logo a hand-written
entry has, so the app renders every card the same way, plus the chart's own
files where the importer could read them:

| File | What |
|---|---|
| `architecture.yaml` | The entry: what it is, its chart, and the values w8s starts you on |
| `logo.svg` / `logo.png` | The card's logo |
| `values.yaml` | The chart's own defaults, as published - every key it takes, usually commented |
| `values.schema.json` | The chart's JSON Schema for those values, when it ships one (one chart in fifteen does) |

The last two are copied out of the chart archive, unchanged. They are what
the deploy page shows somebody who wants to know what a chart takes, so a
chart that will not give them up still gets a card - it just has less to
show.

These are built from `catalog/<id>.yaml`:

```sh
python3 tools/import_charts.py --out vetted
```

Change the entry in `catalog/`, re-run that, read the diff, commit it.
Editing a file here directly is lost the next time anyone rebuilds.

The w8s hub ships this directory in its image, at the commit of this
repository it pins, and shows it as **Vetted charts**: a section of its
own. The other half of the catalog,
[w8s-cloud/reference-architectures](https://github.com/w8s-cloud/reference-architectures),
is written for w8s and spans several clusters.
