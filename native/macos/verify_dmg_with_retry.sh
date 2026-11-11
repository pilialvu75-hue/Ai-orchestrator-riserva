#!/usr/bin/env bash
# hdiutil's diskimages helper can briefly return EAGAIN immediately after
# creating a valid UDZO image on shared GitHub macOS runners. Retry ONLY this
# transient condition; never ignore corruption, missing files or other errors.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <image.dmg>" >&2
  exit 64
fi

dmg="$1"
if [[ ! -s "$dmg" ]]; then
  echo "DMG is missing or empty: $dmg" >&2
  exit 1
fi

# Shared GitHub macOS runners can hold the disk image service for longer than
# the original 5 x 2 s window. Back off for EAGAIN only; do not accept a DMG
# without a real successful hdiutil verify.
max_attempts=10
for (( attempt=1; attempt<=max_attempts; attempt++ )); do
  if output="$(hdiutil verify "$dmg" 2>&1)"; then
    printf '%s\n' "$output"
    exit 0
  fi

  printf '%s\n' "$output" >&2
  if [[ "$output" != *"Resource temporarily unavailable"* || "$attempt" -eq "$max_attempts" ]]; then
    echo "DMG verification failed: non-transient error or retries exhausted." >&2
    exit 1
  fi

  delay="$((attempt + 1))"
  if (( delay > 8 )); then delay=8; fi
  echo "macOS disk image service temporarily busy; retrying verification ($attempt/$max_attempts) in ${delay}s." >&2
  sleep "$delay"
done

exit 1
