#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <app-bundle> <output-dmg>" >&2
  exit 64
fi

app_path="$1"
output_dmg="$2"
volume_name="${AI_ORCHESTRATOR_DMG_VOLUME_NAME:-AI Orchestrator}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "DMG packaging requires macOS." >&2
  exit 1
fi

for tool in hdiutil ditto codesign shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required macOS packaging tool is missing: $tool" >&2
    exit 1
  fi
done

if [[ ! -d "$app_path" || "${app_path##*.}" != "app" ]]; then
  echo "App bundle does not exist or is not a .app directory: $app_path" >&2
  exit 1
fi
if [[ ! -f "$app_path/Contents/Info.plist" ]]; then
  echo "App bundle is missing Contents/Info.plist: $app_path" >&2
  exit 1
fi

app_name="$(basename "$app_path")"
helper_relative="Contents/MacOS/llama-completion"
if [[ ! -x "$app_path/$helper_relative" ]]; then
  echo "App bundle is missing executable bundled runtime: $helper_relative" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_dmg")"
output_dmg="$(cd "$(dirname "$output_dmg")" && pwd)/$(basename "$output_dmg")"
rm -f "$output_dmg" "$output_dmg.sha256"

work_root="$(mktemp -d "${TMPDIR:-/tmp}/ai-orchestrator-dmg.XXXXXX")"
stage_dir="$work_root/stage"
mount_dir="$work_root/mount"
mkdir -p "$stage_dir" "$mount_dir"
mounted=false

cleanup() {
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || \
      hdiutil detach "$mount_dir" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$work_root"
}
trap cleanup EXIT

# Verify the source before copying it into the image.
codesign --verify --deep --strict --verbose=2 "$app_path"

ditto "$app_path" "$stage_dir/$app_name"
ln -s /Applications "$stage_dir/Applications"

# Ensure copying preserved the bundle and embedded helper before image creation.
codesign --verify --deep --strict --verbose=2 "$stage_dir/$app_name"
if [[ ! -x "$stage_dir/$app_name/$helper_relative" ]]; then
  echo "Staged app lost bundled runtime: $helper_relative" >&2
  exit 1
fi

hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$stage_dir" \
  -ov \
  -format UDZO \
  "$output_dmg"

if [[ ! -s "$output_dmg" ]]; then
  echo "Generated DMG is missing or empty: $output_dmg" >&2
  exit 1
fi

hdiutil verify "$output_dmg"

hdiutil attach \
  -readonly \
  -nobrowse \
  -noautoopen \
  -mountpoint "$mount_dir" \
  "$output_dmg" >/dev/null
mounted=true

mounted_app="$mount_dir/$app_name"
if [[ ! -d "$mounted_app" ]]; then
  echo "Mounted DMG does not contain $app_name" >&2
  exit 1
fi
if [[ ! -L "$mount_dir/Applications" || "$(readlink "$mount_dir/Applications")" != "/Applications" ]]; then
  echo "Mounted DMG is missing the /Applications install link" >&2
  exit 1
fi
if [[ ! -x "$mounted_app/$helper_relative" ]]; then
  echo "Mounted app is missing bundled llama-completion" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$mounted_app"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$mounted_app/Contents/Info.plist")"
if [[ "$bundle_id" != "com.aiorchestrator" ]]; then
  echo "Unexpected bundle identifier inside mounted DMG: $bundle_id" >&2
  exit 1
fi

hdiutil detach "$mount_dir" -quiet
mounted=false

size_bytes="$(stat -f '%z' "$output_dmg")"
if (( size_bytes < 1048576 )); then
  echo "Generated DMG is unexpectedly small: ${size_bytes} bytes" >&2
  exit 1
fi

sha256="$(shasum -a 256 "$output_dmg" | awk '{print tolower($1)}')"
printf '%s  %s\n' "$sha256" "$(basename "$output_dmg")" > "$output_dmg.sha256"

echo "DMG_PATH=$output_dmg"
echo "DMG_SIZE_BYTES=$size_bytes"
echo "DMG_SHA256=$sha256"
