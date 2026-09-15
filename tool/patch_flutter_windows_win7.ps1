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

$bytes = [IO.File]::ReadAllBytes($FlutterDll)
Replace-ExactAsciiImport $bytes 'WS2_32.dll' 'ws2fix.dll'
Replace-ExactAsciiImport $bytes 'ntdll.dll' 'nt7fx.dll'
[IO.File]::WriteAllBytes($FlutterDll, $bytes)

$verified = [IO.File]::ReadAllBytes($FlutterDll)
$checks = @(
  @('WS2_32.dll', 0),
  @('ws2fix.dll', 1),
  @('ntdll.dll', 0),
  @('nt7fx.dll', 1)
)
foreach ($check in $checks) {
  $pattern = [Text.Encoding]::ASCII.GetBytes([string]$check[0])
  $count = (Find-PatternOffsets $verified $pattern).Count
  if ($count -ne [int]$check[1]) {
    throw "Post-patch validation failed for $($check[0]): expected $($check[1]), found $count."
  }
}

Write-Host 'Flutter Windows 7 import redirection validated.'
