# AIVEXUS Local Test -> ChatGPT normal chats via OpenAI Secure MCP Tunnel.
# Opt-in only. Does not install software, configure Windows policy, open ports,
# register a ChatGPT plugin, or create/reveal Platform credentials.
# Windows PowerShell 5.1+. Follow docs/CHATGPT_LOCAL_TEST_BRIDGE.md.
[CmdletBinding()]
param(
    [string]$TunnelId,

    [string]$TunnelClientExe,

    [string]$McpScriptPath,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$profileName = 'aivexus-local-test'

# One-time ASUS default paths; any location may still be supplied explicitly.
if ([string]::IsNullOrWhiteSpace($TunnelClientExe)) {
    $TunnelClientExe = Join-Path $env:USERPROFILE 'Downloads\AIVEXUS-Tunnel-Client\tunnel-client.exe'
}
if ([string]::IsNullOrWhiteSpace($McpScriptPath)) {
    $candidates = @(Get-ChildItem (Join-Path $env:USERPROFILE 'Downloads') -Filter 'aivexus_mcp.ps1' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/]mcp-tools[\\/]aivexus_mcp\.ps1 {
    throw 'tunnel-client.exe not found. Obtain the approved Windows build from official OpenAI Platform tunnel settings.'
}
if ((Split-Path -Leaf $TunnelClientExe) -ne 'tunnel-client.exe') {
    throw 'The client must be the official tunnel-client.exe executable.'
}
if (!(Test-Path -LiteralPath $McpScriptPath -PathType Leaf)) {
    throw 'The AIVEXUS MCP adapter path does not exist.'
}
if ((Split-Path -Leaf $McpScriptPath) -ne 'aivexus_mcp.ps1') {
    throw 'Only the AIVEXUS MCP adapter aivexus_mcp.ps1 is supported.'
}
$scriptFullPath = (Resolve-Path -LiteralPath $McpScriptPath).Path
if ($scriptFullPath.Contains('"')) {
    throw 'Unsupported double-quote in MCP script path.'
}
if ($CheckOnly) {
    Write-Host 'Paths and tunnel ID syntax validated. No secrets read; no network requests or processes started.'
    return
}

Write-Host 'Copy the *existing* local bridge key using AIVEXUS > Copy connection key.'
Write-Host 'The key will be read from the clipboard, not echoed or written to disk.'
$bridgeToken = ([string](Get-Clipboard -Raw)).Trim()
if ($bridgeToken.Length -lt 32) {
    throw 'Clipboard does not contain a valid AIVEXUS bridge key. No tunnel started.'
}

# Read an independently scoped Platform runtime key through a concealed prompt.
# The Platform key needs Tunnels Read + Use, not Tunnels Manage.
$runtimeSecret = Read-Host 'Platform tunnel runtime API key (hidden input)' -AsSecureString
if ($null -eq $runtimeSecret -or $runtimeSecret.Length -lt 10) {
    throw 'Missing tunnel runtime key. No tunnel started.'
}
$bstr = [IntPtr]::Zero
$previousBridgeToken = [Environment]::GetEnvironmentVariable('AIVEXUS_BRIDGE_TOKEN','Process')
$previousControlPlaneKey = [Environment]::GetEnvironmentVariable('CONTROL_PLANE_API_KEY','Process')
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($runtimeSecret)
    $runtimeKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:AIVEXUS_BRIDGE_TOKEN = $bridgeToken
    $env:CONTROL_PLANE_API_KEY = $runtimeKey
    $runtimeKey = $null
    $bridgeToken = $null

    # The tunnel client inherits the two process-local environment variables;
    # the spawned MCP PowerShell child inherits only the local bridge token.
    # No secret is passed via command-line arguments or written to YAML.
    $mcpCommand = 'powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "' + $scriptFullPath + '"'
    Write-Host 'Initializing a local STDIO profile. No public listener is opened.'
    & $TunnelClientExe init --sample sample_mcp_stdio_local --profile $profileName --tunnel-id $TunnelId --mcp-command $mcpCommand
    if ($LASTEXITCODE -ne 0) { throw 'tunnel-client init failed' }
    Write-Host 'Checking tunnel readiness. This can require an authorized Platform tunnel association.'
    & $TunnelClientExe doctor --profile $profileName --explain
    if ($LASTEXITCODE -ne 0) { throw 'tunnel-client doctor reported an error' }
    Write-Host 'Running private tunnel. Keep AIVEXUS and this window open; Ctrl+C stops the tunnel.'
    & $TunnelClientExe run --profile $profileName
    if ($LASTEXITCODE -ne 0) { throw 'tunnel-client terminated with an error' }
}
finally {
    [Environment]::SetEnvironmentVariable('AIVEXUS_BRIDGE_TOKEN',$previousBridgeToken,'Process')
    [Environment]::SetEnvironmentVariable('CONTROL_PLANE_API_KEY',$previousControlPlaneKey,'Process')
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ($null -ne $runtimeSecret) { $runtimeSecret.Dispose() }
}
 })
    if ($candidates.Count -ne 1) {
        throw 'Could not select a unique aivexus_mcp.ps1 in Downloads. Use -McpScriptPath with the exact trusted QA path.'
    }
    $McpScriptPath = $candidates[0].FullName
}
if ([string]::IsNullOrWhiteSpace($TunnelId)) {
    if ($CheckOnly) {
        Write-Host 'Tunnel ID not supplied. In live mode the user will be prompted for the Platform tunnel ID.'
    } else {
        Write-Host 'Open OpenAI Platform > Tunnels and copy the ID of the existing AIVEXUS tunnel.'
        $TunnelId = ([string](Read-Host 'Paste tunnel ID')).Trim()
    }
}
if ($TunnelId -and $TunnelId -cnotmatch '^tunnel_[a-z0-9]{32} {
    throw 'tunnel-client.exe not found. Obtain the approved Windows build from official OpenAI Platform tunnel settings.'
}
if ((Split-Path -Leaf $TunnelClientExe) -ne 'tunnel-client.exe') {
    throw 'The client must be the official tunnel-client.exe executable.'
}
if (!(Test-Path -LiteralPath $McpScriptPath -PathType Leaf)) {
    throw 'The AIVEXUS MCP adapter path does not exist.'
}
if ((Split-Path -Leaf $McpScriptPath) -ne 'aivexus_mcp.ps1') {
    throw 'Only the AIVEXUS MCP adapter aivexus_mcp.ps1 is supported.'
}
$scriptFullPath = (Resolve-Path -LiteralPath $McpScriptPath).Path
if ($scriptFullPath.Contains('"')) {
    throw 'Unsupported double-quote in MCP script path.'
}
if ($CheckOnly) {
    Write-Host 'Paths and tunnel ID syntax validated. No secrets read; no network requests or processes started.'
    return
}

