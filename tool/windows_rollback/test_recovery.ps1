$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'AivexusRecovery.cs'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
  throw 'Windows .NET Framework 4 C# compiler unavailable on CI runner.'
}
$working = Join-Path $env:RUNNER_TEMP ('aivexus-recovery-ci-' + [guid]::NewGuid().ToString('N'))
New-Item $working -ItemType Directory -Force | Out-Null
$exe = Join-Path $working 'AivexusRecovery.exe'
& $csc /nologo /target:exe /r:System.Windows.Forms.dll "/out:$exe" "$source"
if ($LASTEXITCODE -ne 0) { throw 'Windows 8.1 compatible recovery helper did not compile.' }

function Invoke-Recovery {
  param([string] $Mode, [string] $App, [string] $Data, [string] $Store, [bool] $MustSucceed = $true)
  $arguments = @('--mode', $Mode, '--app', $App, '--data', $Data, '--store', $Store)
  if ($Mode -eq 'restore') { $arguments += @('--confirm', 'yes') }
  & $exe @arguments
  $exit = $LASTEXITCODE
  if ($MustSucceed -and $exit -ne 0) { throw "$Mode failed: $exit" }
  if (-not $MustSucceed -and $exit -eq 0) { throw "$Mode should have been rejected" }
}
try {
  $app = Join-Path $working 'installed\AI Orchestrator'
  $data = Join-Path $working 'profile\database'
  $store = Join-Path $working 'recovery'
  New-Item $app -ItemType Directory -Force | Out-Null
  New-Item $data -ItemType Directory -Force | Out-Null
  Set-Content (Join-Path $app 'ai_orchestrator.exe') 'original-build-1.0.12.2' -NoNewline
  Set-Content (Join-Path $app 'flutter_windows.dll') 'original-dll' -NoNewline
  Set-Content (Join-Path $data 'ai_orchestrator.db') 'original-user-memory' -NoNewline

  Invoke-Recovery backup $app $data $store
  Invoke-Recovery verify $app $data $store
  Invoke-Recovery backup $app $data $store $false

  Set-Content (Join-Path $app 'ai_orchestrator.exe') 'new-beta-1.0.15' -NoNewline
  Set-Content (Join-Path $app 'new-feature.dll') 'new-runtime' -NoNewline
  Set-Content (Join-Path $data 'ai_orchestrator.db') 'new-user-memory' -NoNewline
  Invoke-Recovery restore $app $data $store
  if ((Get-Content (Join-Path $app 'ai_orchestrator.exe') -Raw) -ne 'original-build-1.0.12.2') {
    throw 'Rollback did not recover original app executable.'
  }
  if ((Get-Content (Join-Path $data 'ai_orchestrator.db') -Raw) -ne 'original-user-memory') {
    throw 'Rollback did not recover original database.'
  }
  if (Test-Path (Join-Path $app 'new-feature.dll')) {
    throw 'Rollback left an incompatible newer native DLL in the program directory.'
  }
  if (Test-Path (Join-Path $store 'latest.txt')) {
    throw 'Restore should clear the pending checkpoint.'
  }

  Invoke-Recovery backup $app $data $store
  $snapshotId = Get-Content (Join-Path $store 'latest.txt') -Raw
  $snapshotPath = Join-Path $store ($snapshotId.Trim())
  Set-Content (Join-Path $snapshotPath 'app\ai_orchestrator.exe') 'tampered' -NoNewline
  Invoke-Recovery verify $app $data $store $false
  Invoke-Recovery restore $app $data $store $false
  if ((Get-Content (Join-Path $app 'ai_orchestrator.exe') -Raw) -ne 'original-build-1.0.12.2') {
    throw 'Rejected corrupt restore changed the installed app.'
  }
  Write-Host 'PASS: backup, verify, refusal to overwrite unapproved backup, clean restore, rollback of data, corrupt snapshot rejection.'
  exit 0
} finally {
  Remove-Item -LiteralPath $working -Recurse -Force -ErrorAction SilentlyContinue
}
