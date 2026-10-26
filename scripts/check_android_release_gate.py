#!/usr/bin/env python3
"""Fail CI if an ordinary push or PR could publish an Android release.

Only an explicitly dispatched beta/nightly/dev workflow may create a GitHub
Release. This is an offline source check: no GitHub token or network required.
"""
from pathlib import Path
import re
import sys


def validate(source: str) -> list[str]:
    errors: list[str] = []

    release_pattern = re.compile(
        r"(?m)^\s*- name: Create GitHub Release\s*\n"
        r"\s*if: github\.event_name == 'workflow_dispatch'\s*$"
    )
    matches = release_pattern.findall(source)
    if len(matches) != 1:
        errors.append("GitHub Release must have an exact manual-dispatch gate")

    for event in ("push:", "pull_request:", "workflow_dispatch:"):
        if not re.search(r"(?m)^  " + re.escape(event) + r"\s*$", source):
            errors.append(f"Expected workflow trigger missing: {event}")

    if (
        "CHANNEL=\"\u0024{{ github.event_name == 'workflow_dispatch' "
        "&& inputs.release_channel || 'ci' }}\"" not in source
    ):
        errors.append("Non-manual workflow must use 'ci', not a release channel")

    if "group: android-release-\u0024{{ github.ref }}-\u0024{{ github.event_name }}" not in source:
        errors.append("Manual releases must not share the push CI concurrency group")

    block_match = re.search(
        r"(?ms)^      release_channel:\s*\n(.*?)(?=^#|^permissions:)",
        source,
    )
    if not block_match:
        errors.append("Explicit release_channel input is required")
    else:
        block = block_match.group(1)
        if not all(re.search(r"(?m)^\s*- " + item + r"\s*$", block)
                   for item in ("beta", "nightly", "dev")):
            errors.append("Manual channels must include beta/nightly/dev")
        if re.search(r"(?m)^\s*- stable\s*$", block):
            errors.append("Stable distribution must not be an implicit manual option")

    return errors


def validate_macos(source: str) -> list[str]:
    # A successful Android push CI can no longer be interpreted as a
    # publishable release. macOS may only attach to a manually dispatched
    # Android release that actually exists.
    required = "github.event.workflow_run.event == 'workflow_dispatch'"
    if required not in source or (
        "github.event.workflow_run.event == 'push'" in source
    ):
        return ["macOS publisher must require an explicit release dispatch"]
    return []


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".github/workflows/build.yml")
    problems = validate(path.read_text(encoding="utf-8"))
    if len(sys.argv) > 2:
        problems.extend(validate_macos(Path(sys.argv[2]).read_text(encoding="utf-8")))
    for problem in problems:
        print(f"::error::{problem}")
    if problems:
        return 1
    print("Release gate OK: pushes and PRs build artifacts; dispatch publishes explicit prereleases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
