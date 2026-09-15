param(
  [Parameter(Mandatory = $true)]
  [string]$FlutterDll
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $FlutterDll)) {
  throw "Flutter engine DLL not found: $FlutterDll"
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

$redirects = @(
  @('WS2_32.dll', 'ws2fix.dll'),
  @('ntdll.dll', 'nt7fx.dll'),
  @('KERNEL32.dll', 'win7krnl.dll'),
  @('api-ms-win-core-path-l1-1-0.dll', 'win7path-compatibility-shim.dll'),
  @('api-ms-win-core-synch-l1-2-0.dll', 'ai-orchestrator-sync-win7fix.dll')
)

$bytes = [IO.File]::ReadAllBytes($FlutterDll)
foreach ($redirect in $redirects) {
  Replace-ExactAsciiImport $bytes $redirect[0] $redirect[1]
}
[IO.File]::WriteAllBytes($FlutterDll, $bytes)

$verified = [IO.File]::ReadAllBytes($FlutterDll)
foreach ($redirect in $redirects) {
  $oldPattern = [Text.Encoding]::ASCII.GetBytes([string]$redirect[0])
  $newPattern = [Text.Encoding]::ASCII.GetBytes([string]$redirect[1])
  $oldCount = (Find-PatternOffsets $verified $oldPattern).Count
  $newCount = (Find-PatternOffsets $verified $newPattern).Count
  if ($oldCount -ne 0 -or $newCount -ne 1) {
    throw "Post-patch validation failed for $($redirect[0]): old=$oldCount new=$newCount."
  }
}

Write-Host 'Flutter Windows 7 import redirection validated for all known loader blockers.'
