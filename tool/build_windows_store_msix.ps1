# Source-only Microsoft Store MSIX candidate for the existing Windows Flutter app.
# Store re-signs submitted packages after certification; not a trusted sideload installer.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $ReleaseDir,
  [Parameter(Mandatory)][string] $OutputDir,
  [Parameter(Mandatory)][string] $IdentityName,
  [Parameter(Mandatory)][string] $Publisher,
  [Parameter(Mandatory)][string] $PublisherDisplayName,
  [Parameter(Mandatory)][string] $Version
)
$ErrorActionPreference = 'Stop'
if ($IdentityName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,100}$') {
  throw 'MSIX identity must match a reserved Partner Center product name.'
}
if ($Publisher -notmatch '^CN=.+$' -or $Publisher.Length -gt 256) {
  throw 'MSIX Publisher must be the exact Partner Center subject, beginning with CN=.'
}
if ([string]::IsNullOrWhiteSpace($PublisherDisplayName)) {
  throw 'MSIX publisher display name is required.'
}
if ($Version -notmatch '^([0-9]+)\.([0-9]+)\.([0-9]+)\.0$') {
  throw 'Microsoft Store version must have four numeric segments and end in .0.'
}
$parts = @($Matches[1], $Matches[2], $Matches[3]) | ForEach-Object { [int]$_ }
if ($parts[0] -lt 1 -or @($parts | Where-Object { $_ -gt 65535 }).Count -ne 0) {
  throw 'MSIX version components must fit 16 bits; major must be positive.'
}
$release = (Resolve-Path -LiteralPath $ReleaseDir).Path
foreach ($relative in @(
  'ai_orchestrator.exe',
  'data',
  'runtime-cuda\llama-server.exe',
  'runtime-cuda\ggml-cuda.dll',
  'mcp-tools\aivexus_mcp.ps1'
)) {
  if (-not (Test-Path -LiteralPath (Join-Path $release $relative))) {
    throw "Incomplete Windows CUDA/ChatGPT beta payload: $relative"
  }
}
$iconPath = Join-Path $PWD 'windows\runner\resources\app_icon.ico'
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
  throw 'Existing AIVEXUS Windows icon not found.'
}
$sdkRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
$makeAppx = Get-ChildItem -LiteralPath $sdkRoot -Filter makeappx.exe -File -Recurse -ErrorAction Stop |
  Where-Object { $_.DirectoryName -match '\\x64$' } |
  Sort-Object FullName -Descending | Select-Object -First 1
if (-not $makeAppx) { throw 'Windows SDK x64 MakeAppx.exe was not found.' }

$stage = Join-Path $env:RUNNER_TEMP 'aivexus-msix-store-qa-stage'
$verify = Join-Path $env:RUNNER_TEMP 'aivexus-msix-store-qa-unpacked'
foreach ($dir in @($stage, $verify)) {
  if (Test-Path -LiteralPath $dir) {
    throw "Refusing to overwrite an existing staging directory: $dir"
  }
}
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item -Path (Join-Path $release '*') -Destination $stage -Recurse -Force
$assets = Join-Path $stage 'Assets'
New-Item -ItemType Directory -Path $assets | Out-Null

Add-Type -AssemblyName System.Drawing
$icon = [System.Drawing.Icon]::new($iconPath)
try {
  $original = $icon.ToBitmap()
  try {
    foreach ($asset in @(
      @{ Name = 'Square44x44Logo.png'; Size = 44 },
      @{ Name = 'Square150x150Logo.png'; Size = 150 },
      @{ Name = 'StoreLogo.png'; Size = 50 }
    )) {
      $size = [int]$asset.Size
      $bitmap = [System.Drawing.Bitmap]::new($size, $size)
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($original, 0, 0, $size, $size)
        $bitmap.Save((Join-Path $assets $asset.Name), [System.Drawing.Imaging.ImageFormat]::Png)
      } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
      }
    }
  } finally { $original.Dispose() }
} finally { $icon.Dispose() }

$escapedIdentity = [Security.SecurityElement]::Escape($IdentityName)
$escapedPublisher = [Security.SecurityElement]::Escape($Publisher)
$escapedPublisherDisplay = [Security.SecurityElement]::Escape($PublisherDisplayName)
$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
         IgnorableNamespaces="uap rescap">
  <Identity Name="$escapedIdentity" Publisher="$escapedPublisher"
            Version="$Version" ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>AI Orchestrator</DisplayName>
    <PublisherDisplayName>$escapedPublisherDisplay</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Resources><Resource Language="en-us" /></Resources>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0"
                        MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Applications>
    <Application Id="Aivexus" Executable="ai_orchestrator.exe"
                 EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="AI Orchestrator"
                          Description="AIVEXUS offline-first AI Orchestrator"
                          BackgroundColor="transparent"
                          Square150x150Logo="Assets\Square150x150Logo.png"
                          Square44x44Logo="Assets\Square44x44Logo.png" />
    </Application>
  </Applications>
  <Capabilities><rescap:Capability Name="runFullTrust" /></Capabilities>
</Package>
"@
$manifestPath = Join-Path $stage 'AppxManifest.xml'
[IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
$parsed = [xml](Get-Content -LiteralPath $manifestPath -Raw)
if ($parsed.Package.Identity.Version -ne $Version -or
    $parsed.Package.Identity.Name -ne $IdentityName) {
  throw 'Generated MSIX manifest identity was not preserved.'
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$output = Join-Path $OutputDir 'AIVEXUS-Windows-Store-Beta-x64.msix'
& $makeAppx.FullName pack /d $stage /p $output /o
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
  throw 'Windows SDK failed to package the unsigned Store MSIX candidate.'
}
& $makeAppx.FullName unpack /p $output /d $verify /o
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $verify 'AppxManifest.xml'))) {
  throw 'Unsigned Store MSIX failed unpack validation.'
}
foreach ($relative in @('ai_orchestrator.exe','runtime-cuda\llama-server.exe','mcp-tools\aivexus_mcp.ps1')) {
  if (-not (Test-Path -LiteralPath (Join-Path $verify $relative))) {
    throw "MSIX lost a required component during packaging: $relative"
  }
}
$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  AIVEXUS-Windows-Store-Beta-x64.msix" |
  Set-Content -LiteralPath "$output.sha256" -Encoding ASCII
Write-Host "Unsigned Microsoft Store QA MSIX structurally validated: $output"
Write-Host 'NO sideload or public release; requires Partner Center identity, certification and Store signing.'
