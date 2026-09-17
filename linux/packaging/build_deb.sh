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
if [[ ! -f "$repo_root/native/linux/llama-runtime" ]]; then
  echo "Linux runtime wrapper is missing: $repo_root/native/linux/llama-runtime" >&2
  exit 1
fi

version="${AI_ORCHESTRATOR_PACKAGE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$repo_root/pubspec.yaml")}"
version="${version#v}"
if [[ -z "$version" ]]; then
  echo "Unable to determine package version from pubspec.yaml" >&2
  exit 1
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+~-][0-9A-Za-z.+~:-]+)*$ ]]; then
  echo "Invalid Debian package version: $version" >&2
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
install -m 0755 "$repo_root/native/linux/llama-runtime" \
  "$package_root/usr/lib/ai-orchestrator/llama-runtime"
install -m 0644 "$repo_root/linux/packaging/ai-orchestrator.desktop" \
  "$package_root/usr/share/applications/ai-orchestrator.desktop"
install -m 0644 "$repo_root/linux/packaging/ai-orchestrator.svg" \
  "$package_root/usr/share/icons/hicolor/scalable/apps/ai-orchestrator.svg"

cat > "$package_root/usr/bin/ai-orchestrator" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
runtime_root=/usr/lib/ai-orchestrator
export LLAMA_CPP_EXECUTABLE="${LLAMA_CPP_EXECUTABLE:-$runtime_root/llama-runtime}"
exec "$runtime_root/ai_orchestrator" "$@"
EOF
chmod 0755 "$package_root/usr/bin/ai-orchestrator"

cat > "$package_root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$package_root/DEBIAN/postinst"

cat > "$package_root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$package_root/DEBIAN/postrm"

installed_kb="$(du -sk "$package_root/usr" | awk '{print $1}')"
cat > "$package_root/DEBIAN/control" <<EOF
Package: ai-orchestrator
Version: $version
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-3-0t64 | libgtk-3-0, libsecret-1-0, libasound2t64 | libasound2, xdg-utils
Maintainer: AI Orchestrator
Installed-Size: $installed_kb
Homepage: https://github.com/pilialvu75-hue/Ai-orchestrator-riserva
Description: AI Orchestrator desktop application
 Offline-first multi-platform AI assistant and app factory.
EOF

# Fail the package build if the installed launcher would ever fall back to an
# unbundled system llama-cli. This checks the exact files that enter the .deb.
test -x "$package_root/usr/lib/ai-orchestrator/llama-completion"
test -x "$package_root/usr/lib/ai-orchestrator/llama-runtime"
test -x "$package_root/usr/bin/ai-orchestrator"
bash -n "$package_root/usr/lib/ai-orchestrator/llama-runtime"
bash -n "$package_root/usr/bin/ai-orchestrator"
grep -Fq 'LLAMA_CPP_EXECUTABLE' "$package_root/usr/bin/ai-orchestrator"
grep -Fq '/usr/lib/ai-orchestrator' "$package_root/usr/bin/ai-orchestrator"
grep -Fq 'llama-completion' "$package_root/usr/lib/ai-orchestrator/llama-runtime"

mkdir -p "$output_dir"
deb_path="$output_dir/AI-Orchestrator_${version}_amd64.deb"
rm -f "$deb_path" "$deb_path.sha256"
dpkg-deb --build --root-owner-group "$package_root" "$deb_path"
sha256sum "$deb_path" > "$deb_path.sha256"

echo "LINUX_DEB=$deb_path"
echo "LINUX_DEB_SHA256=$deb_path.sha256"
