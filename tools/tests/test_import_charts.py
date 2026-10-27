"""Tests for import_charts.py: python3 -m unittest discover -s tools/tests

No network: every fetch goes to a fake. The Artifact Hub package below
has the shape its API documents (GET /api/v1/packages/helm/{repo}/{name}).
"""

import io
import json
import os
import sys
import tarfile
import tempfile
import unittest

import yaml

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import import_charts as ic  # noqa: E402

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
SVG = b'<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg"></svg>'

AH_PACKAGE = {
    "name": "valkey",
    "display_name": "Valkey",
    "description": "Valkey is a high-performance key/value datastore. It speaks the Redis protocol.",
    "keywords": ["valkey", "redis", "cache", "a-keyword-that-is-far-too-long-to-keep"],
    "category": 2,
    "home_url": "https://valkey.io",
    "version": "0.12.0",
    "logo_image_id": "0f1e2d3c",
    "content_url": "https://example.com/valkey-0.12.0.tgz",
    "repository": {"name": "valkey", "url": "https://valkey.io/valkey-helm/"},
}

CHART_YAML = """
apiVersion: v2
name: gatus
version: 1.5.0
description: Automated service health dashboard
keywords: [monitoring, status]
home: https://gatus.io
icon: https://example.com/gatus.png
annotations:
  artifacthub.io/category: monitoring-logging
"""


def fake_get(routes):
    def get(url, limit=0):
        if url not in routes:
            raise ic.ImportError_(f"{url}: HTTP 404")
        body, ctype = routes[url]
        return body, ctype
    return get


