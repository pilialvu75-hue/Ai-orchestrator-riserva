#!/usr/bin/env python3
"""Fail-closed static contract for the inert main-branch workflow registration."""
from pathlib import Path
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


if __name__ == "__main__":
    try:
        verify(PATH.read_text(encoding="utf-8"))
    except Exception as error:
        print("CANTIERE_DISPATCH_BOOTSTRAP_FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
    print("CANTIERE_DISPATCH_BOOTSTRAP_INERT_PASS")
