#!/usr/bin/env python3
"""Explicit internal project staging; no production approval or execution."""
import argparse
import json
from pathlib import Path
import re
from cantiere_library_sandbox_preview import (
    _download_json, discover_development, verify_preview,
    INDEX_PATH, DEVELOPMENT_INDEX_PATH, _write_preview,
)

def stage(pin, project):
    project = project.resolve(strict=True)
    if not (project / "pubspec.yaml").is_file():
        raise ValueError("Expected an existing Dart or Flutter project")
    experimental = _download_json(INDEX_PATH)
    rows = discover_development(_download_json(DEVELOPMENT_INDEX_PATH), experimental)
    row = next((r for r in rows if r["pin"] == pin), None)
    if row is None:
        raise ValueError("Module not independently qualified")
    files = verify_preview(experimental, _download_json(row["path"]), pin, development=True)
    name = re.search(r"^name: ([a-z][a-z0-9_]*)$", files["pubspec.yaml"].decode(), re.M)
    if name is None:
        raise ValueError("Invalid Dart package name")
    parent = project / "aivexus_internal_modules"
    if parent.is_symlink():
        raise ValueError("Symlink destination refused")
    parent.mkdir(exist_ok=True)
    destination = parent / name[1]
    destination.mkdir(exist_ok=False)
    try:
        _write_preview(destination, files)
    except Exception:
        import shutil
        shutil.rmtree(destination)
        raise
    return {"pin": pin, "package_sha256": row["package_sha256"],
            "dependency": {name[1]: {"path": str(destination.relative_to(project))}},
            "production_approved": False, "android_validated": False}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pin", required=True)
    parser.add_argument("--project", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(stage(args.pin, args.project), indent=2))