def chart_tgz(files, chart="valkey"):
    """A chart archive holding `files`, plus a subchart that must be ignored."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        def add(name, body):
            info = tarfile.TarInfo(name)
            info.size = len(body)
            tar.addfile(info, io.BytesIO(body))
        for name, body in files.items():
            add(f"{chart}/{name}", body)
        add(f"{chart}/Chart.yaml", b"name: x\nversion: 1\n")
        add(f"{chart}/charts/dep/values.yaml", b"dep: not the chart's own\n")
    return buf.getvalue()


class Sources(unittest.TestCase):
    def test_artifacthub_fields_and_category(self):
        n = ic.normalize_artifacthub(AH_PACKAGE)
        self.assertEqual(n["name"], "Valkey")
        self.assertEqual(n["category"], "db")
        self.assertEqual(n["chart_url"], "https://example.com/valkey-0.12.0.tgz")
        self.assertEqual(n["logo_url"], "https://artifacthub.io/image/0f1e2d3c@2x")

    def test_an_oci_repository_names_the_chart_under_it(self):
        p = dict(AH_PACKAGE, content_url=None, repository={"url": "oci://ghcr.io/org/charts"})
        self.assertEqual(ic.normalize_artifacthub(p)["chart_url"], "oci://ghcr.io/org/charts/valkey")
        p["repository"] = {"url": "oci://ghcr.io/org/charts/valkey"}
        self.assertEqual(ic.normalize_artifacthub(p)["chart_url"], "oci://ghcr.io/org/charts/valkey")

    def test_chart_yaml_fields(self):
        n = ic.normalize_chart_yaml(yaml.safe_load(CHART_YAML), "TwiN/helm-charts")
        self.assertEqual((n["name"], n["category"], n["version"]), ("gatus", "observability", "1.5.0"))
        self.assertEqual(n["logo_url"], "https://example.com/gatus.png")


class Building(unittest.TestCase):
    def test_the_entry_wins_and_long_keywords_are_dropped(self):
        m, logo = ic.build({"id": "valkey", "tagline": "Mine."}, ic.normalize_artifacthub(AH_PACKAGE))
        self.assertEqual(m["tagline"], "Mine.")
        self.assertEqual(m["tags"], ["valkey", "redis", "cache"])
        self.assertEqual(m["namespace"], "valkey")
        self.assertEqual(ic.check(m), [])

    def test_the_tagline_defaults_to_the_first_sentence(self):
        m, _ = ic.build({"id": "valkey"}, ic.normalize_artifacthub(AH_PACKAGE))
        self.assertEqual(m["tagline"], "Valkey is a high-performance key/value datastore.")

    def test_a_chart_yaml_source_needs_a_chart_url(self):
        with self.assertRaises(ic.ImportError_):
            ic.build({"id": "gatus"}, ic.normalize_chart_yaml(yaml.safe_load(CHART_YAML)))

    def test_description_lines_become_paragraphs(self):
        self.assertEqual(ic.paragraphs("One\ntwo.\n\n  Three\n four. \n"), "One two.\n\nThree four.")

    def test_the_hubs_limits(self):
        m, _ = ic.build({"id": "x", "chart": {"url": "http://plain/x.tgz"}, "category": "dbs",
                         "values": ["not", "a", "map"]}, {"name": "x"})
        problems = " ".join(ic.check(m))
        for expected in ("chart.url", "category", "values must be a mapping"):
            self.assertIn(expected, problems)

    def test_a_one_colour_logo_goes_on_a_tile(self):
        tiled = ic.on_tile(SVG, "svg", "#ffffff").decode()
        self.assertTrue(tiled.startswith("<svg"))
        self.assertIn('fill="#ffffff"', tiled)
        self.assertIn("data:image/svg+xml;base64,", tiled)
        self.assertEqual(ic.logo_kind(tiled.encode(), ""), "svg")
        self.assertIn("data:image/png;base64,", ic.on_tile(PNG, "png", "#fff").decode())
        with self.assertRaises(ic.ImportError_):
            ic.on_tile(SVG, "svg", "white; x")

    def test_logos_are_recognised_by_their_bytes(self):
        self.assertEqual(ic.logo_kind(PNG, "application/octet-stream"), "png")
        self.assertEqual(ic.logo_kind(SVG, "text/plain"), "svg")
        self.assertIsNone(ic.logo_kind(b"\xff\xd8\xff\xe0JFIF", "image/jpeg"))


class ChartFiles(unittest.TestCase):
    """The chart's own values.yaml and values.schema.json, for the deploy
    page to show what a chart takes. Reading a subchart's values as the
    chart's own would describe a dependency nobody is deploying."""

    def test_takes_the_charts_own_files_and_not_a_subcharts(self):
        archive = chart_tgz({"values.yaml": b"replicas: 1\n", "values.schema.json": b"{}"})
        get = fake_get({"https://example.com/c.tgz": (archive, "application/gzip")})
        files = ic.chart_files("https://example.com/c.tgz", "1.0.0", get)
        self.assertEqual(sorted(files), ["values.schema.json", "values.yaml"])
        self.assertEqual(files["values.yaml"], b"replicas: 1\n")

    def test_a_schema_is_optional(self):
        archive = chart_tgz({"values.yaml": b"replicas: 1\n"})
        get = fake_get({"https://example.com/c.tgz": (archive, "application/gzip")})
        self.assertEqual(list(ic.chart_files("https://example.com/c.tgz", "1.0.0", get)), ["values.yaml"])

    def test_an_oversized_file_is_left_out(self):
        archive = chart_tgz({"values.yaml": b"x" * (ic.MAX_CHART_FILE_BYTES + 1)})
        get = fake_get({"https://example.com/c.tgz": (archive, "application/gzip")})
        self.assertEqual(ic.chart_files("https://example.com/c.tgz", "1.0.0", get), {})

    def test_something_that_is_not_an_archive(self):
        get = fake_get({"https://example.com/c.tgz": (b"not a tarball", "text/plain")})
        with self.assertRaises(ic.ImportError_):
            ic.chart_files("https://example.com/c.tgz", "1.0.0", get)

    def test_an_unreadable_archive_still_leaves_an_entry(self):
        """The files are a nicety; a chart that will not give them up still
        gets a card, and the previous run's copies are not left behind."""
        out = tempfile.mkdtemp()
        os.makedirs(os.path.join(out, "gatus"))
        stale = os.path.join(out, "gatus", "values.yaml")
        with open(stale, "w") as f:
            f.write("from an older run\n")
        get = fake_get({
            "https://raw.githubusercontent.com/TwiN/helm-charts/abc/charts/gatus/Chart.yaml": (CHART_YAML.encode(), "text/plain"),
            "https://example.com/gatus.svg": (SVG, "image/svg+xml"),
        })
        entry = {"id": "gatus", "logo": "https://example.com/gatus.svg",
                 "git": {"repo": "TwiN/helm-charts", "path": "charts/gatus", "ref": "abc"},
                 "chart": {"url": "https://example.com/gatus-1.5.0.tgz", "version": "1.5.0"}}
        ic.import_one(entry, out, "auto", False, get)
        self.assertTrue(os.path.exists(os.path.join(out, "gatus", "architecture.yaml")))
        self.assertFalse(os.path.exists(stale))

    def test_they_are_written_beside_the_entry(self):
        out = tempfile.mkdtemp()
        archive = chart_tgz({"values.yaml": b"replicas: 1\n", "values.schema.json": b"{}"}, chart="gatus")
        get = fake_get({
            "https://raw.githubusercontent.com/TwiN/helm-charts/abc/charts/gatus/Chart.yaml": (CHART_YAML.encode(), "text/plain"),
            "https://example.com/gatus.svg": (SVG, "image/svg+xml"),
            "https://example.com/gatus-1.5.0.tgz": (archive, "application/gzip"),
        })
        entry = {"id": "gatus", "logo": "https://example.com/gatus.svg",
                 "git": {"repo": "TwiN/helm-charts", "path": "charts/gatus", "ref": "abc"},
                 "chart": {"url": "https://example.com/gatus-1.5.0.tgz", "version": "1.5.0"}}
        ic.import_one(entry, out, "auto", False, get)
        with open(os.path.join(out, "gatus", "values.yaml")) as f:
            self.assertEqual(f.read(), "replicas: 1\n")
        self.assertTrue(os.path.exists(os.path.join(out, "gatus", "values.schema.json")))