Write-Host 'Copy the *existing* local bridge key using AIVEXUS > Copy connection key.'
Write-Host 'The key will be read from the clipboard, not echoed or written to disk.'
$bridgeToken = ([string](Get-Clipboard -Raw)).Trim()
if ($bridgeToken.Length -lt 32) {
    throw 'Clipboard does not contain a valid AIVEXUS bridge key. No tunnel started.'
}

# Read an independently scoped Platform runtime key through a concealed prompt.
# The Platform key needs Tunnels Read + Use, not Tunnels Manage.
$runtimeSecret = Read-Host 'Platform tunnel runtime API key (hidden input)' -AsSecureString
if ($null -eq $runtimeSecret -or $runtimeSecret.Length -lt 10) {
    throw 'Missing tunnel runtime key. No tunnel started.'
}
$bstr = [IntPtr]::Zero
$previousBridgeToken = [Environment]::GetEnvironmentVariable('AIVEXUS_BRIDGE_TOKEN','Process')
$previousControlPlaneKey = [Environment]::GetEnvironmentVariable('CONTROL_PLANE_API_KEY','Process')
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($runtimeSecret)
    $runtimeKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:AIVEXUS_BRIDGE_TOKEN = $bridgeToken
    $env:CONTROL_PLANE_API_KEY = $runtimeKey
    $runtimeKey = $null
    $bridgeToken = $null

    # The tunnel client inherits the two process-local environment variables;
    # the spawned MCP PowerShell child inherits only the local bridge token.
    # No secret is passed via command-line arguments or written to YAML.
    $mcpCommand = 'powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "' + $scriptFullPath + '"'
    Write-Host 'Initializing a local STDIO profile. No public listener is opened.'
    & $TunnelClientExe init --sample sample_mcp_stdio_local --profile $profileName --tunnel-id $TunnelId --mcp-command $mcpCommand
    if ($LASTEXITCODE -ne 0) { throw 'tunnel-client init failed' }
    Write-Host 'Checking tunnel readiness. This can require an authorized Platform tunnel association.'
    & $TunnelClientExe doctor --profile $profileName --explain
    if ($LASTEXITCODE -ne 0) { throw 'tunnel-client doctor reported an error' }
    Write-Host 'Running private tunnel. Keep AIVEXUS and this window open; Ctrl+C stops the tunnel.'
    & $TunnelClientExe run --profile $profileName
    if ($LASTEXITCODE -ne 0) { throw 'tunnel-client terminated with an error' }
}
finally {
    [Environment]::SetEnvironmentVariable('AIVEXUS_BRIDGE_TOKEN',$previousBridgeToken,'Process')
    [Environment]::SetEnvironmentVariable('CONTROL_PLANE_API_KEY',$previousControlPlaneKey,'Process')
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ($null -ne $runtimeSecret) { $runtimeSecret.Dispose() }
}
) {
    throw 'Invalid tunnel ID format. Paste the complete tunnel_... value from OpenAI Platform.'
}

