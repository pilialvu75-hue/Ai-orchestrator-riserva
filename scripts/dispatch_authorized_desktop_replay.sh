#!/usr/bin/env bash
# Dispatch missing desktop installers ONLY for an existing signed Android
# workflow_dispatch release from this repository. No release is created here.
set -euo pipefail
repo="pilialvu75-hue/Ai-orchestrator-riserva"
request="release-requests/replay-desktop.txt"

test "$GITHUB_REPOSITORY" = "$repo"
test -f "$request"
test "$(wc -l < "$request")" -eq 3
grep -Fxq 'channel=desktop-replay' "$request"
test "$(grep -c '^android_run_id=' "$request")" -eq 1
test "$(grep -c '^main_sha=' "$request")" -eq 1
run_id="$(sed -n 's/^android_run_id=//p' "$request")"
expected_sha="$(sed -n 's/^main_sha=//p' "$request")"
[[ "$run_id" =~ ^[0-9]{6,16}$ ]] || { echo 'Invalid Android workflow run ID' >&2; exit 1; }
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid expected source SHA' >&2; exit 1; }

source_run="$(gh api "repos/$repo/actions/runs/$run_id")"
jq -e --arg repo "$repo" --arg sha "$expected_sha" '
  .name == "Build & Release APK" and
  .event == "workflow_dispatch" and
  .status == "completed" and
  .conclusion == "success" and
  .head_branch == "main" and
  .repository.full_name == $repo and
  .head_sha == $sha and
  (.run_number > 0)
' <<< "$source_run" >/dev/null || {
  echo 'Source is not an authorized successful Android release of this exact commit' >&2
  exit 1
}
run_number="$(jq -r '.run_number' <<< "$source_run")"
code="$((100000 + run_number))"
version_name="$(gh api "repos/$repo/contents/pubspec.yaml?ref=$expected_sha" --jq '.content' |
  base64 -d | sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)(\+[0-9]+)?[[:space:]]*$/\1/p' | head -n 1)"
[[ "$version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'Missing valid application semantic version' >&2
  exit 1
}

matching_tag=""
for channel in stable beta nightly dev; do
  if [ "$channel" = stable ]; then
    candidate="v$version_name+$code"
    expected_pre=false
  else
    candidate="v$version_name-$channel+$code"
    expected_pre=true
  fi
  prerelease="$(gh release view "$candidate" --repo "$repo" --json isPrerelease --jq '.isPrerelease' 2>/dev/null || true)"
  [ "$prerelease" = "$expected_pre" ] || continue
  candidate_sha="$(gh api "repos/$repo/git/ref/tags/$candidate" --jq '.object.sha' 2>/dev/null || true)"
  [ "$candidate_sha" = "$expected_sha" ] || continue
  [ -z "$matching_tag" ] || { echo 'More than one matching authorized tag' >&2; exit 1; }
  matching_tag="$candidate"
done

[ -n "$matching_tag" ] || { echo 'No matching published authorized GitHub Release' >&2; exit 1; }
assets="$(gh release view "$matching_tag" --repo "$repo" --json assets --jq '.assets[].name')"
grep -Fxq 'app-release.apk' <<< "$assets" || { echo 'Published Android APK asset missing' >&2; exit 1; }

echo "Verified existing Android release $matching_tag (run $run_id)."
echo "Dispatching official Windows/macOS publishers on main, no Android rebuild."
gh workflow run windows-release-publish.yml --repo "$repo" --ref main -f android_run_id="$run_id"
gh workflow run macos-release-publish.yml --repo "$repo" --ref main -f android_run_id="$run_id"
echo "Desktop replay dispatch requested. Check publisher runs and signing/notarization gates."
