# One-time per Windows user, and after the ephemeral AIVEXUS key rotates.
# The key never goes to ChatGPT or GitHub. DPAPI protects it for this user.
[CmdletBinding()]
param([switch]$Clear)
$ErrorActionPreference = 'Stop'
$folder = Join-Path $env:LOCALAPPDATA 'AIVEXUS\ChatGPT-Desktop-ReadOnly'
$tokenPath = Join-Path $folder 'bridge-token.dpapi'
if ($Clear) {
    if (Test-Path -LiteralPath $tokenPath) { Remove-Item -LiteralPath $tokenPath -Force }
    Write-Host 'AIVEXUS Desktop: stored local key cleared.'
    return
}
Write-Host 'In AIVEXUS Windows, enable the local bridge and press Copy connection key.'
Read-Host 'When the key is in the clipboard, press Enter' | Out-Null
$token = ([string](Get-Clipboard -Raw)).Trim()
if ([string]::IsNullOrWhiteSpace($token) -or $token.Length -lt 32) {
    throw 'The clipboard does not contain a valid AIVEXUS bridge key. Nothing was stored.'
}
$secure = $null
try {
    $secure = ConvertTo-SecureString -String $token -AsPlainText -Force
    $protected = ConvertFrom-SecureString -SecureString $secure
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    [System.IO.File]::WriteAllText($tokenPath, $protected,
        (New-Object System.Text.UTF8Encoding($false)))
    # Clear only the original secret; never print it or send it to a remote host.
    if (([string](Get-Clipboard -Raw)).Trim() -ceq $token) {
        Set-Clipboard -Value ''
    }
    Write-Host 'AIVEXUS Desktop: local key protected with Windows DPAPI for this Windows user.'
    Write-Host 'Run this setup again after AIVEXUS rotates the connection key.'
} finally {
    $token = $null
    $protected = $null
    if ($null -ne $secure) { $secure.Dispose() }
}
