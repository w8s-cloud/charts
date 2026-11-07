"""Train a small network on CI runs: predict a run's duration and whether
it fails, from what is known when it starts.

Usage: train.py <runs.csv> <artifacts dir>

Writes, per the w8s-artifacts convention:
  metrics.csv      one row per epoch
  summary.json     final numbers, the network's and a baseline's
  predictions.csv  every validation run: actual and predicted
  loss.png, duration.png
  model/model.pt   the weights and the feature encoding

and, to look inside the network:
  network.json     its layers, sizes and input names
  weights.csv      every weight: layer, from, to, value
  layers.csv       per epoch and layer: weight norm, gradient norm, dead units
  units.csv        each hidden unit: mean activation, share of runs it fires
                   on, and its weight into each head
  importance.csv   per input group: how much worse the network gets when
                   that input is shuffled (permutation importance)
  embedding.csv    every run's last hidden layer, projected to 2-D (PCA)
  network.png      the network drawn with its strongest connections
"""
import csv, json, math, os, sys, time

import numpy as np
import torch
from torch import nn

src, out = sys.argv[1], sys.argv[2]
epochs = int(os.environ.get("EPOCHS", 300))
hidden_size = int(os.environ.get("HIDDEN", 64))
lr = float(os.environ.get("LR", 0.003))
val_share = float(os.environ.get("VAL_SHARE", 0.2))
seed = int(os.environ.get("SEED", 7))
torch.manual_seed(seed)
np.random.seed(seed)

max_duration = float(os.environ.get("MAX_DURATION_S", 6 * 3600))
rows = list(csv.DictReader(open(src)))
# A run's record can be touched long after it ended; past max_duration a
# "duration" says nothing about the run, so it is left out (and counted).
dropped = sum(float(r["duration_s"]) > max_duration for r in rows)
rows = [r for r in rows if float(r["duration_s"]) <= max_duration]
rows.sort(key=lambda r: int(r["created_at"]))
cut = int(len(rows) * (1 - val_share))
train_rows, val_rows = rows[:cut], rows[cut:]
print(f"{len(rows)} runs: {len(train_rows)} to train on, the newest {len(val_rows)} to validate")

# --- Features: only what is known when a run starts -------------------------
pipelines = sorted({r["pipeline"] for r in train_rows})
cats = {
    "pipeline": pipelines + ["(other)"],
    "branch": ["main", "branch"],
    "trigger": sorted({r["trigger"] for r in train_rows}) + ["(other)"],
    "weekday": [str(d) for d in range(7)],
}


def onehot(name, value):
    vals = cats[name]
    v = [0.0] * len(vals)
    v[vals.index(value) if value in vals else len(vals) - 1] = 1.0
    return v


def feature_names():
    names = [f"{name}={v}" for name in cats for v in cats[name]]
    return names + ["hour_sin", "hour_cos", "steps"]


def features(r):
    h = int(r["hour_utc"])
    x = []
    for name in cats:
        x += onehot(name, r[name])
    x += [math.sin(2 * math.pi * h / 24), math.cos(2 * math.pi * h / 24), float(r["steps"])]
    return x


def tensors(rs):
    x = torch.tensor([features(r) for r in rs], dtype=torch.float32)
    dur = torch.tensor([math.log(float(r["duration_s"])) for r in rs], dtype=torch.float32)
    fail = torch.tensor([float(r["failed"]) for r in rs], dtype=torch.float32)
    return x, dur, fail


xt, dt, ft = tensors(train_rows)
xv, dv, fv = tensors(val_rows)
mu, sd = xt.mean(0), xt.std(0)
# A column that never varies in training (a category only newer runs
# have) is left unscaled: dividing by its ~0 spread blows validation up.
sd = torch.where(sd < 1e-3, torch.ones_like(sd), sd)
xt, xv = (xt - mu) / sd, (xv - mu) / sd


class Net(nn.Module):
    """A shared body with two heads: log-duration and failure logit."""

    def __init__(self, n_in, n_hidden):
        super().__init__()
        self.body = nn.Sequential(
            nn.Linear(n_in, n_hidden), nn.ReLU(), nn.Dropout(0.1),
            nn.Linear(n_hidden, n_hidden), nn.ReLU(),
        )
        self.duration = nn.Linear(n_hidden, 1)
        self.failure = nn.Linear(n_hidden, 1)

    def forward(self, x):
        h = self.body(x)
        return self.duration(h).squeeze(-1), self.failure(h).squeeze(-1)


