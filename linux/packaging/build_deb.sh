#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bundle_dir="${1:-$repo_root/build/linux/x64/release/bundle}"
output_dir="${2:-$repo_root/build/linux/package}"

if [[ ! -x "$bundle_dir/ai_orchestrator" ]]; then
  echo "Linux Flutter bundle is missing: $bundle_dir" >&2
  exit 1
fi
if [[ ! -x "$bundle_dir/llama-completion" ]]; then
  echo "Bundled llama-completion is missing: $bundle_dir/llama-completion" >&2
  exit 1
fi

version="$(awk '/^version:/ {print $2; exit}' "$repo_root/pubspec.yaml")"
version="${version%%+*}"
if [[ -z "$version" ]]; then
  echo "Unable to determine package version from pubspec.yaml" >&2
  exit 1
fi

package_root="$output_dir/deb-root"
rm -rf "$package_root"
mkdir -p \
  "$package_root/DEBIAN" \
  "$package_root/usr/bin" \
  "$package_root/usr/lib/ai-orchestrator" \
  "$package_root/usr/share/applications" \
  "$package_root/usr/share/icons/hicolor/scalable/apps"

cp -a "$bundle_dir/." "$package_root/usr/lib/ai-orchestrator/"
install -m 0644 "$repo_root/linux/packaging/ai-orchestrator.desktop" \
  "$package_root/usr/share/applications/ai-orchestrator.desktop"
install -m 0644 "$repo_root/linux/packaging/ai-orchestrator.svg" \
  "$package_root/usr/share/icons/hicolor/scalable/apps/ai-orchestrator.svg"

cat > "$package_root/usr/bin/ai-orchestrator" <<'EOF'
#!/usr/bin/env bash
set -e
exec /usr/lib/ai-orchestrator/ai_orchestrator "$@"
EOF
chmod 0755 "$package_root/usr/bin/ai-orchestrator"

installed_kb="$(du -sk "$package_root/usr" | awk '{print $1}')"
cat > "$package_root/DEBIAN/control" <<EOF
Package: ai-orchestrator
Version: $version
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-3-0, libsecret-1-0, libasound2
Maintainer: AI Orchestrator
Installed-Size: $installed_kb
Description: AI Orchestrator desktop application
 Offline-first multi-platform AI assistant and app factory.
EOF

mkdir -p "$output_dir"
deb_path="$output_dir/AI-Orchestrator_${version}_amd64.deb"
rm -f "$deb_path" "$deb_path.sha256"
dpkg-deb --build --root-owner-group "$package_root" "$deb_path"
sha256sum "$deb_path" > "$deb_path.sha256"

echo "LINUX_DEB=$deb_path"
echo "LINUX_DEB_SHA256=$deb_path.sha256"
