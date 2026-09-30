param(
  [string]$BuildDir = ""
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sourceDir = Join-Path $repoRoot 'third_party\llama.cpp'
if (-not $BuildDir) {
  $BuildDir = Join-Path $repoRoot 'build\llama-windows'
}

if (-not (Test-Path (Join-Path $sourceDir 'CMakeLists.txt'))) {
  throw "llama.cpp submodule is missing at $sourceDir"
}

cmake -S $sourceDir -B $BuildDir `
  -A x64 `
  -DBUILD_SHARED_LIBS=OFF `
  -DLLAMA_BUILD_TESTS=OFF `
  -DLLAMA_BUILD_EXAMPLES=OFF `
  -DLLAMA_BUILD_TOOLS=ON `
  -DLLAMA_BUILD_SERVER=OFF `
  -DLLAMA_BUILD_WEBUI=OFF `
  -DLLAMA_OPENSSL=OFF `
  -DGGML_BUILD_TESTS=OFF `
  -DGGML_BUILD_EXAMPLES=OFF `
  -DGGML_NATIVE=OFF `
  -DGGML_OPENMP=OFF `
  -DGGML_BLAS=OFF `
  -DGGML_CUDA=OFF `
  -DGGML_VULKAN=OFF `
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded `
  '-DCMAKE_C_FLAGS=/D_WIN32_WINNT=0x0601 /DWINVER=0x0601' `
  '-DCMAKE_CXX_FLAGS=/D_WIN32_WINNT=0x0601 /DWINVER=0x0601'

if ($LASTEXITCODE -ne 0) {
  throw "llama.cpp CMake configure failed with exit code $LASTEXITCODE"
}

cmake --build $BuildDir --config Release --target llama-completion --parallel 2
if ($LASTEXITCODE -ne 0) {
  throw "llama-completion build failed with exit code $LASTEXITCODE"
}

$candidates = @(
  (Join-Path $BuildDir 'bin\Release\llama-completion.exe'),
  (Join-Path $BuildDir 'bin\llama-completion.exe'),
  (Join-Path $BuildDir 'Release\llama-completion.exe')
)
$helper = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $helper) {
  throw "llama-completion.exe was not produced in the expected build directories."
}

& $helper --version
if ($LASTEXITCODE -ne 0) {
  throw "llama-completion.exe --version failed with exit code $LASTEXITCODE"
}

Write-Host "LLAMA_WINDOWS_HELPER=$helper"