net = Net(xt.shape[1], hidden_size)
opt = torch.optim.Adam(net.parameters(), lr=lr, weight_decay=1e-4)
mse, bce = nn.MSELoss(), nn.BCEWithLogitsLoss()


def evaluate(x, d, f):
    net.eval()
    with torch.no_grad():
        pd, pf = net(x)
        loss = (mse(pd, d) + bce(pf, f)).item()
        mae = (pd.exp() - d.exp()).abs().mean().item()
        acc = ((pf > 0).float() == f).float().mean().item()
    return loss, mae, acc, pd.exp(), torch.sigmoid(pf)


# The Linear layers, by the names the outputs use.
LAYERS = {"input->h1": net.body[0], "h1->h2": net.body[3],
          "h2->duration": net.duration, "h2->failure": net.failure}


def hidden(x):
    """The two hidden layers' activations, with dropout off."""
    net.eval()
    with torch.no_grad():
        h1 = torch.relu(net.body[0](x))
        h2 = torch.relu(net.body[3](h1))
    return h1, h2


metrics, layer_stats = [], []
t0 = time.time()
for epoch in range(1, epochs + 1):
    net.train()
    opt.zero_grad()
    pd, pf = net(xt)
    loss = mse(pd, dt) + bce(pf, ft)
    loss.backward()
    grads = {n: l.weight.grad.norm().item() for n, l in LAYERS.items()}
    opt.step()
    h1, h2 = hidden(xt)
    dead = {"input->h1": (h1.max(0).values == 0).float().mean().item(),
            "h1->h2": (h2.max(0).values == 0).float().mean().item()}
    for n, l in LAYERS.items():
        layer_stats.append(dict(epoch=epoch, layer=n, weight_norm=round(l.weight.norm().item(), 5),
                                grad_norm=round(grads[n], 6), dead_units_share=round(dead.get(n, 0.0), 4)))
    val_loss, val_mae, val_acc, _, _ = evaluate(xv, dv, fv)
    metrics.append(dict(epoch=epoch, loss=round(loss.item(), 5), val_loss=round(val_loss, 5),
                        val_duration_mae_s=round(val_mae, 2), val_failure_accuracy=round(val_acc, 4)))
    if epoch % 25 == 0 or epoch == 1:
        print(f"epoch {epoch:4d}  loss {loss.item():.4f}  val_loss {val_loss:.4f}  "
              f"val MAE {val_mae:7.1f}s  val accuracy {val_acc:.3f}")

# --- A baseline to beat: each pipeline's median duration and failure rate ---
by_pipe = {}
for r in train_rows:
    by_pipe.setdefault(r["pipeline"], []).append(r)
all_d = sorted(float(r["duration_s"]) for r in train_rows)
all_f = sum(int(r["failed"]) for r in train_rows) / len(train_rows)


