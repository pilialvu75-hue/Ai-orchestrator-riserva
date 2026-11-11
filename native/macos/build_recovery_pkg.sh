#!/usr/bin/env bash
# Build a scoped, unsigned macOS recovery installer from an already verified
# official AI Orchestrator app bundle. No Apple Developer membership required.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <verified-app-bundle> <output.pkg> <expected-CFBundleVersion>" >&2
  exit 64
fi
app="$1"
output="$2"
expected_build="$3"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Recovery packages must be built on macOS." >&2
  exit 1
fi
[[ "$app" == *.app && -d "$app" ]] || { echo "Invalid .app bundle." >&2; exit 1; }
[[ "$output" == *.pkg ]] || { echo "Output must be a .pkg." >&2; exit 1; }
[[ "$expected_build" =~ ^[0-9]{2,10}$ ]] || { echo "Invalid build code." >&2; exit 1; }

plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || { echo "Info.plist missing." >&2; exit 1; }
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
[[ "$bundle_id" == "com.aiorchestrator" ]] || { echo "Unexpected bundle ID: $bundle_id" >&2; exit 1; }
[[ "$build" == "$expected_build" ]] || { echo "Unexpected build: $build" >&2; exit 1; }
[[ -x "$app/Contents/MacOS/llama-completion" ]] || { echo "Bundled local runtime missing." >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"
work="$(mktemp -d "/tmp/aivexus-recovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
scripts="$work/scripts"
mkdir -p "$stage/Applications" "$scripts"
/usr/bin/ditto "$app" "$stage/Applications/AI Orchestrator.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$stage/Applications/AI Orchestrator.app"

# This script executes only after the owner explicitly authorizes installation
# of the downloaded package. It does not alter global Gatekeeper policy or any
# app container (SQLite/chat/models/preferences remain in the user's Library).
cat > "$scripts/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -euo pipefail
app="/Applications/AI Orchestrator.app"
plist="$app/Contents/Info.plist"
if [[ ! -d "$app" || ! -f "$plist" ]]; then
  echo "Aivexus recovery: expected application was not installed." >&2
  exit 1
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
if [[ "$bundle_id" != "com.aiorchestrator" ]]; then
  echo "Aivexus recovery: unexpected installed bundle identifier." >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app" || {
  echo "Aivexus recovery: installed app failed signature integrity checks." >&2
  exit 1
}
# The old in-app sandbox downloader marked its own DMG as quarantined,
# and macOS refused exec/open: AppSandbox, NSPOSIXErrorDomain Code=153.
# Remove quarantine only from this verified user-selected application.
# Some macOS versions return a non-zero code when this attribute was
# already absent. That must not turn a valid installation into a failed PKG.
# Still fail if any quarantine attribute survives the attempted cleanup.
/usr/bin/xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
remaining_attributes="$(/usr/bin/xattr -lr "$app" 2>&1)" || {
  echo "Aivexus recovery: cannot inspect installed app attributes." >&2
  exit 1
}
if /usr/bin/grep -Fq 'com.apple.quarantine' <<< "$remaining_attributes"; then
  echo "Aivexus recovery: quarantine still present after cleanup." >&2
  exit 1
fi
echo "Aivexus recovery: verified application authorized; user data untouched."
exit 0
POSTINSTALL
chmod 0755 "$scripts/postinstall"

# Install to /Applications only. pkgbuild does not erase the user's Library.
# The package identifier is separate from the application's bundle identifier.
pkgbuild \
  --root "$stage" \
  --install-location "/" \
  --identifier "com.aiorchestrator.macos.recovery" \
  --version "$expected_build" \
  --ownership recommended \
  --scripts "$scripts" \
  "$output"

[[ -s "$output" ]] || { echo "Empty recovery package." >&2; exit 1; }
# Check that the installer payload cannot touch data outside the app bundle.
payload="$(pkgutil --payload-files "$output" | sed 's#^\./##')"
grep -Fq "Applications/AI Orchestrator.app/Contents/Info.plist" <<<"$payload" || {
  echo "Missing app payload." >&2; exit 1;
}
if grep -Ev '^(\.|Applications/?|Applications/AI Orchestrator\.app(/.*)?)$' <<<"$payload"; then
  echo "Recovery package has unexpected payload paths." >&2
  exit 1
fi
bytes="$(stat -f '%z' "$output")"
(( bytes > 1048576 )) || { echo "Recovery package too small." >&2; exit 1; }
digest="$(shasum -a 256 "$output" | awk '{print tolower($1)}')"
printf '%s  %s\n' "$digest" "$(basename "$output")" > "$output.sha256"
echo "RECOVERY_PKG=$output"
echo "RECOVERY_PKG_BYTES=$bytes"
echo "RECOVERY_PKG_SHA256=$digest"
