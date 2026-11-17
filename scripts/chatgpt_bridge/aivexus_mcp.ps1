# AIVEXUS MCP stdio adapter for built-in Windows PowerShell 5.1+.
# No extra runtime, generic shell tool, remote URLs, or stdout diagnostics.
# Run only from ChatGPT Desktop's explicitly configured custom MCP entry.

$ErrorActionPreference = 'Stop'
try {
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

$BaseUrl = 'http://127.0.0.1:47941'
$ProtocolVersion = '2025-06-18'

function Test-SyntheticId($Value) {
    return ($Value -is [string]) -and ($Value -cmatch '\A[A-Za-z0-9_-]{8,64}\z')
}

function Invoke-AivexusRequest([string]$Method, [string]$Path, $Body = $null) {
    $secret = [Environment]::GetEnvironmentVariable('AIVEXUS_BRIDGE_TOKEN')
    if ([string]::IsNullOrEmpty($secret) -or $secret.Length -lt 32) {
        return @{ error = 'bridge_token_missing' }
    }
    try {
        $request = [System.Net.HttpWebRequest]::Create($BaseUrl + $Path)
        $request.Method = $Method
        $request.Timeout = 8000
        $request.ReadWriteTimeout = 8000
        $request.AllowAutoRedirect = $false
        $request.Headers.Add('Authorization', 'Bearer ' + $secret)
        if ($null -ne $Body) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(
                (ConvertTo-Json -InputObject $Body -Compress -Depth 10))
            $request.ContentType = 'application/json'
            $request.ContentLength = $bytes.Length
            $stream = $request.GetRequestStream()
            try { $stream.Write($bytes, 0, $bytes.Length) }
            finally { $stream.Dispose() }
        }
        $response = $request.GetResponse()
        try {
            $reader = New-Object System.IO.StreamReader(
                $response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try { $raw = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally { $response.Dispose() }
        if ($raw.Length -gt 32768) { return @{ error = 'bridge_response_too_large' } }
        return (ConvertFrom-Json -InputObject $raw)
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            $status = [int]$response.StatusCode
            $response.Dispose()
            return @{ error = 'bridge_http_error'; http_status = $status }
        }
        return @{ error = 'aivexus_not_reachable' }
    }
    catch {
        # Never output the exception, URL, secret or OS paths over MCP.
        return @{ error = 'bridge_transport_error' }
    }
}

function Get-ToolSchema([string]$Name, [string]$Description, $Properties, $Required) {
    return @{
        name = $Name
        description = $Description
        inputSchema = @{
            type = 'object'
            properties = $Properties
            required = @($Required)
            additionalProperties = $false
        }
    }
}

$idProperty = @{ request_id = @{ type = 'string'; pattern = '^[A-Za-z0-9_-]{8,64}$' } }
$Tools = @(
    (Get-ToolSchema 'instance_info' 'Identify the real running AIVEXUS instance without starting it.' @{} @()),
    (Get-ToolSchema 'diagnostics_read' 'Read sanitized synthetic test status and runtime health only.' $idProperty @('request_id')),
    (Get-ToolSchema 'test_start' 'Start fixed synthetic runtime self-test; retry with same request ID.' @{
        request_id = @{ type = 'string'; pattern = '^[A-Za-z0-9_-]{8,64}$' }
        kind = @{ type = 'string'; enum = @('runtime') }
    } @('request_id', 'kind')),
    (Get-ToolSchema 'test_status' 'Recover existing synthetic test outcome; never reruns it.' $idProperty @('request_id')),
    (Get-ToolSchema 'test_cancel' 'Request cooperative cancellation of running test.' $idProperty @('request_id')),
    (Get-ToolSchema 'test_compare' 'Compare durations and statuses of two stored tests.' @{
        first_request_id = @{ type = 'string'; pattern = '^[A-Za-z0-9_-]{8,64}$' }
        second_request_id = @{ type = 'string'; pattern = '^[A-Za-z0-9_-]{8,64}$' }
    } @('first_request_id', 'second_request_id'))
)

function Invoke-BridgeTool([string]$Name, $Arguments) {
    if ($null -eq $Arguments) { $Arguments = [pscustomobject]@{} }
    switch ($Name) {
        'instance_info' {
            if (@($Arguments.PSObject.Properties).Count -gt 0) {
                return @{ error = 'invalid_arguments' }
            }
            return (Invoke-AivexusRequest 'GET' '/v1/instance')
        }
        { $_ -in @('diagnostics_read', 'test_status', 'test_cancel') } {
            if (!(Test-SyntheticId $Arguments.request_id) -or
                @($Arguments.PSObject.Properties).Count -ne 1) {
                return @{ error = 'invalid_request_id' }
            }
            $id = $Arguments.request_id
            if ($Name -eq 'diagnostics_read') {
                return (Invoke-AivexusRequest 'GET' ('/v1/diagnostics?request_id=' + $id))
            }
            if ($Name -eq 'test_status') {
                return (Invoke-AivexusRequest 'GET' ('/v1/tests/' + $id))
            }
            return (Invoke-AivexusRequest 'POST' ('/v1/tests/' + $id + '/cancel') @{})
        }
        'test_start' {
            if (!(Test-SyntheticId $Arguments.request_id) -or
                $Arguments.kind -cne 'runtime' -or
                @($Arguments.PSObject.Properties).Count -ne 2) {
                return @{ error = 'invalid_or_unsupported_test' }
            }
            return (Invoke-AivexusRequest 'POST' '/v1/tests' @{
                request_id = $Arguments.request_id
                kind = 'runtime'
            })
        }
        'test_compare' {
            $a = $Arguments.first_request_id
            $b = $Arguments.second_request_id
            if (!(Test-SyntheticId $a) -or !(Test-SyntheticId $b) -or
                @($Arguments.PSObject.Properties).Count -ne 2) {
                return @{ error = 'invalid_request_id' }
            }
            $first = Invoke-AivexusRequest 'GET' ('/v1/tests/' + $a)
            $second = Invoke-AivexusRequest 'GET' ('/v1/tests/' + $b)
            if ($first.error -or $second.error) {
                return @{ error = 'comparison_unavailable'; first = $first; second = $second }
            }
            $delta = $null
            if ($null -ne $first.elapsed_ms -and $null -ne $second.elapsed_ms) {
                $delta = [long]$second.elapsed_ms - [long]$first.elapsed_ms
            }
            return @{ first = $first; second = $second; elapsed_delta_ms = $delta }
        }
        default { return @{ error = 'unknown_tool' } }
    }
}

function Write-McpResponse($Value) {
    try {
        $line = ConvertTo-Json -InputObject $Value -Compress -Depth 20
        [Console]::Out.WriteLine($line)
        [Console]::Out.Flush()
    } catch {
        [Console]::Out.WriteLine('{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}')
        [Console]::Out.Flush()
    }
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
    try {
        $message = ConvertFrom-Json -InputObject $line
        if ($message.jsonrpc -ne '2.0') { continue }
        if (!($message.PSObject.Properties.Name -contains 'id')) { continue }
        $id = $message.id
        $result = $null
        switch ($message.method) {
            'initialize' {
                $result = @{
                    protocolVersion = $ProtocolVersion
                    capabilities = @{ tools = @{} }
                    serverInfo = @{ name = 'aivexus-local-test-bridge'; version = '0.1.0' }
                }
            }
            'ping' { $result = @{} }
            'tools/list' { $result = @{ tools = $Tools } }
            'tools/call' {
                $data = Invoke-BridgeTool ([string]$message.params.name) $message.params.arguments
                $result = @{
                    content = @(@{
                        type = 'text'
                        text = (ConvertTo-Json -InputObject $data -Compress -Depth 14)
                    })
                    isError = [bool]($null -ne $data.error)
                }
            }
            default {
                Write-McpResponse @{ jsonrpc = '2.0'; id = $id; error = @{
                    code = -32601; message = 'Method not found'
                } }
                continue
            }
        }
        Write-McpResponse @{ jsonrpc = '2.0'; id = $id; result = $result }
    }
    catch {
        # CI-only diagnostics: ID and line number, never exception text or secrets.
        if ($env:AIVEXUS_MCP_TEST_MODE -eq '1') {
            [Console]::Error.WriteLine('MCP_TEST_ERROR=' + $_.FullyQualifiedErrorId +
                ';line=' + $_.InvocationInfo.ScriptLineNumber)
        }
        # A malformed message cannot reveal OS paths or stack traces.
        Write-McpResponse @{
            jsonrpc = '2.0'; id = $null
            error = @{ code = -32700; message = 'Parse error' }
        }
    }
}
