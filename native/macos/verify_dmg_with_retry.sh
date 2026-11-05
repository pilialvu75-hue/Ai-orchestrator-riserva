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

for attempt in 1 2 3 4 5; do
  if output="$(hdiutil verify "$dmg" 2>&1)"; then
    printf '%s\n' "$output"
    exit 0
  fi

  printf '%s\n' "$output" >&2
  if [[ "$output" != *"Resource temporarily unavailable"* || "$attempt" -eq 5 ]]; then
    echo "DMG verification failed: non-transient error or retries exhausted." >&2
    exit 1
  fi

  echo "macOS disk image service temporarily busy; retrying verification ($attempt/5)." >&2
  sleep 2
done

exit 1
