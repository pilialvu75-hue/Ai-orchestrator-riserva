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
  if ($Mode -in @('restore', 'accept')) { $arguments += @('--confirm', 'yes') }
  $arguments += @('--roaming', $script:roaming)
  & $exe @arguments
  $exit = $LASTEXITCODE
  if ($MustSucceed -and $exit -ne 0) { throw "$Mode failed: $exit" }
  if (-not $MustSucceed -and $exit -eq 0) { throw "$Mode should have been rejected" }
}
try {
  $app = Join-Path $working 'installed\AI Orchestrator'
  $data = Join-Path $working 'profile\database'
  $script:roaming = Join-Path $working 'roaming\com.aiorchestrator\AI Orchestrator'
  $store = Join-Path $working 'recovery'
  New-Item $app -ItemType Directory -Force | Out-Null
  New-Item $data -ItemType Directory -Force | Out-Null
  New-Item $script:roaming -ItemType Directory -Force | Out-Null
  Set-Content (Join-Path $script:roaming 'shared_preferences.json') '{"preferred_model":"original"}' -NoNewline
  Set-Content (Join-Path $app 'ai_orchestrator.exe') 'original-build-1.0.12.2' -NoNewline
  Set-Content (Join-Path $app 'flutter_windows.dll') 'original-dll' -NoNewline
  Set-Content (Join-Path $data 'ai_orchestrator.db') 'original-user-memory' -NoNewline

  Invoke-Recovery backup $app $data $store
  Invoke-Recovery verify $app $data $store
  Invoke-Recovery backup $app $data $store $false

  # An explicitly accepted, working version must let the next upgrade
  # create a new verified checkpoint without losing the archived snapshot.
  Invoke-Recovery accept $app $data $store
  if (Test-Path (Join-Path $store 'latest.txt')) {
    throw 'Accept left a pending recovery checkpoint.'
  }
  if (@(Get-ChildItem $store -Directory -Filter 'snapshot-*').Count -lt 1) {
    throw 'Accept erased the archived last-known-good backup.'
  }
  Invoke-Recovery backup $app $data $store

  Set-Content (Join-Path $app 'ai_orchestrator.exe') 'new-beta-1.0.15' -NoNewline
  Set-Content (Join-Path $app 'new-feature.dll') 'new-runtime' -NoNewline
  Set-Content (Join-Path $data 'ai_orchestrator.db') 'new-user-memory' -NoNewline
  Set-Content (Join-Path $script:roaming 'shared_preferences.json') '{"preferred_model":"new"}' -NoNewline
  Invoke-Recovery restore $app $data $store
  if ((Get-Content (Join-Path $app 'ai_orchestrator.exe') -Raw) -ne 'original-build-1.0.12.2') {
    throw 'Rollback did not recover original app executable.'
  }
  if ((Get-Content (Join-Path $data 'ai_orchestrator.db') -Raw) -ne 'original-user-memory') {
    throw 'Rollback did not recover original database.'
  }
  if ((Get-Content (Join-Path $script:roaming 'shared_preferences.json') -Raw) -ne '{"preferred_model":"original"}') {
    throw 'Rollback did not recover Windows Roaming Flutter preferences.'
  }
  if (Test-Path (Join-Path $app 'new-feature.dll')) {
    throw 'Rollback left an incompatible newer native DLL in the program directory.'
  }
  if (Test-Path (Join-Path $store 'latest.txt')) {
    throw 'Restore should clear the pending checkpoint.'
  }

  # Interrupted upgrade: the target EXE disappeared before replacement.
  # The out-of-app recovery helper must still be able to restore it.
  Invoke-Recovery backup $app $data $store
  Remove-Item (Join-Path $app 'ai_orchestrator.exe') -Force
  Invoke-Recovery restore $app $data $store
  if ((Get-Content (Join-Path $app 'ai_orchestrator.exe') -Raw) -ne 'original-build-1.0.12.2') {
    throw 'Recovery could not restore after interrupted upgrade.'
  }

  # Previously absent user data MUST remove data created by the bad upgrade.
  Remove-Item $data -Recurse -Force
  Invoke-Recovery backup $app $data $store
  New-Item $data -ItemType Directory -Force | Out-Null
  Set-Content (Join-Path $data 'newer.db') 'incompatible' -NoNewline
  Invoke-Recovery restore $app $data $store
  if (Test-Path $data) { throw 'Restore left newer data when old data directory did not exist.' }

  # Previously empty user data MUST come back empty.
  New-Item $data -ItemType Directory -Force | Out-Null
  Invoke-Recovery backup $app $data $store
  Set-Content (Join-Path $data 'newer.db') 'incompatible' -NoNewline
  Invoke-Recovery restore $app $data $store
  if (-not (Test-Path $data) -or @(Get-ChildItem $data -Recurse).Count -ne 0) {
    throw 'Restore did not preserve originally empty database directory.'
  }

  # The old app had no Roaming folder: do not keep incompatible new prefs.
  Remove-Item $script:roaming -Recurse -Force
  Invoke-Recovery backup $app $data $store
  New-Item $script:roaming -ItemType Directory -Force | Out-Null
  Set-Content (Join-Path $script:roaming 'shared_preferences.json') '{"bad":"new"}' -NoNewline
  Invoke-Recovery restore $app $data $store
  if (Test-Path $script:roaming) {
    throw 'Rollback did not remove newer Roaming directory absent in original snapshot.'
  }

  # The old app had an empty Roaming folder: restore emptiness.
  New-Item $script:roaming -ItemType Directory -Force | Out-Null
  Invoke-Recovery backup $app $data $store
  Set-Content (Join-Path $script:roaming 'shared_preferences.json') '{"bad":"new"}' -NoNewline
  Invoke-Recovery restore $app $data $store
  if (-not (Test-Path $script:roaming) -or @(Get-ChildItem $script:roaming -Recurse).Count -ne 0) {
    throw 'Rollback did not restore empty Roaming directory.'
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
