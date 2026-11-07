"""Train a small network on CI runs: predict a run's duration and whether
it fails, from what is known when it starts.

Usage: train.py <runs.csv> <artifacts dir>

Writes, per the w8s-artifacts convention:
  metrics.csv      one row per epoch
  summary.json     final numbers, the network's and a baseline's
  predictions.csv  every validation run: actual and predicted
  loss.png, duration.png
  model/model.pt   the weights and the feature encoding
"""
import csv, json, math, os, sys, time

import numpy as np
import torch
from torch import nn

src, out = sys.argv[1], sys.argv[2]
epochs = int(os.environ.get("EPOCHS", 300))
hidden = int(os.environ.get("HIDDEN", 64))
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


net = Net(xt.shape[1], hidden)
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


metrics = []
t0 = time.time()
for epoch in range(1, epochs + 1):
    net.train()
    opt.zero_grad()
    pd, pf = net(xt)
    loss = mse(pd, dt) + bce(pf, ft)
    loss.backward()
    opt.step()
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
    "epochs": epochs, "hidden": hidden, "learning_rate": lr, "seed": seed,
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
            "hidden": hidden}, f"{out}/model/model.pt")

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
print("wrote", sorted(os.listdir(out)))
