param([Parameter(Mandatory = $true)][string]$ReleaseDir)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ReleaseDir -PathType Container)) {
  throw "Windows release directory not found: $ReleaseDir"
}
$target = Join-Path $ReleaseDir 'runtime-cuda'
if (Test-Path -LiteralPath $target) {
  throw "Refusing to overwrite an existing CUDA runtime bundle: $target"
}
$work = Join-Path $env:RUNNER_TEMP 'ai-orchestrator-cuda-b11753'
New-Item -ItemType Directory -Path $work -Force | Out-Null

$serverName = 'llama-b11753-bin-win-cuda-12.4-x64.zip'
$serverSha = 'bb9ae3cdc525208da141a09b055b1de1ca1586964e3031b774a8daeb0a5d4704'
$runtimeName = 'cudart-llama-bin-win-cuda-12.4-x64.zip'
$runtimeSha = '8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6'
$baseUrl = 'https://github.com/ggml-org/llama.cpp/releases/download/b11753'
$archives = @(
  @{ Name = $serverName; Sha = $serverSha; Url = "$baseUrl/$serverName" },
  @{ Name = $runtimeName; Sha = $runtimeSha; Url = "$baseUrl/$runtimeName" }
)
foreach ($asset in $archives) {
  $archive = Join-Path $work $asset.Name
  Invoke-WebRequest -Uri $asset.Url -OutFile $archive -MaximumRetryCount 3 -RetryIntervalSec 8
  $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $asset.Sha) {
    throw "Official CUDA asset SHA-256 mismatch for $($asset.Name)"
  }
  $expanded = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($asset.Name))
  Expand-Archive -LiteralPath $archive -DestinationPath $expanded
  $asset['Expanded'] = $expanded
}

$serverFiles = @(Get-ChildItem -LiteralPath $archives[0].Expanded -Recurse -File -Filter 'llama-server.exe')
if ($serverFiles.Count -ne 1) { throw 'Missing or ambiguous pinned CUDA llama-server.exe' }
$cudaDll = @(Get-ChildItem -LiteralPath $archives[0].Expanded -Recurse -File -Filter 'ggml-cuda.dll')
if ($cudaDll.Count -ne 1) { throw 'Missing or ambiguous ggml-cuda.dll in pinned CUDA package' }
New-Item -ItemType Directory -Path $target | Out-Null
Copy-Item -LiteralPath $serverFiles[0].FullName -Destination (Join-Path $target 'llama-server.exe')

function Copy-RuntimeDll([System.IO.FileInfo]$File) {
  $destination = Join-Path $target $File.Name
  if (Test-Path -LiteralPath $destination) {
    $existingHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    $incomingHash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    if ($existingHash -ne $incomingHash) {
      throw "Conflicting CUDA runtime dependency filename: $($File.Name)"
    }
    return
  }
  Copy-Item -LiteralPath $File.FullName -Destination $destination
}

$releaseDir = $serverFiles[0].DirectoryName
Get-ChildItem -LiteralPath $releaseDir -File -Filter '*.dll' |
  ForEach-Object { Copy-RuntimeDll $_ }
Get-ChildItem -LiteralPath $archives[1].Expanded -Recurse -File -Filter '*.dll' |
  ForEach-Object { Copy-RuntimeDll $_ }

$targetCuda = Join-Path $target 'ggml-cuda.dll'
if (-not (Test-Path -LiteralPath (Join-Path $target 'llama-server.exe')) -or
    -not (Test-Path -LiteralPath $targetCuda)) {
  throw 'The CUDA server or CUDA backend is missing from the prepared bundle.'
}
$licenseDir = Join-Path $target 'licenses'
New-Item -ItemType Directory -Path $licenseDir | Out-Null
Get-ChildItem -LiteralPath $archives[0].Expanded -Recurse -File |
  Where-Object { $_.Name -match '^(LICENSE|COPYING)([-_.].*)?$' } |
  ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $licenseDir ("llama-" + $_.Name)) -Force }
Get-ChildItem -LiteralPath $archives[1].Expanded -Recurse -File |
  Where-Object { $_.Name -match '^(LICENSE|COPYING)([-_.].*)?$' } |
  ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $licenseDir ("cuda-runtime-" + $_.Name)) -Force }

$manifest = [ordered]@{
  engineRelease = 'ggml-org/llama.cpp b11753'
  cudaRuntime = 'CUDA 12.4'
  serverAsset = $serverName
  serverAssetSha256 = $serverSha
  runtimeAsset = $runtimeName
  runtimeAssetSha256 = $runtimeSha
  hardwareSelection = 'NVIDIA CUDA only when listed free VRAM fits model file plus 2048 MiB headroom'
  fallbacks = @('bundled Vulkan', 'bundled CPU')
}
$manifest | ConvertTo-Json -Depth 3 |
  Set-Content -LiteralPath (Join-Path $target 'runtime-manifest.json') -Encoding UTF8
Write-Output "Pinned llama.cpp b11753 CUDA server and verified CUDA 12.4 dependencies bundled at $target"
