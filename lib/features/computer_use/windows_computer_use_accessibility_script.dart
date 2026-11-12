/// Fixed, read-only PowerShell UI Automation script used solely for LOCAL QA.
/// It never reads ValuePattern/TextPattern or modifies the desktop.
const String kWindowsUiAutomationSnapshotScript = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$root = [System.Windows.Automation.AutomationElement]::FromHandle(
    [IntPtr]__HANDLE__)
if ($null -eq $root) { throw 'Selected accessibility window is missing' }
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$queue = New-Object System.Collections.Queue
$queue.Enqueue(@{ node = $root; depth = 0 })
$items = New-Object 'System.Collections.Generic.List[string]'
$sensitive = $false
$truncated = $false
$scanned = 0
while ($queue.Count -gt 0 -and $scanned -lt 64) {
    $entry = $queue.Dequeue()
    $node = $entry.node
    $depth = [int]$entry.depth
    $scanned++
    try {
        $info = $node.Current
        if ($info.IsPassword) {
            $sensitive = $true
            break
        }
        $type = $info.ControlType.ProgrammaticName
        # Edit, Text and Document Name may include private document data.
        $hideName = $type -match '\.(Edit|Text|Document)$'
        $name = if ($hideName) { '[content hidden]' } else { $info.Name }
        if (-not $hideName -and $name -match '(?i)(password|passcode|credit.card|card.number|bank.account|security.code|two.factor|verification.code)') {
            $sensitive = $true
            break
        }
        $name = [string]$name
        $name = $name.Replace([char]10, ' ').Replace([char]13, ' ')
        if ($name.Length -gt 64) { $name = $name.Substring(0, 64) }
        $rect = $info.BoundingRectangle
        if ($rect.Width -gt 0 -and $rect.Height -gt 0 -and
            -not [double]::IsInfinity($rect.X) -and
            -not [double]::IsInfinity($rect.Y)) {
            $x = [int][Math]::Round($rect.X)
            $y = [int][Math]::Round($rect.Y)
            [void]$items.Add("$type ($x,$y) $name")
        }
    } catch {
        # An unreadable control might itself be a sensitive field.
        $sensitive = $true
        break
    }
    if ($depth -ge 3) { continue }
    $child = $null
    try { $child = $walker.GetFirstChild($node) }
    catch { $sensitive = $true; break }
    $siblings = 0
    while ($null -ne $child -and $siblings -lt 64 -and
           ($scanned + $queue.Count) -lt 64) {
        $queue.Enqueue(@{ node = $child; depth = ($depth + 1) })
        $siblings++
        try { $child = $walker.GetNextSibling($child) }
        catch { $sensitive = $true; break }
    }
    if ($null -ne $child) { $truncated = $true }
    if ($sensitive) { break }
}
# Partial trees cannot prove the absence of credential fields.
if ($queue.Count -gt 0 -or $truncated) { $sensitive = $true }
if ($sensitive) {
    [pscustomobject]@{ sensitive = $true; description = '' } |
        ConvertTo-Json -Compress
} else {
    [pscustomobject]@{
        sensitive = $false
        description = ($items -join [Environment]::NewLine)
    } | ConvertTo-Json -Compress
}
''';
