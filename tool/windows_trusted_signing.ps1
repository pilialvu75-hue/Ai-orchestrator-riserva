# Trusted Windows release signing for AIVEXUS.
# A CI runner must have an Authenticode certificate issued by a trusted CA.
# Never commit private keys or passwords. Run on an ephemeral Windows runner.
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('Prepare', 'Sign', 'Bundle', 'Verify')]
  [string] $Mode,
  [string] $FilePath,
  [string] $ReleaseDir
)

$ErrorActionPreference = 'Stop'

function Assert-SecretEnvironment {
  if ([string]::IsNullOrWhiteSpace($env:AIVEXUS_WINDOWS_SIGNING_PFX_B64) -or
      [string]::IsNullOrWhiteSpace($env:AIVEXUS_WINDOWS_SIGNING_PFX_PASSWORD)) {
    throw 'Trusted signing identity not configured: refusing to publish an unsigned Windows beta.'
  }
}

function Assert-PreparedSigning {
  if ([string]::IsNullOrWhiteSpace($env:AIVEXUS_WINDOWS_SIGNING_PFX_PATH) -or
      -not (Test-Path -LiteralPath $env:AIVEXUS_WINDOWS_SIGNING_PFX_PATH) -or
      [string]::IsNullOrWhiteSpace($env:AIVEXUS_WINDOWS_SIGNING_THUMBPRINT)) {
    throw 'Signing prerequisite is missing. Refusing unsigned output.'
  }
  Assert-SecretEnvironment
}

function Get-SigningTool {
  $cmd = Get-Command 'signtool.exe' -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $kits = "C:\Program Files (x86)\Windows Kits\10\bin"
  if (-not (Test-Path -LiteralPath $kits)) {
    throw 'Windows SDK signtool.exe is not installed.'
  }
  $candidate = Get-ChildItem -LiteralPath $kits -Filter signtool.exe -File -Recurse |
    Where-Object { $_.DirectoryName -match '\\x64$' } |
    Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $candidate) { throw 'Windows SDK x64 signtool.exe was not found.' }
  return $candidate.FullName
}

function Assert-ValidSignature([string] $Path, [bool] $RequireOurSigner) {
  $sig = Get-AuthenticodeSignature -LiteralPath $Path
  if ($sig.Status -ne 'Valid') {
    throw "Untrusted or missing Authenticode signature: $([IO.Path]::GetFileName($Path)); status=$($sig.Status)"
  }
  if ($RequireOurSigner -and
      $sig.SignerCertificate.Thumbprint -ne $env:AIVEXUS_WINDOWS_SIGNING_THUMBPRINT) {
    throw "Unexpected signing identity for $([IO.Path]::GetFileName($Path))."
  }
}

switch ($Mode) {
  'Prepare' {
    Assert-SecretEnvironment
    $pfxPath = Join-Path $env:RUNNER_TEMP 'aivexus-windows-signing.pfx'
    try {
      [IO.File]::WriteAllBytes($pfxPath, [Convert]::FromBase64String($env:AIVEXUS_WINDOWS_SIGNING_PFX_B64))
      $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $pfxPath, $env:AIVEXUS_WINDOWS_SIGNING_PFX_PASSWORD,
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
      )
      if (-not $cert.HasPrivateKey) { throw 'Code-signing certificate has no private key.' }
      $eku = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' }
      if (-not $eku -or
          -not (($eku.EnhancedKeyUsages | ForEach-Object { $_.Value }) -contains '1.3.6.1.5.5.7.3.3')) {
        throw 'Certificate is missing the Code Signing EKU.'
      }
      $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
      $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
      if (-not $chain.Build($cert)) {
        throw 'Signing certificate chain is not trusted on the clean CI runner.'
      }
      $null = Get-SigningTool
      "AIVEXUS_WINDOWS_SIGNING_PFX_PATH=$pfxPath" | Out-File -FilePath $env:GITHUB_ENV -Append
      "AIVEXUS_WINDOWS_SIGNING_THUMBPRINT=$($cert.Thumbprint)" | Out-File -FilePath $env:GITHUB_ENV -Append
      Write-Host 'Trusted code signing certificate validated; no private key data logged.'
    } catch {
      Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue
      throw
    }
  }
  'Sign' {
    Assert-PreparedSigning
    if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
      throw 'Signing target is missing.'
    }
    $signTool = Get-SigningTool
    & $signTool sign /fd SHA256 /f $env:AIVEXUS_WINDOWS_SIGNING_PFX_PATH /p $env:AIVEXUS_WINDOWS_SIGNING_PFX_PASSWORD /tr 'http://timestamp.digicert.com' /td SHA256 $FilePath
    if ($LASTEXITCODE -ne 0) { throw 'Windows Authenticode signer failed.' }
    Assert-ValidSignature $FilePath $true
  }
  'Bundle' {
    Assert-PreparedSigning
    if (-not $ReleaseDir -or -not (Test-Path -LiteralPath $ReleaseDir -PathType Container)) {
      throw 'Windows bundle was not found.'
    }
    $files = @(Get-ChildItem -LiteralPath $ReleaseDir -File -Recurse |
      Where-Object { $_.Extension -in '.exe', '.dll' })
    if ($files.Count -lt 1) { throw 'Release bundle contains no executables.' }
    foreach ($file in $files) {
      $sig = Get-AuthenticodeSignature -LiteralPath $file.FullName
      if ($sig.Status -ne 'Valid') {
        & $PSCommandPath -Mode Sign -FilePath $file.FullName
        if ($LASTEXITCODE -ne 0) { throw "Could not sign $($file.Name)" }
      }
      Assert-ValidSignature $file.FullName $false
    }
    Write-Host "Verified Authenticode on $($files.Count) bundled PE files."
  }
  'Verify' {
    Assert-PreparedSigning
    if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
      throw 'Signed installer not found.'
    }
    Assert-ValidSignature $FilePath $true
    Write-Host 'Installer Authenticode signature is valid and matches the release identity.'
  }
}
