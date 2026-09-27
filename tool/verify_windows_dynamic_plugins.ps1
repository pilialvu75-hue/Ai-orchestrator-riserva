param(
  [Parameter(Mandatory = $true)]
  [string]$ReleaseDir
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ReleaseDir)) {
  throw "Windows release directory not found: $ReleaseDir"
}

$exe = Join-Path $ReleaseDir 'ai_orchestrator.exe'
if (-not (Test-Path $exe)) {
  throw "Windows executable not found: $exe"
}

$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if (-not $dumpbin) {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vs) {
      $candidate = Get-ChildItem -Path (Join-Path $vs 'VC\Tools\MSVC') -Filter dumpbin.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\bin\\Hostx64\\x64\\dumpbin\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
      if ($candidate) {
        $dumpbin = $candidate.FullName
      }
    }
  }
}

if (-not $dumpbin) {
  throw 'dumpbin.exe not found; cannot enforce Windows dynamic-plugin linkage policy.'
}

$pluginSpecs = @(
  @{
    Dll = 'file_selector_windows_plugin.dll'
    Export = 'FileSelectorWindowsRegisterWithRegistrar'
  },
  @{
    Dll = 'flutter_secure_storage_windows_plugin.dll'
    Export = 'FlutterSecureStorageWindowsPluginRegisterWithRegistrar'
  },
  @{
    Dll = 'permission_handler_windows_plugin.dll'
    Export = 'PermissionHandlerWindowsPluginRegisterWithRegistrar'
  },
  @{
    Dll = 'record_windows_plugin.dll'
    Export = 'RecordWindowsPluginCApiRegisterWithRegistrar'
  }
)

$dependents = & $dumpbin /dependents $exe | Out-String
if ($LASTEXITCODE -ne 0) {
  throw "dumpbin /dependents failed for $exe"
}

foreach ($spec in $pluginSpecs) {
  $dll = [string]$spec.Dll
  if ($dependents -match [regex]::Escape($dll)) {
    throw "Dynamic-plugin policy violated: ai_orchestrator.exe statically imports $dll"
  }

  $pluginPath = Join-Path $ReleaseDir $dll
  if (-not (Test-Path $pluginPath)) {
    throw "Dynamic-plugin DLL missing from release bundle: $pluginPath"
  }

  $exports = & $dumpbin /exports $pluginPath | Out-String
  if ($LASTEXITCODE -ne 0) {
    throw "dumpbin /exports failed for $pluginPath"
  }

  $symbol = [string]$spec.Export
  if ($exports -notmatch [regex]::Escape($symbol)) {
    throw "Expected plugin registration export '$symbol' missing from $dll"
  }

  Write-Host "PASS dynamic plugin: $dll (not a static EXE import; export $symbol present)"
}

Write-Host 'Windows dynamic-plugin linkage policy verified.'
