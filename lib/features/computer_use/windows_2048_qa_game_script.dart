/// A standalone offline 2048 game used only for user-authorized Windows QA.
///
/// It deliberately exposes its synthetic board via accessibility names on
/// buttons, so an agent can choose moves from actual observed game state.
/// Fixed source: NO external URLs, downloads, files, credentials or arguments.
const String kWindows2048QaGameScript = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:random = [System.Random]::new(20261112)
$script:board = @(0) * 16
$script:score = 0
$script:moves = 0
$script:gameOver = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AIVEXUS 2048 - Offline QA'
$form.AccessibleName = 'AIVEXUS 2048 offline QA game'
$form.Width = 500
$form.Height = 650
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.KeyPreview = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(250,248,239)

$headline = New-Object System.Windows.Forms.Label
$headline.Location = New-Object System.Drawing.Point(22, 13)
$headline.Size = New-Object System.Drawing.Size(445, 33)
$headline.Text = '2048 - AIVEXUS Computer Use test'
$headline.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($headline)

$script:scoreControl = New-Object System.Windows.Forms.Button
$script:scoreControl.Location = New-Object System.Drawing.Point(22, 52)
$script:scoreControl.Size = New-Object System.Drawing.Size(445, 46)
$script:scoreControl.TabStop = $false
$script:scoreControl.FlatStyle = 'Flat'
$form.Controls.Add($script:scoreControl)

$script:tileControls = New-Object 'System.Collections.Generic.List[System.Windows.Forms.Button]'
for ($index = 0; $index -lt 16; $index++) {
    $r = [int][Math]::Floor($index / 4)
    $c = $index % 4
    $tile = New-Object System.Windows.Forms.Button
    $tile.Location = New-Object System.Drawing.Point((22 + $c * 112), (113 + $r * 103))
    $tile.Size = New-Object System.Drawing.Size(104, 96)
    $tile.Font = New-Object System.Drawing.Font('Segoe UI', 19, [System.Drawing.FontStyle]::Bold)
    $tile.TabStop = $false
    $tile.FlatStyle = 'Flat'
    $tile.BackColor = [System.Drawing.Color]::FromArgb(205,193,180)
    $tile.UseVisualStyleBackColor = $false
    $form.Controls.Add($tile)
    $script:tileControls.Add($tile)
}

$help = New-Object System.Windows.Forms.Label
$help.Location = New-Object System.Drawing.Point(22, 534)
$help.Size = New-Object System.Drawing.Size(445, 25)
$help.Text = 'Arrow keys or the buttons below move the tiles. Target: 64.'
$form.Controls.Add($help)

function Add-GameTile {
    $free = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt 16; $i++) {
        if ([int]$script:board[$i] -eq 0) { $free.Add($i) }
    }
    if ($free.Count -eq 0) { return }
    $chosen = $free[$script:random.Next($free.Count)]
    $script:board[$chosen] = if ($script:random.Next(10) -eq 0) { 4 } else { 2 }
}

function Test-GameOver {
    for ($i = 0; $i -lt 16; $i++) {
        if ([int]$script:board[$i] -eq 0) { return $false }
        $r = [int][Math]::Floor($i / 4)
        $c = $i % 4
        if ($c -lt 3 -and $script:board[$i] -eq $script:board[$i + 1]) {
            return $false
        }
        if ($r -lt 3 -and $script:board[$i] -eq $script:board[$i + 4]) {
            return $false
        }
    }
    return $true
}

