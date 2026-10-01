$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

$bin = "$env:TEMP\psmux253_bin"
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$marker = "$env:TEMP\psmux253_marker.txt"
Remove-Item $marker -Force -EA SilentlyContinue

# tech-pass.bat marker program
@"
@echo off
echo TECHPASS_RAN_MARKER > "$marker"
echo TECH-PASS PROGRAM STARTED
ping -n 60 127.0.0.1 > nul
"@ | Set-Content "$bin\tech-pass.bat" -Encoding ASCII

function Test-Scenario {
    param([string]$Name, [scriptblock]$Block)
    $SESSION = "issue253_$Name"
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item $marker -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 800

    Write-Host "`n=== SCENARIO: $Name ===" -ForegroundColor Cyan
    & $Block $SESSION
    Start-Sleep -Seconds 4

    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    Write-Host "PANE CAPTURE:" -ForegroundColor Yellow
    Write-Host $cap
    $markerExists = Test-Path $marker
    Write-Host "Marker file present: $markerExists"
    if ($markerExists) { Write-Host "Marker: $(Get-Content $marker)" }
    $paneCmd = (& $PSMUX display-message -t $SESSION -p '#{pane_current_command}' 2>&1) -join ''
    Write-Host "pane_current_command: $paneCmd"
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    return @{ Marker=$markerExists; Cap=$cap; PaneCmd=$paneCmd }
}

# Scenario 1: as in issue (using `new` alias and `--`)
$r1 = Test-Scenario "alias_dashdash" {
    param($s)
    & $PSMUX new -s $s -d -- cmd /c "$bin\tech-pass.bat"
}

# Scenario 2: full new-session, no --
$r2 = Test-Scenario "newsession_no_dashdash" {
    param($s)
    & $PSMUX new-session -s $s -d cmd /c "$bin\tech-pass.bat"
}

# Scenario 3: new-session with --
$r3 = Test-Scenario "newsession_dashdash" {
    param($s)
    & $PSMUX new-session -s $s -d -- cmd /c "$bin\tech-pass.bat"
}

# Scenario 4: shell-command as single quoted string
$r4 = Test-Scenario "newsession_quoted" {
    param($s)
    & $PSMUX new-session -s $s -d "cmd /c $bin\tech-pass.bat"
}

Write-Host "`n=== SUMMARY ===" -ForegroundColor Magenta
"alias_dashdash:        marker=$($r1.Marker) paneCmd=$($r1.PaneCmd)" | Write-Host
"newsession_no_dashdash:marker=$($r2.Marker) paneCmd=$($r2.PaneCmd)" | Write-Host
"newsession_dashdash:   marker=$($r3.Marker) paneCmd=$($r3.PaneCmd)" | Write-Host
"newsession_quoted:     marker=$($r4.Marker) paneCmd=$($r4.PaneCmd)" | Write-Host
