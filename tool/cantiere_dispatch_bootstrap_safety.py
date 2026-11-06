#!/usr/bin/env python3
"""Fail-closed static contract for the inert main-branch workflow registration."""
from pathlib import Path
import os
import re
import sys

PATH = Path(".github/workflows/cantiere-real-star-production.yml")


def verify(text):
    # Deliberately exact: all production logic must live in the reviewed
    # experimental branch; changes to this bootstrap require explicit review.
    forbidden = (
        r"\$\{\{",
        r"\bsecrets\b",
        r"\bvars\.",
        r"\bworkflow_call\b",
        r"\bpush\b",
        r"\bpull_request\b",
        r"\bcurl\b",
        r"\bwget\b",
        r"\bdart\s+run\b",
        r"\bflutter\b",
        r"\btoken\b",
        r"\bhttps?://",
    )
    for expression in forbidden:
        if re.search(expression, text, re.IGNORECASE):
            raise AssertionError("BOOTSTRAP_FORBIDDEN_DIRECTIVE: " + expression)
    if not re.search(r"(?m)^on:\s*\n\s+workflow_dispatch:\s*$", text):
        raise AssertionError("BOOTSTRAP_MISSING_MANUAL_DISPATCH")
    if not re.search(r"(?m)^permissions:\s*\n\s+contents:\s*read\s*$", text):
        raise AssertionError("BOOTSTRAP_PERMISSIONS_NOT_READ_ONLY")
    if not re.search(r"(?m)^  registration-only:\s*$", text):
        raise AssertionError("BOOTSTRAP_NOT_REGISTRATION_ONLY")
    if len(re.findall(r"(?m)^  [a-zA-Z0-9_-]+:\s*$", text.split("jobs:", 1)[-1])) != 1:
        raise AssertionError("BOOTSTRAP_UNEXPECTED_EXTRA_JOB")
    if "CANTIERE_DISPATCH_REGISTRATION_ONLY" not in text:
        raise AssertionError("BOOTSTRAP_MARKER_MISSING")


def verify_experimental(text):
    """Fail closed on real-star workflows, with no automatic provider launch."""
    if os.environ.get("GITHUB_EVENT_NAME") != "pull_request":
        raise AssertionError("EXPERIMENTAL_REQUIRES_PULL_REQUEST")
    if os.environ.get("GITHUB_HEAD_REF") != "cantiere/real-star-after-bootstrap-20261106":
        raise AssertionError("EXPERIMENTAL_BRANCH_NOT_ALLOWLISTED")
    if not re.search(r"(?m)^  workflow_dispatch:\s*$", text):
        raise AssertionError("EXPERIMENTAL_MANUAL_DISPATCH_MISSING")
    if not re.search(r"(?m)^permissions:\s*\n\s+contents:\s*read\s*$", text):
        raise AssertionError("EXPERIMENTAL_PERMISSIONS_NOT_READ_ONLY")
    if not re.search(r"(?m)^  source-check:\s*$", text):
        raise AssertionError("EXPERIMENTAL_SOURCE_CHECK_MISSING")
    for job in ("real-star-opt-in", "real-star-emulator"):
        match = re.search(
            r"(?ms)^  " + re.escape(job) + r":\s*\n(.*?)(?=^  [a-zA-Z0-9_-]+:\s*$|\Z)",
            text,
        )
        if match is None or not re.search(
            r"(?m)^    if: github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/cantiere/real-star-after-bootstrap-20261106'\s*$",
            match.group(1),
        ):
            raise AssertionError("EXPERIMENTAL_JOB_NOT_MANUAL_ONLY: " + job)
    for marker in (
        "CANTIERE_ZERO_COST_ROUTES_VERIFIED",
        "CANTIERE_CF_ACCESS_CLIENT_ID",
        "CANTIERE_CF_ACCESS_CLIENT_SECRET",
        "cantiere_real_star_receipt_gate.py",
        "cantiere_real_star_emulator_probe.py",
    ):
        if marker not in text:
            raise AssertionError("EXPERIMENTAL_REQUIRED_GATE_MISSING: " + marker)
    for forbidden in (
        r"(?m)^  push:",
        r"(?m)^  schedule:",
        r"pull_request_target",
        r"continue-on-error:\s*true",
    ):
        if re.search(forbidden, text):
            raise AssertionError("EXPERIMENTAL_FORBIDDEN_DIRECTIVE: " + forbidden)


if __name__ == "__main__":
    try:
        content = PATH.read_text(encoding="utf-8")
        if os.environ.get("GITHUB_HEAD_REF") == "cantiere/real-star-after-bootstrap-20261106":
            verify_experimental(content)
            print("CANTIERE_EXPERIMENTAL_MANUAL_GATE_PASS")
        else:
            verify(content)
            print("CANTIERE_DISPATCH_BOOTSTRAP_INERT_PASS")
    except Exception as error:
        print("CANTIERE_DISPATCH_SAFETY_FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
