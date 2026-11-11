param(
  [Parameter(Mandatory = $true)][string]$ReleaseDir
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ReleaseDir -PathType Container)) {
  throw "Windows release directory not found: $ReleaseDir"
}
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$llamaSource = Join-Path $repositoryRoot 'third_party\llama.cpp\CMakeLists.txt'
if (-not (Test-Path -LiteralPath $llamaSource)) {
  throw 'Pinned llama.cpp submodule is missing; initialize the repository submodules first.'
}

$sdkVersion = '1.4.350.0'
$sdkRoot = Join-Path $env:ProgramFiles "VulkanSDK\$sdkVersion"
$glslc = Join-Path $sdkRoot 'Bin\glslc.exe'
if (-not (Test-Path -LiteralPath $glslc)) {
  $installer = Join-Path $env:RUNNER_TEMP "vulkansdk-windows-X64-$sdkVersion.exe"
  $uri = "https://sdk.lunarg.com/sdk/download/$sdkVersion/windows/vulkansdk-windows-X64-$sdkVersion.exe"
  Invoke-WebRequest -Uri $uri -OutFile $installer
  $expectedSha256 = '855b27ba05d2d8119c5114c5d4ff870ca38f2c632b11e1bb9923b9b7e6ecfe7b'
  $actualSha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualSha256 -ne $expectedSha256) {
    throw "Vulkan SDK installer SHA-256 mismatch: $actualSha256"
  }
  $sdkInstall = Start-Process -FilePath $installer -ArgumentList @(
    'install', '--accept-licenses', '--default-answer', '--confirm-command',
    '--accept-messages', "--root=$sdkRoot"
  ) -Wait -PassThru
  if ($sdkInstall.ExitCode -ne 0) {
    throw "Vulkan SDK install failed with exit code $($sdkInstall.ExitCode)."
  }
}
if (-not (Test-Path -LiteralPath $glslc)) {
  throw "Pinned Vulkan SDK is missing glslc: $glslc"
}
$env:VULKAN_SDK = $sdkRoot
$env:Path = "$sdkRoot\Bin;$env:Path"

$cmakeSource = Join-Path $repositoryRoot 'native\windows\static_runtime'
$cpuOutput = Join-Path $ReleaseDir 'runtime-cpu-avx2'
$cpuBuild = Join-Path $env:RUNNER_TEMP 'ai-orchestrator-llama-cpu-avx2'
New-Item -ItemType Directory -Path $cpuOutput -Force | Out-Null
& cmake -S $cmakeSource -B $cpuBuild -A x64 `
  '-DAI_ORCHESTRATOR_RUNTIME_VARIANT=cpu-avx2' `
  "-DCMAKE_INSTALL_PREFIX=$cpuOutput"
if ($LASTEXITCODE -ne 0) { throw "AVX2 runtime configure failed: $LASTEXITCODE" }
& cmake --build $cpuBuild --config Release --target llama-completion --parallel
if ($LASTEXITCODE -ne 0) { throw "AVX2 runtime build failed: $LASTEXITCODE" }
& cmake --install $cpuBuild --config Release
if ($LASTEXITCODE -ne 0) { throw "AVX2 runtime install failed: $LASTEXITCODE" }

$vulkanOutput = Join-Path $ReleaseDir 'runtime-vulkan'
$vulkanBuild = Join-Path $env:RUNNER_TEMP 'ai-orchestrator-llama-vulkan-static'
New-Item -ItemType Directory -Path $vulkanOutput -Force | Out-Null
& cmake -S $cmakeSource -B $vulkanBuild -A x64 `
  '-DAI_ORCHESTRATOR_RUNTIME_VARIANT=vulkan-server' `
  "-DCMAKE_INSTALL_PREFIX=$vulkanOutput"
if ($LASTEXITCODE -ne 0) { throw "Static Vulkan runtime configure failed: $LASTEXITCODE" }
& cmake --build $vulkanBuild --config Release --target llama-server --parallel
if ($LASTEXITCODE -ne 0) { throw "Static Vulkan server build failed: $LASTEXITCODE" }
& cmake --install $vulkanBuild --config Release
if ($LASTEXITCODE -ne 0) { throw "Static Vulkan runtime install failed: $LASTEXITCODE" }

foreach ($required in @(
  (Join-Path $cpuOutput 'llama-completion.exe'),
  (Join-Path $vulkanOutput 'llama-server.exe'),
  (Join-Path $sdkRoot 'Lib\vulkan-1.lib')
)) {
  if (-not (Test-Path -LiteralPath $required)) {
    throw "Expected static runtime output is missing: $required"
  }
}
Write-Output "WINDOWS_STATIC_RUNTIMES_READY sdk=$sdkVersion cpu=AVX2 vulkan=static-loader-import"
