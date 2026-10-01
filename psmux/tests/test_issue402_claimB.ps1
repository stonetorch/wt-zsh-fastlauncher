# Issue #402 Claim B: new-window with trailing PowerShell command string
# Reporter says: new-window -n X -c DIR "pwsh -NoExit -Command '...'"
# produces a broken "text pad" pane: typeable, shows in capture-pane, but NO shell prompt,
# yet list-panes reports live pwsh.
# This test creates such windows and inspects the resulting pane state via capture-pane + list-panes.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue402B"
$psmuxDir = "$env:USERPROFILE\.psmux"
$DIR = "$env:USERPROFILE\psmux_test402\project"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Cleanup
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

Write-Host "`n=== Issue #402 Claim B: trailing pwsh command string ===" -ForegroundColor Cyan

# --- Baseline: plain new-window (reporter says this WORKS) ---
Write-Host "`n[Baseline] plain new-window -c DIR (no trailing command)" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION -n "plain" -c $DIR 2>&1 | Out-Null
Start-Sleep -Seconds 3
$capPlain = & $PSMUX capture-pane -p -t "${SESSION}:plain" 2>&1 | Out-String
Write-Info "capture of plain pane:"
$capPlain -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Host "      | $_" } }
if ($capPlain -match "PS ") { Write-Pass "Baseline plain pane HAS a PowerShell prompt (PS ...)" }
else { Write-Fail "Baseline plain pane has NO prompt (unexpected)" }

# --- TEST 1: new-window with trailing "pwsh -NoExit -Command '...'" ---
Write-Host "`n[Test 1] new-window -n Research_Pi -c DIR ""pwsh -NoExit -Command '...marker...'""" -ForegroundColor Yellow
$trailingCmd = "pwsh -NoExit -Command 'Start-Sleep -Milliseconds 500; Write-Host PIMARKER402'"
& $PSMUX new-window -t $SESSION -n "Research_Pi" -c $DIR $trailingCmd 2>&1 | Out-Null
Start-Sleep -Seconds 4

# What does list-panes report?
$panes = & $PSMUX list-panes -t $SESSION -a -F 'win=#{window_name} cmd=#{pane_current_command} dead=#{pane_dead} pid=#{pane_pid}' 2>&1 | Out-String
Write-Info "list-panes -a:"
$panes -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Host "      | $_" } }

$capR = & $PSMUX capture-pane -p -t "${SESSION}:Research_Pi" 2>&1 | Out-String
Write-Info "capture of Research_Pi pane:"
$capR -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Host "      | $_" } }

# The KEY question: did pwsh actually run the command (marker present) or is the pane broken?
if ($capR -match "PIMARKER402") {
    Write-Pass "Trailing pwsh command EXECUTED (PIMARKER402 present) - pane is functional"
} elseif ($capR -match "PS ") {
    Write-Info "Pane shows a prompt but marker not (yet) visible"
    Write-Fail "Marker PIMARKER402 not found - command may not have run as intended"
} else {
    Write-Fail "BROKEN PANE REPRODUCED: no marker, no prompt - matches reporter's 'text pad' symptom"
}

# Is the pane reported alive?
$rDead = (& $PSMUX display-message -p -t "${SESSION}:Research_Pi" '#{pane_dead}' 2>&1).Trim()
$rCmd = (& $PSMUX display-message -p -t "${SESSION}:Research_Pi" '#{pane_current_command}' 2>&1).Trim()
Write-Info "Research_Pi pane_dead=$rDead pane_current_command=$rCmd"

# --- TEST 2: What does psmux think the trailing arg parsed into? ---
# Reproduce the "type into it and it shows in capture-pane" claim.
Write-Host "`n[Test 2] Type free text into the Research_Pi pane, check capture-pane" -ForegroundColor Yellow
& $PSMUX send-keys -t "${SESSION}:Research_Pi" "This page is just a text page" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$capType = & $PSMUX capture-pane -p -t "${SESSION}:Research_Pi" 2>&1 | Out-String
Write-Info "capture after typing:"
$capType -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Host "      | $_" } }
if ($capType -match "This page is just a text page") {
    Write-Info "Typed text appears in capture (this is normal terminal echo IF a shell is reading it)"
}

# --- TEST 3: Simpler trailing command (no nested quotes) ---
Write-Host "`n[Test 3] new-window with trailing command, NO nested quotes" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION -n "simple_cmd" -c $DIR "pwsh -NoExit" 2>&1 | Out-Null
Start-Sleep -Seconds 4
$capS = & $PSMUX capture-pane -p -t "${SESSION}:simple_cmd" 2>&1 | Out-String
Write-Info "capture of simple_cmd pane (pwsh -NoExit):"
$capS -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Host "      | $_" } }
if ($capS -match "PS ") { Write-Pass "pwsh -NoExit trailing command shows a prompt" }
else { Write-Fail "pwsh -NoExit trailing command shows NO prompt" }

Cleanup
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
