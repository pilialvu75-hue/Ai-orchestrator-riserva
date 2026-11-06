#!/usr/bin/env python3
"""Strict non-secret manifest for coordinated, owner-authorized HYBRID betas.

The release asset is read only after checking the Android run and the release
tag/SHA. It is an integrity/provenance cross-check, NOT a digital signature.
Default release behavior is always consent-gate OFF.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

FIELDS = ("format", "source_sha", "run_number", "release_tag", "channel", "enabled")
FORMAT = "AIVEXUS_HYBRID_BETA_V1"
SHA = re.compile(r"^[0-9a-f]{40}$")
TAG = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+(?:-(beta|nightly|dev))?\+[0-9]+$")
CHANNELS = {"stable", "beta", "nightly", "dev", "ci"}


def _validate(data: dict[str, str], *, source_sha: str, run_number: str,
              tag: str) -> str:
    if tuple(data) != FIELDS or data["format"] != FORMAT:
        raise ValueError("Unexpected HYBRID beta manifest format or fields")
    if not SHA.fullmatch(source_sha) or not run_number.isdigit() or int(run_number) < 1:
        raise ValueError("Invalid release SHA or run number")
    if not TAG.fullmatch(tag) or data["release_tag"] != tag:
        raise ValueError("Release tag mismatch")
    if data["source_sha"] != source_sha or data["run_number"] != run_number:
        raise ValueError("HYBRID beta manifest does not match authorized Android run")
    channel, enabled = data["channel"], data["enabled"]
    if channel not in CHANNELS or enabled not in {"true", "false"}:
        raise ValueError("Invalid channel or HYBRID beta flag")
    tag_channel = TAG.fullmatch(tag).group(1) or "stable"
    if (channel == "ci" and tag_channel != "stable") or (
        channel != "ci" and tag_channel != channel
    ):
        raise ValueError("Release channel and tag disagree")
    if enabled == "true" and channel != "beta":
        raise ValueError("HYBRID consent is allowed ONLY on explicitly opted-in beta")
    return enabled


def make(source_sha: str, run_number: str, tag: str,
         channel: str, enabled: str) -> str:
    data = dict(zip(FIELDS, (FORMAT, source_sha, run_number, tag, channel, enabled)))
    _validate(data, source_sha=source_sha, run_number=run_number, tag=tag)
    return "".join(f"{key}={data[key]}\n" for key in FIELDS)


def resolve(path: Path, source_sha: str, run_number: str, tag: str) -> str:
    if not path.is_file():
        raise ValueError("Missing HYBRID beta attestation on a new-format release")
    pairs = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        if "=" not in raw:
            raise ValueError("Malformed HYBRID beta attestation line")
        pairs.append(raw.split("=", 1))
    if len(pairs) != len(FIELDS) or [k for k, _ in pairs] != list(FIELDS):
        raise ValueError("Duplicate, missing or re-ordered attestation fields")
    data = dict(pairs)
    flag = _validate(data, source_sha=source_sha, run_number=run_number, tag=tag)
    if path.read_text(encoding="utf-8") != make(
        source_sha, run_number, tag, data["channel"], flag
    ):
        raise ValueError("Non-canonical HYBRID beta attestation")
    return flag


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("emit", "resolve"))
    parser.add_argument("--path", required=True, type=Path)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--run-number", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--channel", choices=sorted(CHANNELS))
    parser.add_argument("--enabled", choices=("true", "false"))
    args = parser.parse_args()
    try:
        if args.mode == "emit":
            if args.channel is None or args.enabled is None:
                raise ValueError("Emit requires channel and explicit enabled flag")
            args.path.write_text(
                make(args.source_sha, args.run_number, args.tag,
                     args.channel, args.enabled), encoding="utf-8"
            )
        else:
            print(resolve(args.path, args.source_sha, args.run_number, args.tag))
    except (ValueError, OSError) as exc:
        print(f"HYBRID beta manifest rejected: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
