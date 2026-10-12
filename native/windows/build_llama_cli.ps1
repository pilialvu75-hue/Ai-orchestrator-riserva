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

# cpp-httplib 0.44 has a compile-time Windows 10 floor even when building
# llama-completion only. The helper does not use the HTTP server path, so keep
# the pinned submodule and remove only that preprocessor guard in the CI worktree.
# The final executable is then checked for known post-Windows-7 imports below.
$httplibHeader = Join-Path $sourceDir 'vendor\cpp-httplib\httplib.h'
$httplib = Get-Content -Raw -Path $httplibHeader
$guard = @'
#ifdef _WIN32
#if defined(_WIN32_WINNT) && _WIN32_WINNT < 0x0A00
#error                                                                         \
    "cpp-httplib doesn't support Windows 8 or lower. Please use Windows 10 or later."
#endif
#endif
'@
if (-not $httplib.Contains($guard)) {
  throw 'Expected cpp-httplib Windows-version guard was not found; refusing an unverified patch.'
}
$httplib = $httplib.Replace($guard, '')
Set-Content -Path $httplibHeader -Value $httplib -Encoding UTF8
Write-Host 'Removed cpp-httplib compile-only Windows 10 guard for the bundled completion helper.'

# cpp-httplib's mmap helper also uses Windows 8/10-only App APIs. Replace only
# those three file-mapping calls with equivalent Win7 APIs in the CI worktree.
$httplibSource = Join-Path $sourceDir 'vendor\cpp-httplib\httplib.cpp'
$httplibCpp = Get-Content -Raw -Path $httplibSource
$oldFileOpen = @'
  hFile_ =
      ::CreateFile2(wpath.c_str(), GENERIC_READ,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, OPEN_EXISTING, NULL);
'@
$newFileOpen = @'
  hFile_ = ::CreateFileW(
      wpath.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
'@
$oldMapping = @'
  hMapping_ =
      ::CreateFileMappingFromApp(hFile_, NULL, PAGE_READONLY, size_, NULL);
'@
$newMapping = @'
  hMapping_ = ::CreateFileMappingW(hFile_, NULL, PAGE_READONLY, 0, 0, NULL);
'@
$oldView = @'
  addr_ = ::MapViewOfFileFromApp(hMapping_, FILE_MAP_READ, 0, 0);
'@
$newView = @'
  addr_ = ::MapViewOfFile(hMapping_, FILE_MAP_READ, 0, 0, 0);
'@

foreach ($replacement in @(
  @($oldFileOpen, $newFileOpen),
  @($oldMapping, $newMapping),
  @($oldView, $newView)
)) {
  if (-not $httplibCpp.Contains($replacement[0])) {
    throw 'Expected cpp-httplib Windows file-mapping block was not found; refusing an unverified patch.'
  }
  $httplibCpp = $httplibCpp.Replace($replacement[0], $replacement[1])
}
Set-Content -Path $httplibSource -Value $httplibCpp -Encoding UTF8
Write-Host 'Replaced cpp-httplib App-only file mapping calls with Win7-compatible APIs.'

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
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL `
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

# Reject known loader-time imports introduced after Windows 7. This keeps the
# shared Windows bundle honest even though the helper is being exercised first
# on Windows 8.1.
$helperBytes = [IO.File]::ReadAllBytes($helper)
$forbiddenImports = @(
  'WaitOnAddress',
  'WakeByAddressSingle',
  'WakeByAddressAll',
  'GetCurrentThreadStackLimits',
  'GetSystemTimePreciseAsFileTime',
  'GetProcessMitigationPolicy',
  'CreateFile2',
  'PathCchCanonicalize',
  'PathCchCombine',
  'PathCchRemoveBackslash',
  'RtlAddGrowableFunctionTable',
  'RtlDeleteGrowableFunctionTable'
)
foreach ($symbol in $forbiddenImports) {
  $needle = [Text.Encoding]::ASCII.GetBytes($symbol)
  $found = $false
  for ($i = 0; $i -le $helperBytes.Length - $needle.Length -and -not $found; $i++) {
    $match = $true
    for ($j = 0; $j -lt $needle.Length; $j++) {
      if ($helperBytes[$i + $j] -ne $needle[$j]) {
        $match = $false
        break
      }
    }
    if ($match) { $found = $true }
  }
  if ($found) {
    throw "Bundled llama helper contains unsupported Windows import/symbol '$symbol'."
  }
}
Write-Host 'Bundled llama helper legacy-Windows forbidden-symbol validation passed.'

& $helper --version
if ($LASTEXITCODE -ne 0) {
  throw "llama-completion.exe --version failed with exit code $LASTEXITCODE"
}

Write-Host "LLAMA_WINDOWS_HELPER=$helper"