if (!(Test-Path -LiteralPath $TunnelClientExe -PathType Leaf)) {
    throw 'tunnel-client.exe not found. Obtain the approved Windows build from official OpenAI Platform tunnel settings.'
}
if ((Split-Path -Leaf $TunnelClientExe) -ne 'tunnel-client.exe') {
    throw 'The client must be the official tunnel-client.exe executable.'
}
if (!(Test-Path -LiteralPath $McpScriptPath -PathType Leaf)) {
    throw 'The AIVEXUS MCP adapter path does not exist.'
}
if ((Split-Path -Leaf $McpScriptPath) -ne 'aivexus_mcp.ps1') {
    throw 'Only the AIVEXUS MCP adapter aivexus_mcp.ps1 is supported.'
}
$scriptFullPath = (Resolve-Path -LiteralPath $McpScriptPath).Path
if ($scriptFullPath.Contains('"')) {
    throw 'Unsupported double-quote in MCP script path.'
}
if ($CheckOnly) {
    Write-Host 'Paths and tunnel ID syntax validated. No secrets read; no network requests or processes started.'
    return
}

Write-Host 'Copy the *existing* local bridge key using AIVEXUS > Copy connection key.'
Write-Host 'The key will be read from the clipboard, not echoed or written to disk.'
$bridgeToken = ([string](Get-Clipboard -Raw)).Trim()
if ($bridgeToken.Length -lt 32) {
    throw 'Clipboard does not contain a valid AIVEXUS bridge key. No tunnel started.'
}

# Read an independently scoped Platform runtime key through a concealed prompt.
# The Platform key needs Tunnels Read + Use, not Tunnels Manage.
$runtimeSecret = Read-Host 'Platform tunnel runtime API key (hidden input)' -AsSecureString
if ($null -eq $runtimeSecret -or $runtimeSecret.Length -lt 10) {
    throw 'Missing tunnel runtime key. No tunnel started.'
}
$bstr = [IntPtr]::Zero
$previousBridgeToken = [Environment]::GetEnvironmentVariable('AIVEXUS_BRIDGE_TOKEN','Process')
$previousControlPlaneKey = [Environment]::GetEnvironmentVariable('CONTROL_PLANE_API_KEY','Process')
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($runtimeSecret)
    $runtimeKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:AIVEXUS_BRIDGE_TOKEN = $bridgeToken
    $env:CONTROL_PLANE_API_KEY = $runtimeKey
    $runtimeKey = $null
    $bridgeToken = $null

    # The tunnel client inherits the two process-local environment variables;
    # the spawned MCP PowerShell child inherits only the local bridge token.
    # No secret is passed via command-line arguments or written to YAML.
    $mcpCommand = 'powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "' + $scriptFullPath + '"'
    Write-Host 'Initializing a local STDIO profile. No public listener is opened.'
    & $TunnelClientExe init --sample sample_mcp_stdio_local --profile $profileName --tunnel-id $TunnelId --mcp-command $mcpCommand
    if ($LASTEXITCODE -ne 0) { throw 'tunnel-client init failed' }
    Write-Host 'Checking tunnel readiness. This can require an authorized Platform tunnel association.'
    & $TunnelClientExe doctor --profile $profileName --explain
    if ($LASTEXITCODE -ne 0) { throw 'tunnel-client doctor reported an error' }
    Write-Host 'Running private tunnel. Keep AIVEXUS and this window open; Ctrl+C stops the tunnel.'
    & $TunnelClientExe run --profile $profileName
    if ($LASTEXITCODE -ne 0) { throw 'tunnel-client terminated with an error' }
}
finally {
    [Environment]::SetEnvironmentVariable('AIVEXUS_BRIDGE_TOKEN',$previousBridgeToken,'Process')
    [Environment]::SetEnvironmentVariable('CONTROL_PLANE_API_KEY',$previousControlPlaneKey,'Process')
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ($null -ne $runtimeSecret) { $runtimeSecret.Dispose() }
}
