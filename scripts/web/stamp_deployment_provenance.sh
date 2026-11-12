#!/usr/bin/env bash
# Stamp only public, non-sensitive source identity into a protected Pages build.
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo 'Usage: stamp_deployment_provenance.sh BUILD_DIR GIT_SHA GITHUB_RUN_ID' >&2
  exit 2
fi
build_dir="$1"
git_sha="$2"
run_id="$3"
if [[ ! "$git_sha" =~ ^[0-9a-f]{40}$ ]] || [[ ! "$run_id" =~ ^[1-9][0-9]*$ ]]; then
  echo 'Invalid deployment identity.' >&2
  exit 2
fi
if [[ ! -s "$build_dir/index.html" ]] || [[ ! -s "$build_dir/main.dart.js" ]]; then
  echo 'Web build artifacts missing.' >&2
  exit 2
fi

tmp="$(mktemp "$build_dir/.aivexus-web-deployment.XXXXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '{"schemaVersion":1,"product":"aivexus-web","gitSha":"%s","githubRunId":"%s"}\n' \
  "$git_sha" "$run_id" > "$tmp"
mv -f -- "$tmp" "$build_dir/__aivexus_web_deployment.json"
