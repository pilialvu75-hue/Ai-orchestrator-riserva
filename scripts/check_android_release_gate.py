#!/usr/bin/env python3
"""Fail CI if an ordinary push or PR could publish an Android release.

Only an explicitly dispatched stable/beta/nightly/dev workflow may create a
GitHub Release. This is an offline source check: no token or network required.
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

    if 'TAG="v${VERSION_NAME}-${CHANNEL}+${VERSION_CODE}"' not in source:
        errors.append(
            "Official prerelease tag must follow SemVer (vX.Y.Z-beta+build)"
        )

    block_match = re.search(
        r"(?ms)^      release_channel:\s*\n(.*?)(?=^#|^permissions:)",
        source,
    )
    if not block_match:
        errors.append("Explicit release_channel input is required")
    else:
        block = block_match.group(1)
        if not all(re.search(r"(?m)^\s*- " + item + r"\s*$", block)
                   for item in ("stable", "beta", "nightly", "dev")):
            errors.append("Manual channels must include stable/beta/nightly/dev")

    return errors


def validate_desktop_publisher(source: str, platform: str) -> list[str]:
    # All desktop assets attach to an existing, deliberately dispatched
    # Android prerelease. Merely finishing main push CI must not publish.
    problems: list[str] = []
    required = "github.event.workflow_run.event == 'workflow_dispatch'"
    if required not in source or (
        "github.event.workflow_run.event == 'push'" in source
    ):
        problems.append(f"{platform}: publisher must require manual release dispatch")
    if "id: publish_tag" not in source or "steps.publish_tag.outputs.tag" not in source:
        problems.append(f"{platform}: publisher must resolve the actual explicit release tag")
    if platform in ("linux", "macos") and 'candidate="${base}-${channel}+${build}"' not in source:
        problems.append(f"{platform}: must resolve SemVer prerelease tag")
    if platform == "windows" and '"$base-beta+$build"' not in source:
        problems.append("windows: must resolve SemVer prerelease tag")
    if platform in ("linux", "macos") and 'candidate="${base}+${build}"' not in source:
        problems.append(f"{platform}: must recognize manually published stable tag")
    if platform == "windows" and '"$base+$build"' not in source:
        problems.append("windows: must recognize manually published stable tag")
    if "steps.version.outputs.tag" in source:
        problems.append(f"{platform}: publisher may not upload to an unsuffixed tag")
    if platform == "macos" and 'version_code="$((100000 +' not in source:
        problems.append("macOS must use the same build-code namespace as Android")
    return problems


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".github/workflows/build.yml")
    problems = validate(path.read_text(encoding="utf-8"))
    for publisher_path in sys.argv[2:]:
        filename = Path(publisher_path).name
        platform = filename.split("-", 1)[0]
        problems.extend(
            validate_desktop_publisher(
                Path(publisher_path).read_text(encoding="utf-8"),
                platform,
            )
        )
    for problem in problems:
        print(f"::error::{problem}")
    if problems:
        return 1
    print("Release gate OK: pushes and PRs cannot publish; dispatch explicitly selects stable or prerelease")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
