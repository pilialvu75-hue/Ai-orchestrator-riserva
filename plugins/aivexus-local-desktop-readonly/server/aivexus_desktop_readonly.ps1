# Desktop-only MCP entrypoint. Emits NO diagnostic text to stdout.
# Only the approved loopback AIVEXUS bridge is used; no remote calls.
$ErrorActionPreference = 'Stop'
$env:AIVEXUS_MCP_INSTANCE_ONLY = '1'
# Do not accidentally reuse an inherited key from another process.
$env:AIVEXUS_BRIDGE_TOKEN = $null

$tokenPath = Join-Path $env:LOCALAPPDATA 'AIVEXUS\ChatGPT-Desktop-ReadOnly\bridge-token.dpapi'
if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
    $secured = $null
    $bstr = [IntPtr]::Zero
    try {
        $stored = ([System.IO.File]::ReadAllText($tokenPath)).Trim()
        $secured = ConvertTo-SecureString -String $stored
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secured)
        $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ($token.Length -ge 32) { $env:AIVEXUS_BRIDGE_TOKEN = $token }
        $token = $null
    } catch {
        # No exception details on the MCP stdio stream. The adapter reports
        # bridge_token_missing when instance_info is requested.
        $env:AIVEXUS_BRIDGE_TOKEN = $null
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ($null -ne $secured) { $secured.Dispose() }
    }
}

try {
    & (Join-Path $PSScriptRoot 'aivexus_mcp.ps1')
} finally {
    $env:AIVEXUS_BRIDGE_TOKEN = $null
    $env:AIVEXUS_MCP_INSTANCE_ONLY = $null
}