def baseline(r):
    rs = by_pipe.get(r["pipeline"])
    if not rs:
        return all_d[len(all_d) // 2], all_f
    ds = sorted(float(x["duration_s"]) for x in rs)
    return ds[len(ds) // 2], sum(int(x["failed"]) for x in rs) / len(rs)


base = [baseline(r) for r in val_rows]
base_mae = float(np.mean([abs(b[0] - float(r["duration_s"])) for b, r in zip(base, val_rows)]))
base_acc = float(np.mean([(b[1] > 0.5) == (r["failed"] == "1") for b, r in zip(base, val_rows)]))

_, mae, acc, pred_d, pred_f = evaluate(xv, dv, fv)
summary = {
    "runs": len(rows), "dropped_over_max_duration": dropped, "max_duration_s": max_duration,
    "train": len(train_rows), "validation": len(val_rows),
    "epochs": epochs, "hidden": hidden_size, "learning_rate": lr, "seed": seed,
    "seconds": round(time.time() - t0, 1),
    "network": {"duration_mae_s": round(mae, 1), "failure_accuracy": round(acc, 4)},
    "baseline_per_pipeline": {"duration_mae_s": round(base_mae, 1), "failure_accuracy": round(base_acc, 4)},
    "failure_rate_validation": round(fv.mean().item(), 4),
}
print(json.dumps(summary, indent=2))

os.makedirs(f"{out}/model", exist_ok=True)
with open(f"{out}/metrics.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(metrics[0]))
    w.writeheader()
    w.writerows(metrics)
with open(f"{out}/summary.json", "w") as fh:
    json.dump(summary, fh, indent=2)
with open(f"{out}/predictions.csv", "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["created_at", "pipeline", "branch", "duration_s", "predicted_duration_s",
                "baseline_duration_s", "failed", "predicted_failure_p", "baseline_failure_p"])
    for r, d, p, b in zip(val_rows, pred_d.tolist(), pred_f.tolist(), base):
        w.writerow([r["created_at"], r["pipeline"], r["branch"], r["duration_s"], round(d, 1),
                    round(b[0], 1), r["failed"], round(p, 4), round(b[1], 4)])
torch.save({"state_dict": net.state_dict(), "categories": cats, "mean": mu, "std": sd,
            "hidden": hidden_size}, f"{out}/model/model.pt")

# --- Inside the network ----------------------------------------------------
in_names = feature_names()
h1_names = [f"h1.{i}" for i in range(hidden_size)]
h2_names = [f"h2.{i}" for i in range(hidden_size)]
ends = {"input->h1": (in_names, h1_names), "h1->h2": (h1_names, h2_names),
        "h2->duration": (h2_names, ["duration"]), "h2->failure": (h2_names, ["failure"])}

with open(f"{out}/network.json", "w") as fh:
    json.dump({
        "inputs": in_names,
        "layers": [{"name": n, "from": len(ends[n][0]), "to": len(ends[n][1]),
                    "activation": "relu" if n in ("input->h1", "h1->h2") else
                    ("exp (log-seconds)" if n == "h2->duration" else "sigmoid")} for n in LAYERS],
        "dropout_after_h1": 0.1,
        "parameters": sum(p.numel() for p in net.parameters()),
    }, fh, indent=2)

with open(f"{out}/weights.csv", "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["layer", "from", "to", "weight"])
    for n, l in LAYERS.items():
        src_names, dst_names = ends[n]
        for j, row in enumerate(l.weight.detach().tolist()):
            for i, v in enumerate(row):
                w.writerow([n, src_names[i], dst_names[j], round(v, 5)])

with open(f"{out}/layers.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(layer_stats[0]))
    w.writeheader()
    w.writerows(layer_stats)

x_all = torch.cat([xt, xv])
h1_all, h2_all = hidden(x_all)
with open(f"{out}/units.csv", "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["layer", "unit", "mean_activation", "active_share", "to_duration", "to_failure"])
    for layer, h, names in (("h1", h1_all, h1_names), ("h2", h2_all, h2_names)):
        for k, name in enumerate(names):
            to_d = net.duration.weight[0, k].item() if layer == "h2" else ""
            to_f = net.failure.weight[0, k].item() if layer == "h2" else ""
            w.writerow([layer, name, round(h[:, k].mean().item(), 5),
                        round((h[:, k] > 0).float().mean().item(), 4),
                        to_d if to_d == "" else round(to_d, 5), to_f if to_f == "" else round(to_f, 5)])

# Permutation importance: shuffle one input group across the validation
# runs and see how much the network's answers get worse.
groups = {}
for k, name in enumerate(in_names):
    groups.setdefault(name.split("=")[0].replace("_sin", "").replace("_cos", ""), []).append(k)
rng = torch.Generator().manual_seed(seed)
importance = []
for g, cols in groups.items():
    d_mae, d_acc = [], []
    for _ in range(10):
        xs = xv.clone()
        xs[:, cols] = xv[torch.randperm(len(xv), generator=rng)][:, cols]
        _, m, a, _, _ = evaluate(xs, dv, fv)
        d_mae.append(m - mae)
        d_acc.append(acc - a)
    importance.append(dict(input=g, columns=len(cols),
                           duration_mae_increase_s=round(float(np.mean(d_mae)), 1),
                           failure_accuracy_drop=round(float(np.mean(d_acc)), 4),
                           first_layer_weight_norm=round(net.body[0].weight[:, cols].norm().item(), 4)))
importance.sort(key=lambda r: -r["duration_mae_increase_s"])
with open(f"{out}/importance.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(importance[0]))
    w.writeheader()
    w.writerows(importance)

# The last hidden layer is what both heads see: project it to 2-D.
h2n = h2_all.numpy()
h2c = h2n - h2n.mean(0)
_, sv, vt = np.linalg.svd(h2c, full_matrices=False)
pcs = h2c @ vt[:2].T
explained = (sv[:2] ** 2 / max((sv ** 2).sum(), 1e-12)).tolist()
net.eval()
with torch.no_grad():
    emb_d, emb_f = net(x_all)
with open(f"{out}/embedding.csv", "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["split", "created_at", "pipeline", "branch", "duration_s", "failed",
                "predicted_duration_s", "predicted_failure_p", "pc1", "pc2"])
    for k, r in enumerate(train_rows + val_rows):
        w.writerow(["train" if k < len(train_rows) else "validation", r["created_at"], r["pipeline"],
                    r["branch"], r["duration_s"], r["failed"], round(emb_d[k].exp().item(), 1),
                    round(torch.sigmoid(emb_f[k]).item(), 4), round(float(pcs[k, 0]), 4),
                    round(float(pcs[k, 1]), 4)])
summary["embedding_explained_variance"] = [round(e, 4) for e in explained]
summary["parameters"] = sum(p.numel() for p in net.parameters())
with open(f"{out}/summary.json", "w") as fh:
    json.dump(summary, fh, indent=2)

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

fig, ax = plt.subplots(figsize=(7, 4))
ax.plot([m["epoch"] for m in metrics], [m["loss"] for m in metrics], label="train")
ax.plot([m["epoch"] for m in metrics], [m["val_loss"] for m in metrics], label="validation")
ax.set_xlabel("epoch"); ax.set_ylabel("loss"); ax.legend(); fig.tight_layout()
fig.savefig(f"{out}/loss.png", dpi=120)

fig, ax = plt.subplots(figsize=(5, 5))
actual = [float(r["duration_s"]) for r in val_rows]
ax.scatter(actual, pred_d.tolist(), s=8, alpha=0.6)
top = max(actual + pred_d.tolist())
ax.plot([1, top], [1, top], color="gray", lw=1)
ax.set_xscale("log"); ax.set_yscale("log")
ax.set_xlabel("actual duration (s)"); ax.set_ylabel("predicted (s)"); fig.tight_layout()
fig.savefig(f"{out}/duration.png", dpi=120)
# The network: every unit, and the strongest connections of each layer.
cols = [in_names, h1_names, h2_names, ["duration", "failure"]]
pos = {}
for c, names in enumerate(cols):
    for k, name in enumerate(names):
        pos[name] = (c, 1 - (k + 0.5) / len(names))
fig, ax = plt.subplots(figsize=(12, 9))
for n, l in LAYERS.items():
    src_names, dst_names = ends[n]
    wts = l.weight.detach().abs()
    keep = wts.flatten().topk(min(150, wts.numel())).values[-1].item()
    for j, row in enumerate(l.weight.detach().tolist()):
        for i, v in enumerate(row):
            if abs(v) >= keep:
                (x0, y0), (x1, y1) = pos[src_names[i]], pos[dst_names[j]]
                ax.plot([x0, x1], [y0, y1], color="tab:blue" if v > 0 else "tab:red",
                        lw=0.3 + 2.5 * abs(v) / wts.max().item(), alpha=0.5)
for name, (x, y) in pos.items():
    ax.scatter([x], [y], s=12, color="black", zorder=3)
for name in in_names + ["duration", "failure"]:
    x, y = pos[name]
    ax.text(x - 0.03 if x == 0 else x + 0.03, y, name, fontsize=6, va="center",
            ha="right" if x == 0 else "left")
ax.set_xlim(-0.6, 3.4); ax.axis("off")
ax.set_title("strongest connections per layer (blue positive, red negative)")
fig.tight_layout()
fig.savefig(f"{out}/network.png", dpi=90)
print("wrote", sorted(os.listdir(out)))
