#!/usr/bin/env bash
# Portable fake-hdiutil regression tests; never rely on a mounted real DMG.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
helper="$repo_root/native/macos/verify_dmg_with_retry.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
printf 'synthetic image for mocked hdiutil\n' > "$work/fake.dmg"

cat > "$work/bin/hdiutil" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "verify" && "$#" -eq 2 ]] || exit 90
count="$(cat "$MOCK_CALLS_FILE")"
count="$((count + 1))"
printf '%s\n' "$count" > "$MOCK_CALLS_FILE"
case "$MOCK_MODE" in
  success) echo 'verify: valid'; exit 0 ;;
  busy-once)
    if (( count == 1 )); then
      echo 'hdiutil: verify failed - Resource temporarily unavailable' >&2
      exit 1
    fi
    echo 'verify: valid'
    exit 0
    ;;
  busy-six)
    if (( count <= 6 )); then
      echo 'hdiutil: verify failed - Resource temporarily unavailable' >&2
      exit 1
    fi
    echo 'verify: valid after backoff'
    exit 0
    ;;
  always-busy)
    echo 'hdiutil: verify failed - Resource temporarily unavailable' >&2
    exit 1
    ;;
  invalid-image)
    echo 'hdiutil: verify failed - not recognized as a disk image' >&2
    exit 1
    ;;
  *) exit 91 ;;
esac
MOCK
cat > "$work/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" =~ ^[2-8]$ ]] || exit 92
exit 0
MOCK
chmod +x "$work/bin/hdiutil" "$work/bin/sleep"

test_case() {
  local mode="$1"
  local expected_status="$2"
  local expected_calls="$3"
  printf '0\n' > "$work/calls"
  local status=0
  MOCK_MODE="$mode" MOCK_CALLS_FILE="$work/calls" \
    PATH="$work/bin:$PATH" bash "$helper" "$work/fake.dmg" \
      > "$work/stdout" 2> "$work/stderr" || status=$?
  if [[ "$status" != "$expected_status" ]]; then
    echo "FAIL $mode: expected status $expected_status, got $status" >&2
    cat "$work/stderr" >&2
    exit 1
  fi
  if [[ "$(cat "$work/calls")" != "$expected_calls" ]]; then
    echo "FAIL $mode: expected $expected_calls hdiutil calls" >&2
    cat "$work/stderr" >&2
    exit 1
  fi
  echo "PASS $mode: status $status, $expected_calls verify attempt(s)"
}

test_case success 0 1
test_case busy-once 0 2
test_case busy-six 0 7
test_case always-busy 1 10
test_case invalid-image 1 1

# Empty/missing images fail before any external disk-image utility is called.
printf '0\n' > "$work/calls"
if MOCK_MODE=success MOCK_CALLS_FILE="$work/calls" PATH="$work/bin:$PATH" \
  bash "$helper" "$work/missing.dmg" >/dev/null 2>&1; then
  echo 'FAIL missing image unexpectedly accepted' >&2
  exit 1
fi
[[ "$(cat "$work/calls")" == "0" ]] || exit 1
echo 'PASS missing image never calls hdiutil'

bash -n "$helper"
bash -n "$repo_root/native/macos/package_dmg.sh"
echo 'All macOS DMG verification retry contract tests passed'
