#!/usr/bin/env python3
"""Turns a list of upstream Helm charts into Apps catalog entries.

Reads catalog/<id>.yaml, one file per chart, and writes, per entry,
<out>/<id>/architecture.yaml and <out>/<id>/logo.{svg,png}: the same two
files a hand-written reference architecture has, so the w8s hub renders
every entry the same way (check() below mirrors the hub's limits).

Where an entry's metadata comes from, in order of preference:

  git: {repo, path, ref}          The chart's own Chart.yaml on GitHub, at
                                  the pinned ref: what was vetted. A
                                  Chart.yaml has no download URL, so
                                  `chart:` is then required in the entry.
  artifacthub: <repo>/<package>   Artifact Hub's package API: name,
                                  description, keywords, category, logo and
                                  the chart's download URL, in one shape
                                  for every chart repository. It describes
                                  the package's latest version, not the
                                  pinned one, so it is the fallback.

`artifacthub:` is also the package's page, written into the entry for
the card's Artifact Hub link whichever source answered.

Anything set in the entry itself (name, tagline, description, tags,
category, namespace, logo, chart, source) wins over what the source says.
`logo_background: "#ffffff"` puts a one-colour logo on a tile of that
colour, so a black (or white) mark reads on both the app's themes.
`values` is the entry's own: the Helm values the deploy page starts from,
for what a chart's defaults get wrong (most often: no persistent volume).

  python3 tools/import_charts.py --out vetted
  python3 tools/import_charts.py --out vetted --only valkey,qdrant
  python3 tools/import_charts.py --out vetted --check-kinds  # needs helm

`vetted/` is where these belong: upstream charts w8s vetted and left
alone, committed here and shipped in the w8s hub image at a pinned
commit of this repository, a section of their own in the app. The other
half is w8s-cloud/reference-architectures: the architectures somebody
wrote for w8s. Nothing writes an imported entry there.

--check-kinds renders each chart with the entry's values and fails on any
object the agent will not install for an app (APP_KINDS below, from the
agent chart's `w8s-agent.appRules`): an operator, a CRD, a Job, a
PodDisruptionBudget. Such a chart is listed but its install fails.

Needs PyYAML (pip install pyyaml). Nothing else outside the standard
library.
"""

import argparse
import base64
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ARTIFACTHUB = "https://artifacthub.io"

# The hub's own limits (reference_architectures.rs).
CATEGORIES = [
    "db", "ai", "messaging", "observability", "storage", "web", "security",
    "business", "project", "productivity", "knowledge", "data", "devtools", "other",
]
MAX_LOGO_BYTES = 256 * 1024
MAX_VALUES_BYTES = 8 * 1024
# The chart's own values.yaml and values.schema.json, written beside the
# entry so the deploy page can show what a chart takes without fetching it
# at deploy time. A values.yaml runs from 4 KiB to 90 KiB across the
# charts here; the cap is what keeps one pathological chart from bloating
# the catalog and the hub's reads of it.
MAX_CHART_FILE_BYTES = 128 * 1024
CHART_FILES = ("values.yaml", "values.schema.json")

# What an app's Helm release may create (k8s/charts/w8s-agent/templates/
# _helpers.tpl, w8s-agent.appRules). Keep in step with that list.
APP_KINDS = {
    "Service", "ConfigMap", "Secret", "PersistentVolumeClaim", "ServiceAccount",
    "Deployment", "StatefulSet", "ServiceExport", "NetworkPolicy", "HTTPRoute",
}

# Artifact Hub's package categories, by number (the API) and by the name a
# chart's `artifacthub.io/category` annotation uses.
AH_CATEGORY = {
    1: "ai", 2: "db", 3: "other", 4: "observability", 5: "web",
    6: "security", 7: "storage", 8: "messaging",
    "ai-machine-learning": "ai", "database": "db", "integration-delivery": "other",
    "monitoring-logging": "observability", "networking": "web", "security": "security",
    "storage": "storage", "streaming-messaging": "messaging",
}

