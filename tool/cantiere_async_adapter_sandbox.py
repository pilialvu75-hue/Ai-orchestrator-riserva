#!/usr/bin/env python3
"""Cantiere experimental integration probe of the real AIVEXUS Library async adapter.

Runs a standalone Dart consumer in an isolated temporary directory; it does NOT
install or stage the TESTED module into the production Flutter workspace.
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

LIBRARY = "https://github.com/pilialvu75-hue/AI-Orchestrator-Module-Library.git"
_SHA = re.compile(r"[0-9a-f]{40}\Z")

def execute(library_sha: str, upstream_sha: str) -> None:
    if not _SHA.fullmatch(library_sha) or not _SHA.fullmatch(upstream_sha):
        raise ValueError("full pinned 40-character Git SHAs required")
    with tempfile.TemporaryDirectory(prefix="cantiere-async-sandbox-") as tmp:
        root = Path(tmp)
        checkout = root / "library"
        subprocess.run(["git", "clone", "--quiet", LIBRARY, str(checkout)], check=True)
        subprocess.run(["git", "checkout", "--quiet", library_sha], cwd=checkout, check=True)
        actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
        if actual != library_sha:
            raise ValueError("Library source pin mismatch")
        subprocess.run([sys.executable, str(checkout / "tools/rebuild_async_adapter.py"),
                        "--source-commit", upstream_sha,
                        "--output", str(root / "rebuilt")], check=True)
        print("PASS: Cantiere sandbox executed real pinned Library async adapter")
        print("NOT CERTIFIED; NOT STAGED IN PRODUCTION; TEMPORARY FILES REMOVED")

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--library-sha", required=True)
    p.add_argument("--upstream-sha", required=True)
    args = p.parse_args()
    try:
        execute(args.library_sha, args.upstream_sha)
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
