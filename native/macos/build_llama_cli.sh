#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_dir="$repo_root/third_party/llama.cpp"
build_dir="${LLAMA_MACOS_BUILD_DIR:-$repo_root/build/llama-macos}"

if [[ ! -f "$source_dir/CMakeLists.txt" ]]; then
  echo "llama.cpp submodule is missing at $source_dir" >&2
  exit 1
fi

cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_WEBUI=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DGGML_BUILD_TESTS=OFF \
  -DGGML_BUILD_EXAMPLES=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_METAL_MACOSX_VERSION_MIN=12.0

jobs="${LLAMA_MACOS_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
cmake --build "$build_dir" --config Release --target llama-cli --parallel "$jobs"

helper="$build_dir/bin/llama-cli"
if [[ ! -x "$helper" ]]; then
  echo "llama-cli was not produced at $helper" >&2
  exit 1
fi

archs="$(lipo -archs "$helper")"
if [[ "$archs" != *arm64* || "$archs" != *x86_64* ]]; then
  echo "llama-cli is not Universal 2: $archs" >&2
  exit 1
fi

if otool -L "$helper" | grep -Eq '/(opt/homebrew|usr/local|Users|private|Volumes)/'; then
  echo "llama-cli contains a non-portable dynamic dependency" >&2
  otool -L "$helper" >&2
  exit 1
fi

"$helper" --version

echo "LLAMA_MACOS_HELPER=$helper"