class Importing(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp()

    def read(self, entry_id):
        with open(os.path.join(self.out, entry_id, "architecture.yaml")) as f:
            return yaml.safe_load(f)

    def test_artifacthub_when_git_does_not_answer_then_the_files_the_hub_reads(self):
        get = fake_get({
            "https://artifacthub.io/api/v1/packages/helm/valkey/valkey": (json.dumps(AH_PACKAGE).encode(), "application/json"),
            "https://artifacthub.io/image/0f1e2d3c@2x": (PNG, "image/png"),
        })
        entry = {"id": "valkey", "artifacthub": "valkey/valkey", "values": {"dataStorage": {"enabled": True}},
                 "git": {"repo": "valkey-io/valkey-helm", "path": "valkey"}}
        origin = ic.import_one(entry, self.out, "auto", False, get, want_chart_files=False)
        self.assertIn("Artifact Hub", origin)
        doc = self.read("valkey")
        self.assertEqual(doc["artifacthub"], "valkey/valkey")
        self.assertEqual(doc["logo"], "logo.png")
        self.assertEqual(doc["values"], {"dataStorage": {"enabled": True}})
        self.assertEqual(doc["chart"], {"url": "https://example.com/valkey-0.12.0.tgz", "version": "0.12.0"})
        self.assertTrue(os.path.exists(os.path.join(self.out, "valkey", "logo.png")))

    def test_git_when_artifacthub_does_not_answer(self):
        get = fake_get({
            "https://raw.githubusercontent.com/TwiN/helm-charts/abc/charts/gatus/Chart.yaml": (CHART_YAML.encode(), "text/plain"),
            "https://example.com/gatus.svg": (SVG, "image/svg+xml"),
        })
        entry = {"id": "gatus", "artifacthub": "gatus/gatus", "logo": "https://example.com/gatus.svg",
                 "git": {"repo": "TwiN/helm-charts", "path": "charts/gatus", "ref": "abc"},
                 "chart": {"url": "https://example.com/gatus-1.5.0.tgz"}}
        origin = ic.import_one(entry, self.out, "auto", False, get, want_chart_files=False)
        self.assertIn("github.com/TwiN/helm-charts", origin)
        doc = self.read("gatus")
        self.assertEqual((doc["logo"], doc["chart"]["version"], doc["category"]), ("logo.svg", "1.5.0", "observability"))
        self.assertEqual(doc["artifacthub"], "gatus/gatus")

    def test_git_first_when_both_answer(self):
        """The pinned ref is what was vetted; Artifact Hub describes the
        package's latest version, so it is only the fallback."""
        get = fake_get({
            "https://raw.githubusercontent.com/TwiN/helm-charts/abc/charts/gatus/Chart.yaml": (CHART_YAML.encode(), "text/plain"),
            "https://artifacthub.io/api/v1/packages/helm/valkey/valkey": (json.dumps(AH_PACKAGE).encode(), "application/json"),
            "https://example.com/gatus.svg": (SVG, "image/svg+xml"),
        })
        entry = {"id": "gatus", "artifacthub": "valkey/valkey", "logo": "https://example.com/gatus.svg",
                 "git": {"repo": "TwiN/helm-charts", "path": "charts/gatus", "ref": "abc"},
                 "chart": {"url": "https://example.com/gatus-1.5.0.tgz"}}
        origin = ic.import_one(entry, self.out, "auto", False, get, want_chart_files=False)
        self.assertIn("github.com/TwiN/helm-charts", origin)
        self.assertEqual(self.read("gatus")["chart"]["version"], "1.5.0")

    def test_an_artifacthub_reference_is_two_names(self):
        m, _ = ic.build({"id": "x", "artifacthub": "only-one",
                         "chart": {"url": "https://example.com/x.tgz", "version": "1"}}, {"name": "X"})
        self.assertIn("artifacthub must be <repository>/<package>", ic.check(m))
        m["artifacthub"] = "repo/package"
        self.assertEqual(ic.check(m), [])

    def test_a_logo_the_hub_cannot_serve_stops_the_entry(self):
        get = fake_get({
            "https://artifacthub.io/api/v1/packages/helm/valkey/valkey": (json.dumps(AH_PACKAGE).encode(), "application/json"),
            "https://artifacthub.io/image/0f1e2d3c@2x": (b"\xff\xd8\xff\xe0JFIF", "image/jpeg"),
        })
        with self.assertRaises(ic.ImportError_) as e:
            ic.import_one({"id": "valkey", "artifacthub": "valkey/valkey"}, self.out, "auto", False, get)
        self.assertIn("not an SVG or PNG", str(e.exception))
        self.assertFalse(os.path.exists(os.path.join(self.out, "valkey")))

    def test_a_too_large_logo_stops_the_entry(self):
        get = fake_get({
            "https://artifacthub.io/api/v1/packages/helm/valkey/valkey": (json.dumps(AH_PACKAGE).encode(), "application/json"),
            "https://artifacthub.io/image/0f1e2d3c@2x": (PNG + b"\x00" * ic.MAX_LOGO_BYTES, "image/png"),
        })
        with self.assertRaises(ic.ImportError_):
            ic.import_one({"id": "valkey", "artifacthub": "valkey/valkey"}, self.out, "auto", False, get)

    def test_an_entry_is_named_by_its_file(self):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "valkey.yaml"), "w") as f:
            f.write("name: Valkey\n")
        with open(os.path.join(d, "README.md"), "w") as f:
            f.write("not an entry\n")
        self.assertEqual(ic.read_catalog(d), [{"id": "valkey", "name": "Valkey"}])
        with open(os.path.join(d, "other.yaml"), "w") as f:
            f.write("id: valkey\n")
        with self.assertRaises(SystemExit):
            ic.read_catalog(d)

    def test_the_catalog_in_the_repository_is_valid(self):
        entries = ic.read_catalog(os.path.join(ic.HERE, "..", "catalog"))
        self.assertGreater(len(entries), 0)
        ids = [e["id"] for e in entries]
        self.assertEqual(len(ids), len(set(ids)))
        for e in entries:
            self.assertTrue(ic.SLUG.match(e["id"]), e["id"])
            self.assertIn("git", e, e["id"])
            self.assertIn("chart", e, e["id"])
            m, _ = ic.build(e, {"name": e["id"]})
            m["logo"] = "logo.svg"
            self.assertEqual(ic.check(m), [], e["id"])


if __name__ == "__main__":
    unittest.main()
