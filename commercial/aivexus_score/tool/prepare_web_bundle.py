#!/usr/bin/env python3
"""Prepare a standalone, self-hosted Flutter Web ZIP for nested-path hosting.

Fail closed if Flutter's generated layout changes. Nothing is deployed.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

LOCAL_RENDERER = '  config: { canvasKitBaseUrl: "canvaskit/" },\n'
LOADER_MARKER = "_flutter.loader.load({\n"


def prepare(root: Path) -> None:
    required = (
        "index.html", "manifest.json", "flutter_bootstrap.js",
        "canvaskit/canvaskit.js", "canvaskit/canvaskit.wasm",
    )
    missing = [path for path in required if not (root / path).is_file()]
    if missing:
        raise ValueError(f"Missing essential bundled Web assets: {missing}")

    index = root / "index.html"
    html = index.read_text(encoding="utf-8")
    if '<base href="/">' in html:
        html = html.replace('<base href="/">', '<base href="./">', 1)
    if '<base href="./">' not in html:
        raise ValueError("Unexpected Flutter base href: cannot ensure nested-path hosting")
    html = html.replace("<title>aivexus_score</title>", "<title>AIVEXUS Score</title>")
    html = html.replace(
        'content="A new Flutter project."',
        'content="Offline scoreboard for two players; no account or advertisements."',
    )
    html = html.replace(
        'content="aivexus_score"',
        'content="AIVEXUS Score"',
    )
    if "<title>AIVEXUS Score</title>" not in html:
        raise ValueError("Unexpected Flutter title: cannot verify branding")
    index.write_text(html, encoding="utf-8")

    loader = root / "flutter_bootstrap.js"
    js = loader.read_text(encoding="utf-8")
    if LOCAL_RENDERER not in js:
        if js.count(LOADER_MARKER) != 1:
            raise ValueError("Unknown Flutter loader layout; cannot force local CanvasKit")
        js = js.replace(LOADER_MARKER, LOADER_MARKER + LOCAL_RENDERER, 1)
    if js.count(LOCAL_RENDERER) != 1:
        raise ValueError("Local CanvasKit configuration is ambiguous")
    loader.write_text(js, encoding="utf-8")

    manifest = root / "manifest.json"
    data = json.loads(manifest.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("Unexpected Web manifest")
    data["name"] = "AIVEXUS Score"
    data["short_name"] = "AIVEXUS Score"
    data["description"] = "Private offline scoreboard for two players."
    data["start_url"] = "."
    manifest.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print("Web package prepared: relative paths, local CanvasKit, AIVEXUS Score metadata")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("web_root", type=Path)
    args = parser.parse_args()
    prepare(args.web_root)
