param(
  [Parameter(Mandatory = $true)]
  [string]$ReleaseDir
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ReleaseDir)) {
  throw "Windows release directory not found: $ReleaseDir"
}

function Find-PatternOffsets([byte[]]$Haystack, [byte[]]$Needle) {
  $offsets = New-Object System.Collections.Generic.List[int]
  for ($i = 0; $i -le $Haystack.Length - $Needle.Length; $i++) {
    $match = $true
    for ($j = 0; $j -lt $Needle.Length; $j++) {
      if ($Haystack[$i + $j] -ne $Needle[$j]) {
        $match = $false
        break
      }
    }
    if ($match) {
      $offsets.Add($i)
    }
  }
  return $offsets
}

function Count-AsciiPattern([byte[]]$Bytes, [string]$Text) {
  return (Find-PatternOffsets $Bytes ([Text.Encoding]::ASCII.GetBytes($Text))).Count
}

function Replace-ExactAsciiImport(
  [byte[]]$Bytes,
  [string]$Original,
  [string]$Replacement
) {
  $oldName = [Text.Encoding]::ASCII.GetBytes($Original)
  $newName = [Text.Encoding]::ASCII.GetBytes($Replacement)
  if ($oldName.Length -ne $newName.Length) {
    throw "Replacement '$Replacement' must have the same byte length as '$Original'."
  }

  $oldOffsets = Find-PatternOffsets $Bytes $oldName
  $newOffsets = Find-PatternOffsets $Bytes $newName

  if ($oldOffsets.Count -eq 0 -and $newOffsets.Count -eq 1) {
    Write-Host "$Original is already redirected to $Replacement."
    return
  }
  if ($oldOffsets.Count -ne 1) {
    throw "Expected exactly one '$Original' import string, found $($oldOffsets.Count)."
  }
  if ($newOffsets.Count -ne 0) {
    throw "Unexpected pre-existing '$Replacement' string count: $($newOffsets.Count)."
  }

  $offset = $oldOffsets[0]
  [Array]::Copy($newName, 0, $Bytes, $offset, $newName.Length)
  Write-Host "Redirected $Original -> $Replacement at byte offset $offset"
}

# Diagnostic engine-only branch: ONNX is intentionally not required. The
# generated native plugin targets are absent, so sherpa/ONNX does not enter the
# release bundle. All loader-critical Flutter/Win7 compatibility files remain
# mandatory. Production branches retain the stricter patcher.
$requiredFiles = @(
  'ai_orchestrator.exe',
  'AI-Orchestrator-Windows-Diagnostics.exe',
  'flutter_windows.dll',
  'ws2fix.dll',
  'nt7fx.dll',
  'win7krnl.dll',
  'win7path-compatibility-shim.dll',
  'ai-orchestrator-sync-win7fix.dll',
  'dxg7.dll'
)
foreach ($name in $requiredFiles) {
  $path = Join-Path $ReleaseDir $name
  if (-not (Test-Path $path)) {
    throw "Windows 7 compatibility file is missing from release bundle: $path"
  }
}

$runnerPath = Join-Path $ReleaseDir 'ai_orchestrator.exe'
$runnerBytes = [IO.File]::ReadAllBytes($runnerPath)
$runnerForbiddenSymbols = @(
  'WaitOnAddress',
  'WakeByAddressSingle',
  'WakeByAddressAll',
  'GetCurrentThreadStackLimits',
  'GetSystemTimePreciseAsFileTime',
  'GetProcessMitigationPolicy',
  'CreateFile2',
  'PathCchCanonicalize',
  'PathCchCombine',
  'PathCchRemoveBackslash',
  'RtlAddGrowableFunctionTable',
  'RtlDeleteGrowableFunctionTable'
)
foreach ($symbol in $runnerForbiddenSymbols) {
  $count = Count-AsciiPattern $runnerBytes $symbol
  if ($count -ne 0) {
    throw "Windows 7 runner validation failed: '$symbol' appears $count time(s) in ai_orchestrator.exe."
  }
}
Write-Host 'Windows 7 runner forbidden-symbol validation passed.'

$flutterPath = Join-Path $ReleaseDir 'flutter_windows.dll'
$flutterBytes = [IO.File]::ReadAllBytes($flutterPath)
$flutterChecks = @(
  @('WS2_32.dll', 0),
  @('ws2fix.dll', 1),
  @('ntdll.dll', 0),
  @('nt7fx.dll', 1),
  @('KERNEL32.dll', 0),
  @('win7krnl.dll', 1),
  @('api-ms-win-core-path-l1-1-0.dll', 0),
  @('win7path-compatibility-shim.dll', 1),
  @('api-ms-win-core-synch-l1-2-0.dll', 0),
  @('ai-orchestrator-sync-win7fix.dll', 1)
)
foreach ($check in $flutterChecks) {
  $count = Count-AsciiPattern $flutterBytes ([string]$check[0])
  if ($count -ne [int]$check[1]) {
    throw "Flutter compatibility validation failed for $($check[0]): expected $($check[1]), found $count."
  }
}

$onnxPath = Join-Path $ReleaseDir 'onnxruntime.dll'
if (Test-Path $onnxPath) {
  $onnxBytes = [IO.File]::ReadAllBytes($onnxPath)
  $onnxRedirects = @(
    @('KERNEL32.dll', 'win7krnl.dll'),
    @('api-ms-win-core-path-l1-1-0.dll', 'win7path-compatibility-shim.dll'),
    @('dxgi.dll', 'dxg7.dll')
  )
  foreach ($redirect in $onnxRedirects) {
    Replace-ExactAsciiImport $onnxBytes $redirect[0] $redirect[1]
  }
  [IO.File]::WriteAllBytes($onnxPath, $onnxBytes)

  $verifiedOnnx = [IO.File]::ReadAllBytes($onnxPath)
  foreach ($redirect in $onnxRedirects) {
    $oldCount = Count-AsciiPattern $verifiedOnnx ([string]$redirect[0])
    $newCount = Count-AsciiPattern $verifiedOnnx ([string]$redirect[1])
    if ($oldCount -ne 0 -or $newCount -ne 1) {
      throw "ONNX compatibility validation failed for $($redirect[0]): old=$oldCount new=$newCount."
    }
  }
  $hash = (Get-FileHash -Path $onnxPath -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Host "Patched ONNX Runtime SHA256: $hash"
} else {
  Write-Host 'Engine-only diagnostic bundle: onnxruntime.dll intentionally absent; ONNX patch skipped.'
}

Write-Host "Windows 7 engine-only release bundle compatibility validation passed."
