#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_dir="$repo_root/third_party/llama.cpp"
build_dir="${LLAMA_MACOS_LEGACY_BUILD_DIR:-$repo_root/build/llama-macos-high-sierra}"

if [[ ! -f "$source_dir/CMakeLists.txt" ]]; then
  echo "llama.cpp submodule is missing at $source_dir" >&2
  exit 1
fi

# High Sierra legacy target: x86_64 only, CPU only, no Metal and no host-native
# CPU tuning. The MacBook7,1 test machine has a Core 2 Duo and a non-Metal GPU,
# so compatibility is more important than build-host-specific optimizations.
cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.13 \
  "-DCMAKE_C_FLAGS=-mmacosx-version-min=10.13 -ffile-prefix-map=$repo_root=." \
  "-DCMAKE_CXX_FLAGS=-mmacosx-version-min=10.13 -ffile-prefix-map=$repo_root=." \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_WEBUI=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DGGML_BUILD_TESTS=OFF \
  -DGGML_BUILD_EXAMPLES=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_BLAS=OFF \
  -DGGML_ACCELERATE=OFF \
  -DGGML_METAL=OFF

jobs="${LLAMA_MACOS_LEGACY_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
cmake --build "$build_dir" --config Release --target llama-completion --parallel "$jobs"

helper="$build_dir/bin/llama-completion"
if [[ ! -x "$helper" ]]; then
  echo "llama-completion was not produced at $helper" >&2
  exit 1
fi

archs="$(lipo -archs "$helper")"
if [[ "$archs" != "x86_64" ]]; then
  echo "High Sierra helper must be x86_64-only, got: $archs" >&2
  exit 1
fi

# Validate that the final Mach-O still advertises a High Sierra-compatible
# deployment target. Depending on the linker this is LC_BUILD_VERSION or the
# older LC_VERSION_MIN_MACOSX load command.
load_commands="$(otool -l "$helper")"
if ! awk '
  /LC_BUILD_VERSION/ { in_build=1; next }
  /LC_VERSION_MIN_MACOSX/ { in_legacy=1; next }
  in_build && /minos/ { if ($2 == "10.13" || $2 ~ /^10\.13\./) ok=1; in_build=0 }
  in_legacy && /version/ { if ($2 == "10.13" || $2 ~ /^10\.13\./) ok=1; in_legacy=0 }
  END { exit ok ? 0 : 1 }
' <<<"$load_commands"; then
  echo "llama-completion does not advertise macOS 10.13 as its minimum target" >&2
  otool -l "$helper" | grep -A4 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' >&2 || true
  exit 1
fi

# Only Apple system libraries/frameworks are allowed. This avoids shipping a
# helper that accidentally depends on Homebrew or build-machine paths.
dependencies="$(otool -L "$helper" | awk '/^\t/{print}')"
if grep -Eq '/(opt/homebrew|usr/local|Users|private|Volumes)/' <<<"$dependencies"; then
  echo "llama-completion contains a non-portable dynamic dependency" >&2
  printf '%s\n' "$dependencies" >&2
  exit 1
fi

if strings "$helper" | grep -F "$repo_root/" >/dev/null; then
  echo "llama-completion contains build-machine source paths" >&2
  exit 1
fi

"$helper" --version

echo "LLAMA_MACOS_HIGH_SIERRA_HELPER=$helper"