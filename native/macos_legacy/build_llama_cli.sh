#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
submodule_dir="$repo_root/third_party/llama.cpp"
legacy_source_dir="${LLAMA_MACOS_LEGACY_SOURCE_DIR:-$repo_root/build/llama-macos-high-sierra-source}"
build_dir="${LLAMA_MACOS_LEGACY_BUILD_DIR:-$repo_root/build/llama-macos-high-sierra}"

# Last known-good lineage before ggml introduced dynamic backend loading based
# on std::filesystem (which has a macOS 10.15 deployment requirement in libc++).
# Keep this pin independent from the modern macOS/Android llama.cpp submodule.
legacy_revision="${LLAMA_MACOS_LEGACY_REVISION:-f6d12e7df8fe64384f1939976871252e6422a01e}"

if [[ ! -f "$submodule_dir/CMakeLists.txt" ]]; then
  echo "llama.cpp submodule is missing at $submodule_dir" >&2
  exit 1
fi

# Never move the checked-in submodule away from the revision used by modern
# platforms. Materialize the legacy revision as an isolated git worktree.
git -C "$submodule_dir" fetch --depth=1 origin "$legacy_revision"
if [[ -e "$legacy_source_dir" ]]; then
  rm -rf "$legacy_source_dir"
  git -C "$submodule_dir" worktree prune
fi
git -C "$submodule_dir" worktree add --detach "$legacy_source_dir" "$legacy_revision"

rm -rf "$build_dir"

# High Sierra legacy target: x86_64 only, CPU only, and baseline x86-64 ISA.
# The reference MacBook7,1 uses a Core 2 Duo and a non-Metal GeForce 320M, so
# AVX/FMA/F16C/AMX and build-host-native tuning must never enter this binary.
cmake -S "$legacy_source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.13 \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  "-DCMAKE_C_FLAGS=-ffile-prefix-map=$repo_root=." \
  "-DCMAKE_CXX_FLAGS=-ffile-prefix-map=$repo_root=." \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_COMMON=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=ON \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_CURL=OFF \
  -DGGML_CCACHE=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_LLAMAFILE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_BLAS=OFF \
  -DGGML_ACCELERATE=OFF \
  -DGGML_METAL=OFF \
  -DGGML_AMX=OFF \
  -DGGML_AVX=OFF \
  -DGGML_AVX2=OFF \
  -DGGML_AVX512=OFF \
  -DGGML_AVX512_VBMI=OFF \
  -DGGML_AVX512_VNNI=OFF \
  -DGGML_AVX512_BF16=OFF \
  -DGGML_FMA=OFF \
  -DGGML_F16C=OFF \
  -DGGML_AMX_TILE=OFF \
  -DGGML_AMX_INT8=OFF \
  -DGGML_AMX_BF16=OFF

compile_commands="$build_dir/compile_commands.json"
if [[ ! -f "$compile_commands" ]]; then
  echo "CMake did not emit compile_commands.json" >&2
  exit 1
fi

# A hosted Intel runner is much newer than the physical Core 2 Duo. Fail the
# build rather than accidentally shipping a helper that executes unsupported
# instructions on the 2010 MacBook.
if grep -Eq -- '-march=native|-m(avx[^ "\\]*|fma|f16c|bmi2?|sse4\.2)' "$compile_commands"; then
  echo "Legacy compile commands contain CPU instructions newer than Core 2" >&2
  grep -E -- '-march=native|-m(avx[^ "\\]*|fma|f16c|bmi2?|sse4\.2)' "$compile_commands" >&2 || true
  exit 1
fi

jobs="${LLAMA_MACOS_LEGACY_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
cmake --build "$build_dir" --config Release --target llama-cli --parallel "$jobs"

helper="$build_dir/bin/llama-cli"
if [[ ! -x "$helper" ]]; then
  echo "llama-cli was not produced at $helper" >&2
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
  echo "llama-cli does not advertise macOS 10.13 as its minimum target" >&2
  otool -l "$helper" | grep -A4 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' >&2 || true
  exit 1
fi

# Only Apple system libraries/frameworks are allowed. This avoids shipping a
# helper that accidentally depends on Homebrew or build-machine paths.
dependencies="$(otool -L "$helper" | awk '/^\t/{print}')"
if grep -Eq '/(opt/homebrew|usr/local|Users|private|Volumes)/' <<<"$dependencies"; then
  echo "llama-cli contains a non-portable dynamic dependency" >&2
  printf '%s\n' "$dependencies" >&2
  exit 1
fi

if strings "$helper" | grep -F "$repo_root/" >/dev/null; then
  echo "llama-cli contains build-machine source paths" >&2
  exit 1
fi

printf 'LLAMA_MACOS_HIGH_SIERRA_REVISION=%s\n' "$legacy_revision"
printf 'LLAMA_MACOS_HIGH_SIERRA_HELPER=%s\n' "$helper"
