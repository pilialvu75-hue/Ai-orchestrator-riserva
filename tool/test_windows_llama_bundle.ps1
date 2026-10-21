param([Parameter(Mandatory = $true)][string]$ReleaseDir)
$ErrorActionPreference = 'Stop'
$helper = Join-Path $ReleaseDir 'llama-completion.exe'
if (-not (Test-Path -LiteralPath $helper)) { throw 'Bundled llama-completion.exe is missing' }

# Check the actual linked executable, not just the configured Windows target.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$dumpbin = Get-ChildItem -Path (Join-Path $vs 'VC\Tools\MSVC') -Filter dumpbin.exe -Recurse |
  Where-Object FullName -match 'Hostx64\\x64\\dumpbin.exe$' | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $dumpbin) { throw 'dumpbin is required for the runtime import audit' }
$imports = & $dumpbin.FullName /imports $helper | Out-String
if ($LASTEXITCODE -ne 0) { throw 'Runtime import audit failed' }
$forbidden = @('WaitOnAddress', 'WakeByAddressSingle', 'WakeByAddressAll',
  'GetSystemTimePreciseAsFileTime', 'GetCurrentThreadStackLimits', 'CreateFile2',
  'GetTempPath2W', 'GetThreadDescription', 'SetThreadDescription',
  'api-ms-win-core-path-l1-1-0.dll', 'libomp', 'cudart', 'cublas', 'node.dll')
foreach ($symbol in $forbidden) {
  if ($imports -match [regex]::Escape($symbol)) { throw "Runtime imports unsupported dependency: $symbol" }
}
$imports | Set-Content -LiteralPath (Join-Path $ReleaseDir 'data\llama-imports.txt')

$temporary = Join-Path $env:RUNNER_TEMP 'windows-gguf-smoke'
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
$model = Join-Path $temporary 'stories15M-q8_0.gguf'
$revision = 'def3e2dd70df35ecbf6403ea347de4c5977220c1'
Invoke-WebRequest "https://huggingface.co/ggml-org/tiny-llamas/resolve/$revision/stories15M-q8_0.gguf?download=true" -OutFile $model
$header = [IO.File]::OpenRead($model)
try {
  $magic = New-Object byte[] 4
  if ($header.Read($magic, 0, 4) -ne 4 -or [Text.Encoding]::ASCII.GetString($magic) -ne 'GGUF') { throw 'Invalid smoke model' }
} finally { $header.Dispose() }

# Exercise the same Dart provider as the UI, with inherited overrides poisoned:
# the runtime must resolve next to the executable even when cwd is elsewhere.
$env:AI_ORCHESTRATOR_WINDOWS_SMOKE_HELPER = $helper
$env:AI_ORCHESTRATOR_WINDOWS_SMOKE_MODEL = $model
try {
  flutter test test/core/runtime/inference/windows_bundle_real_inference_test.dart --reporter expanded
  if ($LASTEXITCODE -ne 0) { throw 'Real bundled GGUF inference failed' }
  if ($env:AI_ORCHESTRATOR_WINDOWS_SMOKE_MODERN -eq '1') {
    flutter test test/core/runtime/inference/resident_completion_runtime_real_test.dart --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'Resident GGUF cache, session isolation or cancellation test failed' }
  }
} finally {
  Remove-Item Env:AI_ORCHESTRATOR_WINDOWS_SMOKE_HELPER -ErrorAction SilentlyContinue
  Remove-Item Env:AI_ORCHESTRATOR_WINDOWS_SMOKE_MODEL -ErrorAction SilentlyContinue
}
Write-Output 'WINDOWS_BUNDLED_GGUF_INFERENCE_OK'
