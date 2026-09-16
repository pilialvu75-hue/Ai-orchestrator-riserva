param(
  [Parameter(Mandatory = $true)]
  [string]$RegistrantPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RegistrantPath)) {
  throw "Generated Windows plugin registrant not found: $RegistrantPath"
}

$marker = '// AI_ORCHESTRATOR_PLUGIN_TRACE_INSTRUMENTED'
$raw = Get-Content -Path $RegistrantPath -Raw
if ($raw.Contains($marker)) {
  Write-Host 'Windows plugin registrant is already instrumented.'
  exit 0
}

$lines = [System.Collections.Generic.List[string]]::new()
(Get-Content -Path $RegistrantPath) | ForEach-Object { [void]$lines.Add($_) }

$includeIndex = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^#include\s+"generated_plugin_registrant\.h"') {
    $includeIndex = $i
    break
  }
}
if ($includeIndex -lt 0) {
  throw 'Unable to locate generated_plugin_registrant.h include.'
}

$lines.Insert($includeIndex + 1, '#include "runner/startup_trace.h"')
$lines.Insert($includeIndex + 2, $marker)

$output = [System.Collections.Generic.List[string]]::new()
$currentRegistrar = $null
$registrarCount = 0

foreach ($line in $lines) {
  if ($null -eq $currentRegistrar -and
      $line -match '^\s*([A-Za-z_][A-Za-z0-9_]*RegisterWithRegistrar)\s*\(') {
    $currentRegistrar = $Matches[1]
    $registrarCount++
    [void]$output.Add(
      ('  startup_trace::Mark("PLUGIN before {0}");' -f $currentRegistrar)
    )
  }

  [void]$output.Add($line)

  if ($null -ne $currentRegistrar -and $line -match '\);\s*$') {
    [void]$output.Add(
      ('  startup_trace::Mark("PLUGIN after {0}");' -f $currentRegistrar)
    )
    $currentRegistrar = $null
  }
}

if ($null -ne $currentRegistrar) {
  throw "Registrant instrumentation ended inside call: $currentRegistrar"
}
if ($registrarCount -eq 0) {
  throw 'No Windows plugin registrar calls were found to instrument.'
}

Set-Content -Path $RegistrantPath -Value $output -Encoding utf8
Write-Host "Instrumented $registrarCount Windows plugin registrar call(s): $RegistrantPath"
