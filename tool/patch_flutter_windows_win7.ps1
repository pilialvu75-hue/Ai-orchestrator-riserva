param(
  [Parameter(Mandatory = $true)]
  [string]$FlutterDll
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $FlutterDll)) {
  throw "Flutter engine DLL not found: $FlutterDll"
}

$oldName = [Text.Encoding]::ASCII.GetBytes('WS2_32.dll')
$newName = [Text.Encoding]::ASCII.GetBytes('ws2fix.dll')
if ($oldName.Length -ne $newName.Length) {
  throw 'Compatibility DLL name must have the same byte length as WS2_32.dll.'
}

$bytes = [IO.File]::ReadAllBytes($FlutterDll)

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

$oldOffsets = Find-PatternOffsets $bytes $oldName
$newOffsets = Find-PatternOffsets $bytes $newName

if ($oldOffsets.Count -eq 0 -and $newOffsets.Count -eq 1) {
  Write-Host 'Flutter Winsock import is already patched.'
  exit 0
}

if ($oldOffsets.Count -ne 1) {
  throw "Expected exactly one WS2_32.dll import string, found $($oldOffsets.Count)."
}
if ($newOffsets.Count -ne 0) {
  throw "Unexpected pre-existing ws2fix.dll string count: $($newOffsets.Count)."
}

$offset = $oldOffsets[0]
[Array]::Copy($newName, 0, $bytes, $offset, $newName.Length)
[IO.File]::WriteAllBytes($FlutterDll, $bytes)

$verified = [IO.File]::ReadAllBytes($FlutterDll)
$remainingOld = (Find-PatternOffsets $verified $oldName).Count
$patchedNew = (Find-PatternOffsets $verified $newName).Count
if ($remainingOld -ne 0 -or $patchedNew -ne 1) {
  throw "Post-patch validation failed: old=$remainingOld new=$patchedNew"
}

Write-Host "Patched Flutter engine import at byte offset $offset: WS2_32.dll -> ws2fix.dll"
