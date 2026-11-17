$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$signer = Join-Path $root 'tool/windows_trusted_signing.ps1'
$tokens=$null; $errors=$null
[Management.Automation.Language.Parser]::ParseFile($signer,[ref]$tokens,[ref]$errors) | Out-Null
if ($errors.Count) { throw "Signer syntax errors: $errors" }
$workflow = Get-Content (Join-Path $root '.github/workflows/windows-release-publish.yml') -Raw
foreach ($text in @('-Mode Prepare','-Mode Bundle','-Mode Sign','-Mode VerifyMicrosoft','-Mode Verify','AivexusTrustedSignedBuild 1','/Saivexus_ci=','if: always()')) {
  if (-not $workflow.Contains($text)) { throw "Missing coordinated safety step: $text" }
}
if ($workflow.IndexOf('-Mode Bundle') -lt $workflow.IndexOf('Copy-Item $candidate.FullName')) { throw 'Bundle signed before final DLL copy' }
if ($workflow.IndexOf('-Mode Verify -FilePath $setupPath') -gt $workflow.IndexOf('$hash = Get-FileHash')) { throw 'Hash before installer trust' }
$lines=$workflow -split '\r?\n'
$count=0
for($i=0;$i -lt $lines.Count;$i++){
  if($lines[$i] -eq '        run: |'){
    $block=@();$i++
    while($i -lt $lines.Count -and ($lines[$i] -match '^          ' -or $lines[$i] -eq '')){
      $block += ($lines[$i] -replace '^          ','');$i++
    }
    $i--
    $code=($block -join [Environment]::NewLine) -replace '\$\{\{.*?\}\}','123'
    if($code -match 'set -euo pipefail'){continue}
    $parseErrors=$null
    [Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$parseErrors)|Out-Null
    if($parseErrors.Count){throw "Workflow script syntax errors: $parseErrors"}
    $count++
  }
}
# Synthetic signature responses only; no real certificate or executable.
$tempFile=New-TemporaryFile
try {
  function Get-AuthenticodeSignature {
    param($LiteralPath)
    [pscustomobject]@{Status=$global:aivexusSyntheticStatus;SignerCertificate=[pscustomobject]@{Subject=$global:aivexusSyntheticSubject;Thumbprint='TEST'}}
  }
  $global:aivexusSyntheticStatus='Valid'
  $global:aivexusSyntheticSubject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'
  & $signer -Mode VerifyMicrosoft -FilePath $tempFile.FullName
  foreach($case in @(
    @{Status='NotSigned';Subject='CN=Microsoft Corporation, O=Microsoft Corporation'},
    @{Status='HashMismatch';Subject='CN=Microsoft Corporation, O=Microsoft Corporation'},
    @{Status='Valid';Subject='CN=Example, O=Example'},
    @{Status='Valid';Subject='CN=Example, O=Microsoft Corporation Fake'}
  )){
    $global:aivexusSyntheticStatus=$case.Status;$global:aivexusSyntheticSubject=$case.Subject
    $rejected=$false
    try { & $signer -Mode VerifyMicrosoft -FilePath $tempFile.FullName } catch {$rejected=$true}
    if(-not $rejected){throw "Unsafe vendor accepted: $case"}
  }
} finally {
  Remove-Item -LiteralPath $tempFile.FullName -Force
  Remove-Variable aivexusSyntheticStatus,aivexusSyntheticSubject -Scope Global -ErrorAction SilentlyContinue
}
Write-Host "PASS: signer parser, $count workflow scripts, payload ordering, five vendor signature cases."
