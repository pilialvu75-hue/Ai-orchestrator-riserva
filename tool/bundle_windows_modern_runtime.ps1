param([Parameter(Mandatory = $true)][string]$ReleaseDir)
$ErrorActionPreference = 'Stop'
$modernWork = Join-Path $env:RUNNER_TEMP 'llama-b11753-modern'
New-Item -ItemType Directory -Path $modernWork -Force | Out-Null
$modernArchive = Join-Path $modernWork 'runtime.zip'
Invoke-WebRequest 'https://github.com/ggml-org/llama.cpp/releases/download/b11753/llama-b11753-bin-win-cpu-x64.zip' -OutFile $modernArchive
if ((Get-FileHash -LiteralPath $modernArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne '1a88a6a6b7dc18b3b0b064239cfc2d03a3b74e4f565a9b875dadc9cedbc73285') { throw 'Official runtime SHA256 mismatch' }
$modernExpanded = Join-Path $modernWork 'expanded'
Expand-Archive -LiteralPath $modernArchive -DestinationPath $modernExpanded -Force
$modernHelper = @(Get-ChildItem -LiteralPath $modernExpanded -Recurse -File -Filter 'llama-completion.exe')
if ($modernHelper.Count -ne 1) { throw 'Missing or ambiguous modern completion helper' }
$modernTarget = Join-Path $ReleaseDir 'runtime-modern'
New-Item -ItemType Directory -Path $modernTarget -Force | Out-Null
Get-ChildItem -LiteralPath $modernHelper[0].DirectoryName -File | Where-Object {
  $_.Name -in @('llama-completion.exe','llama-server.exe') -or $_.Name -like 'ggml*.dll' -or
  $_.Name -in @('llama.dll','llama-common.dll','llama-completion-impl.dll','llama-server-impl.dll','mtmd.dll','libomp.dll','LICENSE-LLVM-OpenMP')
} | Copy-Item -Destination $modernTarget -Force
foreach ($requiredModern in @('llama-completion.exe','llama-completion-impl.dll','llama-server.exe','llama-server-impl.dll','mtmd.dll','llama-common.dll','llama.dll','ggml.dll','ggml-base.dll','ggml-cpu-x64.dll','libomp.dll')) {
  if (!(Test-Path -LiteralPath (Join-Path $modernTarget $requiredModern))) { throw "Missing modern runtime dependency: $requiredModern" }
}
Write-Output 'Verified official b11753 CPU runtime bundled for Windows 10/11; legacy helper unchanged.'

$vulkanArchive = Join-Path $modernWork 'vulkan.zip'
Invoke-WebRequest 'https://github.com/ggml-org/llama.cpp/releases/download/b11753/llama-b11753-bin-win-vulkan-x64.zip' -OutFile $vulkanArchive
if ((Get-FileHash -LiteralPath $vulkanArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'd994930aa5739c77d14f34599e0b905ea86c04e53a6ba7ec94a317bbc5e0effd') { throw 'Official Vulkan runtime SHA256 mismatch' }
$vulkanExpanded = Join-Path $modernWork 'vulkan-expanded'
Expand-Archive -LiteralPath $vulkanArchive -DestinationPath $vulkanExpanded -Force
$vulkanServer = @(Get-ChildItem -LiteralPath $vulkanExpanded -Recurse -File -Filter 'llama-server.exe')
if ($vulkanServer.Count -ne 1) { throw 'Missing or ambiguous Vulkan server' }
$vulkanTarget = Join-Path $ReleaseDir 'runtime-vulkan'
New-Item -ItemType Directory -Path $vulkanTarget -Force | Out-Null
Get-ChildItem -LiteralPath $vulkanServer[0].DirectoryName -File | Where-Object {
  $_.Name -eq 'llama-server.exe' -or $_.Name -like 'ggml*.dll' -or
  $_.Name -in @('llama.dll','llama-common.dll','llama-server-impl.dll','mtmd.dll','libomp.dll','LICENSE-LLVM-OpenMP')
} | Copy-Item -Destination $vulkanTarget -Force
foreach ($required in @('llama-server.exe','llama-server-impl.dll','ggml-vulkan.dll','ggml.dll','ggml-base.dll','llama.dll','llama-common.dll','mtmd.dll','libomp.dll')) {
  if (!(Test-Path -LiteralPath (Join-Path $vulkanTarget $required))) { throw "Missing Vulkan dependency: $required" }
}
Write-Output 'Verified Vulkan server bundled separately; runtime selection retains CPU fallback.'