SLUG = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
# The hub's artifacthub_url: two names of letters, digits, '-', '_', '.'.
ARTIFACTHUB_REF = re.compile(r"^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$")


class ImportError_(Exception):
    pass


def fetch(url, limit=4 * 1024 * 1024):
    req = urllib.request.Request(url, headers={"User-Agent": "w8s-catalog-import"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read(limit + 1)
            if len(body) > limit:
                raise ImportError_(f"{url}: larger than {limit} bytes")
            return body, r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        raise ImportError_(f"{url}: HTTP {e.code}") from None
    except urllib.error.URLError as e:
        raise ImportError_(f"{url}: {e.reason}") from None


# ---- Sources ---------------------------------------------------------------

def from_artifacthub(ref, get=fetch):
    """What Artifact Hub knows about <repo>/<package>, in our field names."""
    body, _ = get(f"{ARTIFACTHUB}/api/v1/packages/helm/{ref}")
    return normalize_artifacthub(json.loads(body))


def normalize_artifacthub(p):
    repo = p.get("repository") or {}
    out = {
        "name": p.get("display_name") or p.get("name") or "",
        "description": p.get("description") or "",
        "tags": p.get("keywords") or [],
        "category": AH_CATEGORY.get(p.get("category"), ""),
        "source": p.get("home_url") or "",
        "version": p.get("version") or "",
    }
    if p.get("logo_image_id"):
        out["logo_url"] = f"{ARTIFACTHUB}/image/{p['logo_image_id']}@2x"
    repo_url = (repo.get("url") or "").rstrip("/")
    name = p.get("name") or ""
    if repo_url.startswith("oci://"):
        # An OCI repository is the registry path the chart sits under.
        out["chart_url"] = repo_url if repo_url.endswith("/" + name) else f"{repo_url}/{name}"
    elif p.get("content_url"):
        out["chart_url"] = p["content_url"]
    return out


def from_git(g, get=fetch):
    """What a chart's own Chart.yaml says, read from GitHub."""
    ref = g.get("ref") or "HEAD"
    path = g.get("path", ".").strip("/")
    path = "" if path == "." else path + "/"
    body, _ = get(f"https://raw.githubusercontent.com/{g['repo']}/{ref}/{path}Chart.yaml")
    return normalize_chart_yaml(yaml.safe_load(body), g["repo"])


def normalize_chart_yaml(c, repo=""):
    ann = c.get("annotations") or {}
    out = {
        "name": c.get("name") or "",
        "description": c.get("description") or "",
        "tags": c.get("keywords") or [],
        "category": AH_CATEGORY.get(str(ann.get("artifacthub.io/category", "")).strip('"'), ""),
        "source": c.get("home") or (f"https://github.com/{repo}" if repo else ""),
        "version": str(c.get("version") or ""),
    }
    if c.get("icon"):
        out["logo_url"] = c["icon"]
    return out


# ---- Building an entry -----------------------------------------------------

def build(entry, source):
    """architecture.yaml's fields, entry overrides first; and the logo URL."""
    chart = entry.get("chart") or {}
    chart_url = chart.get("url") or source.get("chart_url")
    version = str(chart.get("version") or source.get("version") or "")
    if not chart_url:
        raise ImportError_("no chart URL: set chart.url in the entry")
    tags = entry.get("tags") or [t for t in source.get("tags", []) if 0 < len(str(t)) <= 30][:8]
    m = {
        "name": entry.get("name") or source.get("name") or entry["id"],
        "tagline": entry.get("tagline") or first_sentence(source.get("description", "")),
        "description": paragraphs(entry.get("description") or source.get("description") or ""),
        "tags": [str(t) for t in tags],
        "category": entry.get("category") or source.get("category") or "other",
        "namespace": entry.get("namespace") or entry["id"],
        "logo": "",
        "source": entry.get("source") or source.get("source") or "",
        "chart": {"url": chart_url, "version": version or "latest"},
    }
    if entry.get("artifacthub"):
        m["artifacthub"] = entry["artifacthub"]
    if entry.get("values") is not None:
        m["values"] = entry["values"]
    if m["source"] and not m["source"].startswith("https://"):
        m["source"] = ""
    return m, entry.get("logo") or source.get("logo_url")


def paragraphs(text):
    """Lines joined into flowing paragraphs: the Apps page keeps line
    breaks as written, so a wrapped YAML block would wrap mid-sentence."""
    paras = re.split(r"\n\s*\n", text.strip())
    return "\n\n".join(" ".join(p.split()) for p in paras if p.strip())


def first_sentence(text):
    text = " ".join(text.split())
    m = re.match(r"(.+?[.!?])(\s|$)", text)
    s = m.group(1) if m else text
    return s[:200]


def check(m):
    """The hub's check_manifest, so a bad entry fails here and not there."""
    errors = []
    if not m["name"].strip() or len(m["name"]) > 80:
        errors.append("name must be 1-80 characters")
    if len(m["tagline"]) > 200:
        errors.append("tagline must be at most 200 characters")
    if len(m["description"]) > 4000:
        errors.append("description must be at most 4000 characters")
    if len(m["tags"]) > 8 or any(not t.strip() or len(t) > 30 for t in m["tags"]):
        errors.append("at most 8 tags, each 1-30 characters")
    if m["category"] not in CATEGORIES:
        errors.append(f"category must be one of {', '.join(CATEGORIES)}")
    if not (SLUG.match(m["namespace"]) and len(m["namespace"]) <= 63):
        errors.append("namespace must be a DNS label")
    url = m["chart"]["url"]
    if not (url.startswith("https://") or url.startswith("oci://")):
        errors.append("chart.url must be an https:// chart archive or an oci:// reference")
    if not 0 < len(m["chart"]["version"]) <= 64:
        errors.append("chart.version must be 1-64 characters")
    if "artifacthub" in m and not ARTIFACTHUB_REF.match(m["artifacthub"]):
        errors.append("artifacthub must be <repository>/<package>")
    if m["logo"] and not m["logo"].endswith((".svg", ".png")):
        errors.append("logo must be an .svg or .png file")
    if "values" in m:
        if not isinstance(m["values"], dict):
            errors.append("values must be a mapping of Helm values")
        elif len(json.dumps(m["values"], separators=(",", ":"))) > MAX_VALUES_BYTES:
            errors.append(f"values must be at most {MAX_VALUES_BYTES} bytes")
    return errors


def logo_kind(body, content_type):
    """'svg' or 'png' from the bytes (servers mislabel), else None."""
    head = body[:512].lstrip()
    if body.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if b"<svg" in body[:4096] or head.startswith(b"<?xml") and b"<svg" in body[:16384]:
        return "svg"
    if "svg" in content_type:
        return "svg"
    return None


def on_tile(body, kind, background):
    """The logo on a rounded tile of `background`, as an SVG.

    For a one-colour mark (black or white) that disappears on one of the
    app's two themes: on its own tile it reads on both. The original is
    embedded unchanged, as a data URI."""
    if not re.fullmatch(r"#[0-9a-fA-F]{3}([0-9a-fA-F]{3})?", background):
        raise ImportError_(f"logo_background {background!r} must be a #rgb or #rrggbb colour")
    mime = "image/svg+xml" if kind == "svg" else "image/png"
    data = base64.b64encode(body).decode()
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
        f'<rect width="100" height="100" rx="22" fill="{background}"/>'
        f'<image x="16" y="16" width="68" height="68" href="data:{mime};base64,{data}"/>'
        "</svg>"
    ).encode()


def render_yaml(m, origin, entry_id):
    doc = {k: v for k, v in m.items() if v not in ("", [], None)}
    header = (
        f"# Generated by tools/import_charts.py from {origin}.\n"
        f"# Change catalog/{entry_id}.yaml and re-run it rather than editing here.\n"
    )
    return header + yaml.dump(doc, Dumper=_Dumper, sort_keys=False, allow_unicode=True, width=76)


class _Dumper(yaml.SafeDumper):
    pass


def _str(dumper, value):
    # Prose as a block, the way a person writes it: folded (read back as
    # one line) for a long paragraph, literal to keep paragraph breaks.
    style = "|" if "\n" in value else ">" if len(value) > 70 and " " in value else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


_Dumper.add_representer(str, _str)


def disallowed_kinds(chart_url, version, values=None, helm="helm"):
    """Kinds the chart renders, with the entry's values, that apps may not create."""
    args = [helm, "template", "x", chart_url, "--skip-tests", "--kube-version", "1.31.0", "-n", "demo", "-f", "-"]
    if not chart_url.endswith(".tgz") and version and version != "latest":
        args += ["--version", version]
    r = subprocess.run(args, input=json.dumps(values or {}), capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise ImportError_(f"helm template failed: {r.stderr.strip()[:300]}")
    kinds = set(re.findall(r"^kind:\s*(\S+)", r.stdout, re.M))
    return sorted(kinds - APP_KINDS)


# ---- Main ------------------------------------------------------------------

def chart_files(chart_url, version, get=fetch, helm="helm", tmp=None):
    """The chart's own values.yaml and values.schema.json, as bytes.

    A chart's values.yaml is what the deploy page needs to show somebody
    what they can set; nearly every chart has one. A values.schema.json is
    rarer - one of the fifteen charts here ships one - so it is taken when
    it is there and never required.

    Only the chart's own files: a subchart's `charts/<name>/values.yaml`
    describes a dependency, not this chart, and would be read as the
    chart's own. An `https://` archive is read directly; an `oci://`
    reference needs helm to pull it.
    """
    out = {}
    if chart_url.startswith("oci://"):
        if shutil.which(helm) is None:
            raise ImportError_(f"{chart_url}: an oci:// chart needs helm on PATH to read its values")
        with tempfile.TemporaryDirectory(dir=tmp) as d:
            r = subprocess.run(
                [helm, "pull", chart_url, "--version", version, "--destination", d],
                capture_output=True, text=True, timeout=300,
            )
            if r.returncode != 0:
                raise ImportError_(f"{chart_url}: helm pull failed: {r.stderr.strip() or r.stdout.strip()}")
            tgz = [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".tgz")]
            if not tgz:
                raise ImportError_(f"{chart_url}: helm pull wrote no archive")
            with open(tgz[0], "rb") as f:
                body = f.read()
    else:
        body, _ = get(chart_url, limit=16 * 1024 * 1024)

    try:
        with tarfile.open(fileobj=io.BytesIO(body), mode="r:gz") as tar:
            for member in tar.getmembers():
                parts = member.name.split("/")
                # <chart>/<file>, and nothing deeper: a subchart's values
                # are four components in.
                if len(parts) != 2 or parts[1] not in CHART_FILES or not member.isfile():
                    continue
                if member.size > MAX_CHART_FILE_BYTES:
                    continue
                f = tar.extractfile(member)
                if f is not None:
                    out[parts[1]] = f.read()
    except tarfile.TarError as e:
        raise ImportError_(f"{chart_url}: not a readable chart archive ({e})")
    return out


def import_one(entry, out_dir, prefer, check_kinds, get=fetch, want_chart_files=True):
    if not SLUG.match(entry.get("id", "")):
        raise ImportError_(f"id {entry.get('id')!r} must be lowercase letters, digits and '-'")
    source, origin = None, None
    errors = []
    order = ["git", "artifacthub"] if prefer == "auto" else [prefer]
    for kind in order:
        if kind not in entry:
            continue
        try:
            if kind == "artifacthub":
                source, origin = from_artifacthub(entry["artifacthub"], get), f"Artifact Hub ({entry['artifacthub']})"
            else:
                g = entry["git"]
                source, origin = from_git(g, get), f"github.com/{g['repo']}/{g.get('path', '.')} @ {g.get('ref', 'HEAD')}"
            break
        except ImportError_ as e:
            errors.append(f"{kind}: {e}")
    if source is None:
        raise ImportError_("no source answered: " + "; ".join(errors) if errors else "no source (artifacthub or git) in the entry")

    m, logo_url = build(entry, source)
    target = os.path.join(out_dir, entry["id"])
    logo_file = None
    if logo_url:
        body, ctype = get(logo_url, limit=8 * 1024 * 1024)
        kind = logo_kind(body, ctype)
        if kind is None:
            raise ImportError_(f"logo {logo_url} is not an SVG or PNG; set `logo:` to one")
        if entry.get("logo_background"):
            body, kind = on_tile(body, kind, entry["logo_background"]), "svg"
        if len(body) > MAX_LOGO_BYTES:
            raise ImportError_(f"logo {logo_url} is {len(body)} bytes, over {MAX_LOGO_BYTES}; set `logo:` to a smaller one")
        logo_file = (f"logo.{kind}", body)
        m["logo"] = logo_file[0]
    problems = check(m)
    if problems:
        raise ImportError_("; ".join(problems))
    if check_kinds:
        bad = disallowed_kinds(m["chart"]["url"], m["chart"]["version"], m.get("values"))
        if bad:
            raise ImportError_(f"the chart creates objects apps may not: {', '.join(bad)}")

    # The chart's own files are a nicety, not the entry: a chart whose
    # archive cannot be read still gets a card, with a note on stderr.
    files = {}
    if want_chart_files:
        try:
            files = chart_files(m["chart"]["url"], m["chart"]["version"], get)
        except (ImportError_, OSError) as e:
            print(f"  (no chart values: {e})", file=sys.stderr)

    os.makedirs(target, exist_ok=True)
    for name in CHART_FILES:
        p = os.path.join(target, name)
        if os.path.exists(p) and name not in files:
            os.remove(p)
    for name, body in files.items():
        with open(os.path.join(target, name), "wb") as f:
            f.write(body)
    for old in ("logo.svg", "logo.png"):
        p = os.path.join(target, old)
        if os.path.exists(p) and (not logo_file or logo_file[0] != old):
            os.remove(p)
    if logo_file:
        with open(os.path.join(target, logo_file[0]), "wb") as f:
            f.write(logo_file[1])
    with open(os.path.join(target, "architecture.yaml"), "w") as f:
        f.write(render_yaml(m, origin, entry["id"]))
    return origin


def read_catalog(directory):
    """Every catalog/<id>.yaml, in name order; the file name is the id."""
    entries = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".yaml"):
            continue
        with open(os.path.join(directory, name)) as f:
            entry = yaml.safe_load(f) or {}
        if not isinstance(entry, dict):
            raise SystemExit(f"{name}: an entry is a mapping")
        entry_id = name[: -len(".yaml")]
        if entry.setdefault("id", entry_id) != entry_id:
            raise SystemExit(f"{name}: id {entry['id']!r} is not the file's name")
        entries.append(entry)
    return entries


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--catalog", default=os.path.join(HERE, "..", "catalog"),
                    help="the directory of <id>.yaml entries")
    ap.add_argument("--out", required=True, help="the catalog's architectures/ directory")
    ap.add_argument("--only", help="comma-separated ids")
    ap.add_argument("--source", choices=["auto", "artifacthub", "git"], default="auto")
    ap.add_argument("--check-kinds", action="store_true", help="render each chart with helm and refuse ones apps cannot install")
    ap.add_argument("--no-chart-files", action="store_true",
                    help="skip each chart's values.yaml and values.schema.json (one download per chart)")
    a = ap.parse_args(argv)
    entries = read_catalog(a.catalog)
    only = set(a.only.split(",")) if a.only else None
    failed = 0
    for e in entries:
        if only and e.get("id") not in only:
            continue
        try:
            origin = import_one(e, a.out, a.source, a.check_kinds, want_chart_files=not a.no_chart_files)
            print(f"ok    {e['id']:<24} {origin}")
        except ImportError_ as err:
            failed += 1
            print(f"FAIL  {e.get('id', '?'):<24} {err}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
