#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 7 ]]; then
  echo "Usage: $0 <app_path> <dmg_path> <developer_id_identity> <notary_key_path> <notary_key_id> <notary_issuer_id> <entitlements>" >&2
  exit 64
fi

app_path="$1"
dmg_path="$2"
identity="$3"
notary_key_path="$4"
notary_key_id="$5"
notary_issuer_id="$6"
entitlements="$7"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package_script="$repo_root/native/macos/package_dmg.sh"

for required in "$app_path" "$notary_key_path" "$entitlements" "$package_script"; do
  if [[ ! -e "$required" ]]; then
    echo "Required path is missing: $required" >&2
    exit 66
  fi
done

if [[ "$identity" != Developer\ ID\ Application:* ]]; then
  echo "Refusing non-Developer-ID identity: $identity" >&2
  exit 65
fi

mkdir -p "$(dirname "$dmg_path")"
work_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ai-orchestrator-notary.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

notary_submit() {
  local artifact="$1"
  local label="$2"
  local log_path="$work_dir/${label}.json"

  xcrun notarytool submit "$artifact" \
    --key "$notary_key_path" \
    --key-id "$notary_key_id" \
    --issuer "$notary_issuer_id" \
    --wait \
    --output-format json | tee "$log_path"

  python3 - "$log_path" "$label" <<'PY'
import json
import sys

path, label = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

status = str(payload.get("status", "")).strip()
submission_id = str(payload.get("id", "")).strip()
if status.lower() != "accepted":
    raise SystemExit(
        f"{label} notarization was not accepted: status={status!r} id={submission_id!r}"
    )

print(f"NOTARY_ACCEPTED label={label} id={submission_id}")
PY
}

helper_path="$app_path/Contents/MacOS/llama-completion"
if [[ ! -x "$helper_path" ]]; then
  echo "Bundled llama-completion helper is missing: $helper_path" >&2
  exit 66
fi

echo "Signing app with Developer ID identity: $identity"

# Sign loose nested Mach-O objects first.
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q '^Mach-O'; then
    codesign --force \
      --sign "$identity" \
      --options runtime \
      --timestamp \
      "$candidate"
  fi
done < <(
  find "$app_path/Contents" -type f \
    ! -path "$app_path/Contents/MacOS/*" \
    -print0
)

codesign --force \
  --sign "$identity" \
  --options runtime \
  --timestamp \
  "$helper_path"

# Sign nested bundles deepest-first, then the outer app.
if [[ -d "$app_path/Contents/Frameworks" ]]; then
  while IFS= read -r nested_bundle; do
    codesign --force \
      --sign "$identity" \
      --options runtime \
      --timestamp \
      "$nested_bundle"
  done < <(
    find "$app_path/Contents/Frameworks" -depth -type d \
      \( -name '*.framework' -o -name '*.app' -o -name '*.appex' -o -name '*.xpc' \) \
      | awk '{ print length($0), $0 }' \
      | sort -rn \
      | cut -d' ' -f2-
  )
fi

codesign --force \
  --sign "$identity" \
  --options runtime \
  --timestamp \
  --entitlements "$entitlements" \
  "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"

app_zip="$work_dir/AI-Orchestrator.app.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$app_zip"
notary_submit "$app_zip" "app"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

rm -f "$dmg_path" "$dmg_path.sha256"
bash "$package_script" "$app_path" "$dmg_path"

if [[ ! -s "$dmg_path" ]]; then
  echo "DMG packager produced no distribution image." >&2
  exit 1
fi

codesign --force \
  --sign "$identity" \
  --timestamp \
  "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"

notary_submit "$dmg_path" "dmg"
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"

spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$dmg_path"

# Signing, notarization and stapling mutate the container. Publish only the
# digest calculated after every trust mutation has completed.
dmg_sha256="$(shasum -a 256 "$dmg_path" | awk '{print tolower($1)}')"
printf '%s  %s\n' "$dmg_sha256" "$(basename "$dmg_path")" > "$dmg_path.sha256"

echo "MACOS_NOTARIZED_RELEASE_OK"
echo "dmg_path=$dmg_path"
echo "dmg_sha256=$dmg_sha256"
