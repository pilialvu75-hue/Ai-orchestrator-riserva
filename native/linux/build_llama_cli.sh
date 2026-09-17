#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_dir="$repo_root/third_party/llama.cpp"
build_dir="${LLAMA_LINUX_BUILD_DIR:-$repo_root/build/llama-linux}"

if [[ ! -f "$source_dir/CMakeLists.txt" ]]; then
  echo "llama.cpp submodule is missing at $source_dir" >&2
  exit 1
fi

cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  "-DCMAKE_C_FLAGS=-ffile-prefix-map=$repo_root=." \
  "-DCMAKE_CXX_FLAGS=-ffile-prefix-map=$repo_root=." \
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
  -DGGML_CUDA=OFF \
  -DGGML_VULKAN=OFF

jobs="${LLAMA_LINUX_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"
cmake --build "$build_dir" --config Release --target llama-completion --parallel "$jobs"

helper="$build_dir/bin/llama-completion"
if [[ ! -x "$helper" ]]; then
  echo "llama-completion was not produced at $helper" >&2
  exit 1
fi

if ldd "$helper" | grep -F 'not found' >/dev/null; then
  echo "llama-completion has unresolved dynamic dependencies" >&2
  ldd "$helper" >&2
  exit 1
fi

if strings "$helper" | grep -F "$repo_root/" >/dev/null; then
  echo "llama-completion contains build-machine source paths" >&2
  exit 1
fi

"$helper" --version

echo "LLAMA_LINUX_HELPER=$helper"
