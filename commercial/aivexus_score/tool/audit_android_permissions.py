#!/usr/bin/env python3
"""Fail-closed audit for permissions requested by the standalone scorekeeper.

aapt dump permissions prints declarations ('permission:') separately from
requests ('uses-permission:'). An AndroidX internal unexported receiver
permission is expected from the Flutter scaffold and does not grant access
to sensitive device APIs. Every other requested permission is forbidden.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

EXPECTED_PACKAGE = "dev.aivexus.aivexus_score"
RECEIVER_PERMISSION = EXPECTED_PACKAGE + ".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
REQUEST = re.compile(r"^uses-(?:implied-)?permission(?:-sdk-\d+)?:\s*name='([^']+)'(?:\s.*)?$")


def audit_permissions(report: str, package: str = EXPECTED_PACKAGE) -> list[str]:
    if package != EXPECTED_PACKAGE:
        raise ValueError(f"Unexpected application id: {package!r}")
    lines = [line.strip() for line in report.splitlines() if line.strip()]
    if f"package: {package}" not in lines:
        raise ValueError("Missing or unexpected package in aapt permissions report")

    seen: list[str] = []
    for line in lines:
        if line.startswith("uses-"):
            match = REQUEST.fullmatch(line)
            if match is None:
                raise ValueError(f"Unrecognized permission request format: {line}")
            permission = match.group(1)
            if permission != RECEIVER_PERMISSION:
                raise ValueError(f"Unexpected Android permission requested: {permission}")
            if line.startswith("uses-implied-"):
                raise ValueError("An implied permission was not explicitly reviewed")
            seen.append(permission)
        elif line.startswith("permission:"):
            # Declared custom permission is expected; it is not a permission request.
            declared = line.split(":", 1)[1].strip()
            if declared != RECEIVER_PERMISSION:
                raise ValueError(f"Unexpected custom permission declaration: {declared}")
        elif not line.startswith("package:"):
            raise ValueError(f"Unexpected aapt permissions report line: {line}")

    return seen


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--package", default=EXPECTED_PACKAGE)
    args = parser.parse_args()
    try:
        seen = audit_permissions(args.report.read_text(encoding="utf-8"), args.package)
    except (ValueError, OSError) as exc:
        print(f"Permission audit failed: {exc}", file=sys.stderr)
        return 1
    print(f"Permission audit PASS: only reviewed internal AndroidX receiver request ({len(seen)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
