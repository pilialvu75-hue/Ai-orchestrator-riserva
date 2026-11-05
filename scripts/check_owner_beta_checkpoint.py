#!/usr/bin/env python3
"""Offline security regression gate for owner-triggered beta checkpoints.

Production releases still require Build & Release APK's workflow_dispatch
with release_channel=beta, stable is never dispatched automatically.
An explicitly labeled checkpoint PR merged by the repository owner may
also authorize the beta after source CI passes.
A public issue/comment cannot cause deployment unless both the issue and
comment are owned by the actual repository owner, and the pinned issue
number and exact current source SHA match.
"""
from pathlib import Path
import re
import sys


def validate(source: str) -> list[str]:
    problems: list[str] = []
    required = [
        "  issue_comment:",
        "    types: [created]",
        "  pull_request:",
        "types: [opened, reopened, synchronize, closed]",
        "github.event.action == 'closed'",
        "github.event.pull_request.merged == true",
        "github.event.pull_request.base.ref == 'main'",
        "github.event.pull_request.user.login == github.repository_owner",
        "contains(github.event.pull_request.title, '[beta-checkpoint]')",
        "'.pull_request.merge_commit_sha // \"\"'",
        "github.event.issue.number == 1008",
        "github.event.issue.pull_request == null",
        "github.event.issue.state == 'open'",
        "github.actor == github.repository_owner",
        "github.event.issue.user.login == github.repository_owner",
        "github.event.comment.user.login == github.repository_owner",
        "startsWith(github.event.comment.body, '/aivexus beta-checkpoint ')",
        "github.event_name == 'issue_comment'",
        "github.event_name == 'pull_request'",
        "  actions: write",
        "  contents: read",
        "  cancel-in-progress: false",
        "([0-9a-f]{40})$",
        "main_sha=",
        '[[ "$sha" != "$main_sha" ]]',
        '"Assistant Shared Tests"',
        '"Web Cantiere Build"',
        '"Build Linux Desktop"',
        '"Build Windows Desktop"',
        '"Build macOS Desktop"',
        '(.conclusion // "pending")',
        'github.event_name ==',
        'gh workflow run build.yml --ref main -f release_channel=beta',
        'gh api -X GET "repos/$GITHUB_REPOSITORY/actions/runs"',
        "-f head_sha=\"$sha\" -f event=push",
        "-f head_sha=\"$sha\" -f event=workflow_dispatch",
        '"$GITHUB_EVENT_PATH"',
    ]
    for marker in required:
        if marker not in source:
            problems.append(f"Missing owner beta checkpoint gate: {marker}")
    if re.search(r"(?m)^  push:", source):
        problems.append("Comment dispatcher must not activate on arbitrary push")
    if "gh workflow run build.yml --ref main -f release_channel=stable" in source:
        problems.append("Stable release must remain an explicitly manual channel")
    if "gh workflow run build.yml --ref main -f release_channel=beta" not in source:
        problems.append("No authorized beta dispatch")
    if not re.search(r"(?m)^  authorize-and-dispatch:\s*$", source):
        problems.append("Missing owner-gated dispatch job")
    if not re.search(r"(?m)^  contract:\s*$", source):
        problems.append("Missing PR-only verification job")
    if len(re.findall(r"\bgh workflow run\b", source)) != 1:
        problems.append("Only one approved downstream dispatch is allowed")
    return problems


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        ".github/workflows/owner-beta-checkpoint.yml"
    )
    errors = validate(path.read_text(encoding="utf-8"))
    for error in errors:
        print(f"::error::{error}")
    if errors:
        return 1
    print("Owner-only issue command -> CI-gated manual-beta workflow dispatch: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
