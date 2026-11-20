param([Parameter(Mandatory = $true)][string]$ReleaseDir)
$ErrorActionPreference = 'Stop'
$target = Join-Path $ReleaseDir 'runtime-cuda'
$server = Join-Path $target 'llama-server.exe'
if (-not (Test-Path -LiteralPath $server)) { throw 'CUDA llama-server.exe is missing' }
if (-not (Test-Path -LiteralPath (Join-Path $target 'ggml-cuda.dll'))) { throw 'CUDA backend DLL is missing' }
if (-not (Test-Path -LiteralPath (Join-Path $target 'runtime-manifest.json'))) { throw 'Pinned runtime manifest is missing' }

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$dumpbin = Get-ChildItem -Path (Join-Path $vs 'VC/Tools/MSVC') -Filter dumpbin.exe -Recurse |
  Where-Object FullName -match 'Hostx64\\x64\\dumpbin.exe$' |
  Sort-Object FullName -Descending | Select-Object -First 1
if (-not $dumpbin) { throw 'dumpbin is required for the CUDA import audit' }

$pending = [System.Collections.Generic.Queue[System.IO.FileInfo]]::new()
$pending.Enqueue((Get-Item -LiteralPath $server))
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
while ($pending.Count -gt 0) {
  $binary = $pending.Dequeue()
  if (-not $seen.Add($binary.FullName)) { continue }
  $imports = & $dumpbin.FullName /dependents $binary.FullName | Out-String
  if ($LASTEXITCODE -ne 0) { throw "CUDA import audit failed for $($binary.Name)" }
  $dependencies = [regex]::Matches($imports, '(?m)^\s+([A-Za-z0-9_.+-]+\.dll)\s*$')
  foreach ($match in $dependencies) {
    $name = $match.Groups[1].Value
    $local = Join-Path $target $name
    if (Test-Path -LiteralPath $local) {
      $pending.Enqueue((Get-Item -LiteralPath $local))
      continue
    }
    $system = Join-Path (Join-Path $env:WINDIR 'System32') $name
    if (Test-Path -LiteralPath $system) { continue }
    if ($name -match '^(api-ms-win-|ext-ms-win-)' -or $name -ieq 'nvcuda.dll') { continue }
    throw "Unresolved CUDA dependency: $name imported by $($binary.Name)"
  }
}
Write-Output ("CUDA dependency closure passed for {0} bundled binaries. nvcuda.dll is supplied by the installed NVIDIA driver." -f $seen.Count)