function Update-GameView {
    $highest = 0
    for ($i = 0; $i -lt 16; $i++) {
        $value = [int]$script:board[$i]
        if ($value -gt $highest) { $highest = $value }
        $row = [int][Math]::Floor($i / 4) + 1
        $col = ($i % 4) + 1
        $tile = $script:tileControls[$i]
        $tile.Text = if ($value -eq 0) { '' } else { [string]$value }
        $tile.AccessibleName = "2048 tile row $row column $col value $value"
        $shade = if ($value -eq 0) { 205 } else { [Math]::Max(130, 235 - [Math]::Log($value, 2) * 13) }
        $tile.BackColor = [System.Drawing.Color]::FromArgb([int]$shade, 193, 170)
    }
    $state = if ($script:gameOver) {
        'GAME OVER'
    } elseif ($highest -ge 64) {
        'TARGET 64 REACHED'
    } else {
        'PLAYING'
    }
    $script:scoreControl.Text = "Score: $($script:score) | Best: $highest | Moves: $($script:moves)"
    $script:scoreControl.AccessibleName = "2048 score $($script:score) best tile $highest moves $($script:moves) state $state"
}

function Move-Game([string]$direction) {
    if ($script:gameOver) { return }
    $before = @($script:board)
    for ($line = 0; $line -lt 4; $line++) {
        switch ($direction) {
            'left'  { $indices = @(0..3 | ForEach-Object { $line * 4 + $_ }) }
            'right' { $indices = @(3..0 | ForEach-Object { $line * 4 + $_ }) }
            'up'    { $indices = @(0..3 | ForEach-Object { $_ * 4 + $line }) }
            'down'  { $indices = @(3..0 | ForEach-Object { $_ * 4 + $line }) }
            default { return }
        }
        $values = New-Object 'System.Collections.Generic.List[int]'
        foreach ($index in $indices) {
            if ([int]$script:board[$index] -ne 0) {
                $values.Add([int]$script:board[$index])
            }
        }
        $merged = @(0) * 4
        $sourceIndex = 0
        $destination = 0
        while ($sourceIndex -lt $values.Count) {
            $value = [int]$values[$sourceIndex]
            if (($sourceIndex + 1) -lt $values.Count -and
                $value -eq [int]$values[$sourceIndex + 1]) {
                $value *= 2
                $script:score += $value
                $sourceIndex += 2
            } else {
                $sourceIndex++
            }
            $merged[$destination] = $value
            $destination++
        }
        for ($i = 0; $i -lt 4; $i++) {
            $script:board[$indices[$i]] = [int]$merged[$i]
        }
    }
    $changed = $false
    for ($i = 0; $i -lt 16; $i++) {
        if ($script:board[$i] -ne $before[$i]) {
            $changed = $true
            break
        }
    }
    if ($changed) {
        $script:moves++
        Add-GameTile
        $script:gameOver = Test-GameOver
    }
    Update-GameView
}

function Reset-Game {
    $script:random = [System.Random]::new(20261112)
    $script:board = @(0) * 16
    $script:score = 0
    $script:moves = 0
    $script:gameOver = $false
    Add-GameTile
    Add-GameTile
    Update-GameView
}

$directions = @(
    @{ label = 'LEFT'; name = 'left'; x = 22 },
    @{ label = 'DOWN'; name = 'down'; x = 130 },
    @{ label = 'UP'; name = 'up'; x = 238 },
    @{ label = 'RIGHT'; name = 'right'; x = 346 }
)
foreach ($direction in $directions) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = [string]$direction.label
    $button.AccessibleName = "2048 move $($direction.name)"
    $button.Location = New-Object System.Drawing.Point([int]$direction.x, 560)
    $button.Size = New-Object System.Drawing.Size(100, 35)
    $button.Tag = [string]$direction.name
    $button.Add_Click({
        param($sender, $e)
        Move-Game ([string]$sender.Tag)
    })
    $form.Controls.Add($button)
}

$form.Add_KeyDown({
    param($sender, $e)
    switch ($e.KeyCode) {
        'Left'  { Move-Game 'left';  $e.Handled = $true }
        'Right' { Move-Game 'right'; $e.Handled = $true }
        'Up'    { Move-Game 'up';    $e.Handled = $true }
        'Down'  { Move-Game 'down';  $e.Handled = $true }
    }
    if ($e.Handled) { $e.SuppressKeyPress = $true }
})

Reset-Game
[System.Windows.Forms.Application]::Run($form)
''';
