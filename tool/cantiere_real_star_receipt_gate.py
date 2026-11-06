#!/usr/bin/env python3
"""Verify a synthetic-safe four-role receipt binds to the exact star APK.

This is a receipt consistency check, NOT independent proof of actual upstream
model identity or a working star on a device.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

REQUIRED_ROLES = ("orchestration", "architecture_reasoning", "coding", "review")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def validate(apk: Path, receipt: Path):
    if not apk.is_file() or apk.stat().st_size == 0:
        raise ValueError("APK_MISSING")
    if not receipt.is_file() or receipt.stat().st_size == 0:
        raise ValueError("RECEIPT_MISSING")
    if receipt.stat().st_size > 65536:
        raise ValueError("RECEIPT_TOO_LARGE")
    data = json.loads(receipt.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("gate") != "REAL_STAR_PRODUCTION_BUILD":
        raise ValueError("RECEIPT_INVALID_GATE")
    if data.get("production_lifecycle") != "existing_cantiere":
        raise ValueError("RECEIPT_WRONG_LIFECYCLE")
    if data.get("four_roles_replied") is not True or data.get("artifact_built") is not True:
        raise ValueError("RECEIPT_MISSING_COMPLETION")
    expected = data.get("apk_sha256")
    if not isinstance(expected, str) or not SHA256.fullmatch(expected):
        raise ValueError("RECEIPT_INVALID_SHA256")
    digest = hashlib.sha256()
    with apk.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if expected != digest.hexdigest():
        raise ValueError("APK_RECEIPT_HASH_MISMATCH")
    if any(data.get(key) is not False for key in (
        "independent_model_generation_provenance_verified",
        "emulator_visual_verified",
        "geometric_star_verified",
        "android_local_verified",
        "windows_local_verified",
    )):
        raise ValueError("RECEIPT_PREMATURE_SUCCESS_CLAIM")
    roles = data.get("role_receipts")
    if not isinstance(roles, dict) or set(roles) != set(REQUIRED_ROLES):
        raise ValueError("RECEIPT_WRONG_ROLE_SET")
    for role in REQUIRED_ROLES:
        record = roles[role]
        if not isinstance(record, dict) or type(record.get("successful_calls")) is not int or record["successful_calls"] < 1:
            raise ValueError("RECEIPT_ROLE_CALL_MISSING_" + role)
        models = record.get("models")
        if not isinstance(models, list) or not models or not all(
            isinstance(item, str) and 0 < len(item.strip()) <= 200 for item in models
        ):
            raise ValueError("RECEIPT_ROLE_MODEL_MISSING_" + role)
    return expected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    sha = validate(args.apk, args.receipt)
    print("CANTIERE_REAL_STAR_RECEIPT_BINDING_PASS sha256=" + sha)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("CANTIERE_REAL_STAR_RECEIPT_GATE_FAIL: " + str(exc), file=sys.stderr)
        sys.exit(1)
