#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
legacy_dir="$repo_root/legacy_macos"
build_root="${AI_ORCHESTRATOR_LEGACY_BUILD_DIR:-$repo_root/build/macos-high-sierra-app}"
app="$build_root/AI Orchestrator Legacy.app"
contents="$app/Contents"
macos_dir="$contents/MacOS"
resources_dir="$contents/Resources"
helper="${LLAMA_MACOS_HIGH_SIERRA_HELPER:-$repo_root/build/llama-macos-high-sierra/bin/llama-cli}"
executable="$macos_dir/AI Orchestrator Legacy"

if [[ ! -x "$helper" ]]; then
  echo "High Sierra llama helper is missing: $helper" >&2
  echo "Run native/macos_legacy/build_llama_cli.sh first." >&2
  exit 1
fi

rm -rf "$build_root"
mkdir -p "$macos_dir" "$resources_dir"

cp "$legacy_dir/Info.plist" "$contents/Info.plist"
cp "$helper" "$resources_dir/llama-cli"
chmod 0755 "$resources_dir/llama-cli"

clang \
  -fobjc-arc \
  -Wall -Wextra -Werror \
  -mmacosx-version-min=10.13 \
  -framework Cocoa \
  "$legacy_dir/main.m" \
  -o "$executable"

chmod 0755 "$executable"

if [[ "$(lipo -archs "$executable")" != "x86_64" ]]; then
  echo "Legacy app executable must be x86_64" >&2
  lipo -archs "$executable" >&2 || true
  exit 1
fi

check_minimum_target() {
  local binary="$1"
  local commands
  commands="$(otool -l "$binary")"
  if ! awk '
    /LC_BUILD_VERSION/ { in_build=1; next }
    /LC_VERSION_MIN_MACOSX/ { in_legacy=1; next }
    in_build && /minos/ { if ($2 == "10.13" || $2 ~ /^10\.13\./) ok=1; in_build=0 }
    in_legacy && /version/ { if ($2 == "10.13" || $2 ~ /^10\.13\./) ok=1; in_legacy=0 }
    END { exit ok ? 0 : 1 }
  ' <<<"$commands"; then
    echo "Binary does not advertise macOS 10.13 minimum: $binary" >&2
    otool -l "$binary" | grep -A4 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' >&2 || true
    exit 1
  fi
}

check_portable_dependencies() {
  local binary="$1"
  local deps
  deps="$(otool -L "$binary" | awk '/^\t/{print}')"
  if grep -Eq '/(opt/homebrew|usr/local|Users|private|Volumes)/' <<<"$deps"; then
    echo "Non-portable dependency in $binary" >&2
    printf '%s\n' "$deps" >&2
    exit 1
  fi
}

check_minimum_target "$executable"
check_minimum_target "$resources_dir/llama-cli"
check_portable_dependencies "$executable"
check_portable_dependencies "$resources_dir/llama-cli"

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$contents/Info.plist")" != "10.13" ]]; then
  echo "Info.plist minimum system version is not 10.13" >&2
  exit 1
fi

# Ad-hoc signing is enough for a private physical compatibility test. Public
# distribution/notarization remains a separate modern release concern.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

"$executable" --self-test

printf 'AI_ORCHESTRATOR_HIGH_SIERRA_APP=%s\n' "$app"
