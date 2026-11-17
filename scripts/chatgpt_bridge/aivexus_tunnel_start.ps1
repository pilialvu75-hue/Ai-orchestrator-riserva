# AIVEXUS -> ordinary ChatGPT Chat via OpenAI Secure MCP Tunnel.
# Private QA launcher, opt-in only. No Windows security policy is changed.
# Supports built-in Windows PowerShell 5.1 and later.
[CmdletBinding()]
param(
    [string]$TunnelId,
    [string]$TunnelClientExe,
    [string]$McpScriptPath,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$profileName = 'aivexus-local-test'

# Optional default: the previously verified ASUS Windows download location.
if ([string]::IsNullOrWhiteSpace($TunnelClientExe)) {
    $TunnelClientExe = Join-Path $env:USERPROFILE 'Downloads\AIVEXUS-Tunnel-Client\tunnel-client.exe'
}

# The local adapter is a trusted copy in the private Windows QA package.
# Multiple copies are ambiguous: never choose one silently.
if ([string]::IsNullOrWhiteSpace($McpScriptPath)) {
    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    $candidates = @(
        Get-ChildItem -LiteralPath $downloads -Filter 'aivexus_mcp.ps1' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/]mcp-tools[\\/]aivexus_mcp\.ps1$' }
    )
    if ($candidates.Count -ne 1) {
        throw 'Could not identify one trusted QA MCP adapter. Specify -McpScriptPath explicitly.'
    }
    $McpScriptPath = $candidates[0].FullName
}

if ([string]::IsNullOrWhiteSpace($TunnelId)) {
    if ($CheckOnly) {
        Write-Host 'Tunnel ID not specified: it will be requested at activation.'
    } else {
        $TunnelId = ([string](Read-Host 'Paste existing OpenAI Platform tunnel ID')).Trim()
    }
}
if (-not [string]::IsNullOrWhiteSpace($TunnelId)) {
    if ($TunnelId -cnotmatch '^tunnel_[a-z0-9]{32}$') {
        throw 'Invalid tunnel ID format; verify the value on OpenAI Platform.'
    }
}

if (-not (Test-Path -LiteralPath $TunnelClientExe -PathType Leaf)) {
    throw 'tunnel-client.exe not found at the expected local path.'
}
if ((Split-Path -Path $TunnelClientExe -Leaf) -ne 'tunnel-client.exe') {
    throw 'Expected official executable named tunnel-client.exe.'
}
if (-not (Test-Path -LiteralPath $McpScriptPath -PathType Leaf)) {
    throw 'AIVEXUS adapter aivexus_mcp.ps1 not found.'
}
if ((Split-Path -Path $McpScriptPath -Leaf) -ne 'aivexus_mcp.ps1') {
    throw 'Expected trusted adapter named aivexus_mcp.ps1.'
}
$clientPath = (Resolve-Path -LiteralPath $TunnelClientExe).Path
$scriptFullPath = (Resolve-Path -LiteralPath $McpScriptPath).Path
if ($scriptFullPath.Contains('"')) {
    throw 'Unsupported quote character in MCP adapter file path.'
}
# The tunnel-client command parser can truncate a quoted -File path containing
# spaces (for example the ASUS QA ZIP folder with ' (1)' in its name).
# Stage this vetted adapter beside the verified tunnel-client binary instead.
$stagedAdapter = Join-Path (Split-Path -Path $clientPath -Parent) 'aivexus_mcp.ps1'
if ($stagedAdapter -match '\s') {
    throw 'The tunnel-client folder contains spaces; choose -TunnelClientExe in a path without spaces.'
}

if ($CheckOnly) {
    Write-Host 'PRECHECK PASS: tunnel-client.exe and aivexus_mcp.ps1 exist.'
    Write-Host 'No keys read, no network requests, no tunnel started.'
    return
}

# Copy only the trusted local adapter script, never credentials. No inbound
# listener, registry, Windows policy, or AIVEXUS runtime is changed.
Copy-Item -LiteralPath $scriptFullPath -Destination $stagedAdapter -Force
Write-Host 'Prepared stable MCP adapter path (without spaces).'

# The existing local AIVEXUS token is copied inside AIVEXUS, not ChatGPT.
Write-Host 'In AIVEXUS, press Copy connection key; then return to this window.'
$bridgeToken = ([string](Get-Clipboard -Raw)).Trim()
if ($bridgeToken.Length -lt 32) {
    throw 'Missing AIVEXUS local bridge key in clipboard. No tunnel started.'
}

# Use the separate restricted Platform runtime key (Tunnels Read + Use).
# Read-Host -AsSecureString does not print the key.
$runtimeSecret = Read-Host 'OpenAI Platform tunnel runtime API key (hidden)' -AsSecureString
if ($null -eq $runtimeSecret -or $runtimeSecret.Length -lt 10) {
    throw 'Missing Platform tunnel runtime API key. No tunnel started.'
}

$previousBridgeToken = [Environment]::GetEnvironmentVariable('AIVEXUS_BRIDGE_TOKEN', 'Process')
$previousControlKey = [Environment]::GetEnvironmentVariable('CONTROL_PLANE_API_KEY', 'Process')
$bstr = [IntPtr]::Zero
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($runtimeSecret)
    $runtimeKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:AIVEXUS_BRIDGE_TOKEN = $bridgeToken
    $env:CONTROL_PLANE_API_KEY = $runtimeKey
    $runtimeKey = $null
    $bridgeToken = $null

    $mcpCommand = 'powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File ' + $stagedAdapter
    Write-Host 'Creating a private local STDIO tunnel profile.'
    & $clientPath init --sample sample_mcp_stdio_local --profile $profileName --tunnel-id $TunnelId --mcp-command $mcpCommand
    if ($LASTEXITCODE -ne 0) { throw 'Tunnel profile initialization failed.' }

    Write-Host 'Checking private tunnel readiness.'
    & $clientPath doctor --profile $profileName --explain
    if ($LASTEXITCODE -ne 0) { throw 'Tunnel readiness check failed.' }

    Write-Host 'Starting private tunnel. Press Ctrl+C to stop.'
    # Stop on any child-process failure rather than repeatedly restarting it.
    & $clientPath run --profile $profileName --mcp.stdio-failure-policy=exit
    if ($LASTEXITCODE -ne 0) { throw 'Tunnel client stopped with an error.' }
}
finally {
    [Environment]::SetEnvironmentVariable('AIVEXUS_BRIDGE_TOKEN', $previousBridgeToken, 'Process')
    [Environment]::SetEnvironmentVariable('CONTROL_PLANE_API_KEY', $previousControlKey, 'Process')
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ($null -ne $runtimeSecret) { $runtimeSecret.Dispose() }
}
