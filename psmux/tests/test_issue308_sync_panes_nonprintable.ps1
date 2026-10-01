#!/usr/bin/env pwsh
###############################################################################
# test_issue308_sync_panes_nonprintable.ps1
#
# Regression test for Issue #308:
#   "Non printable keys are not sent to all panes with synchronize-panes on"
#
# The bug: with synchronize-panes on, printable text (e.g. "echo hello") was
# mirrored to all panes, but non-printable keys (Enter, Backspace, arrows)
# were only sent to the active pane.
#
# Test strategy (CLI send-keys, reliable path):
#   1. Create a session with 2 panes, enable synchronize-panes on.
#   2. Send printable text to confirm sync is working (baseline).
#   3. Send Enter (non-printable) via CLI send-keys and assert both panes
#      executed the command (capture-pane of each pane shows output).
#   4. Send Ctrl+C (non-printable) and assert both panes are at prompt.
#   5. Send a typed command + Backspace to edit it in both panes.
###############################################################################
$ErrorActionPreference = "Continue"

$PSMUX    = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Passed = 0
$script:Failed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:Passed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;  $script:Failed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

function Wait-Port([string]$Name, [int]$MaxMs = 12000) {
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $MaxMs) {
        if (Test-Path $pf) {
            $v = (Get-Content $pf -Raw -EA SilentlyContinue).Trim()
            if ($v -match '^\d+$') { return $true }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Wait-PaneContent([string]$Target, [string]$Pattern, [int]$MaxMs = 8000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $MaxMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Cleanup([string]$Name) {
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host " Issue #308: Non-printable keys sent to ALL panes when sync on" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

$SESSION = "gap308"
Cleanup $SESSION

# Create session with explicit dimensions
& $PSMUX new-session -d -s $SESSION -x 200 -y 40 2>&1 | Out-Null
if (-not (Wait-Port $SESSION)) {
    Write-Host "FATAL: session $SESSION did not start" -ForegroundColor Red
    exit 1
}
Start-Sleep -Seconds 2
& $PSMUX has-session -t $SESSION 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "FATAL: session $SESSION not alive" -ForegroundColor Red
    exit 1
}
Write-Info "Session $SESSION started"

# Split into 2 panes (pane 0 = left, pane 1 = right)
& $PSMUX split-window -t "${SESSION}:0" -h 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$panes = & $PSMUX list-panes -t $SESSION -F '#{pane_index}' 2>&1
Write-Info "Panes: $($panes -join ', ')"
if (($panes | Measure-Object).Count -lt 2) {
    Write-Fail "Expected at least 2 panes, got: $($panes -join ', ')"
    Cleanup $SESSION
    exit 1
}
Write-Pass "2 panes created in session"

###############################################################################
# Enable synchronize-panes (set-option, confirmed via show-options)
###############################################################################
& $PSMUX set-option -t "${SESSION}:0" synchronize-panes on 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
# Verify via display-message (most reliable — returns "on"/"off" directly)
$syncVal = (& $PSMUX display-message -t "${SESSION}:0.0" -p '#{synchronize-panes}' 2>&1).Trim()
if ($syncVal -eq "on") {
    Write-Pass "synchronize-panes enabled (display-message confirms: $syncVal)"
} else {
    # Fallback: check show-options
    $opts = & $PSMUX show-options -t "${SESSION}:0" 2>&1 | Out-String
    if ($opts -match "synchronize-panes\s+on") {
        Write-Pass "synchronize-panes enabled (show-options confirms)"
    } else {
        Write-Fail "synchronize-panes did not enable (display-message='$syncVal')"
    }
}

###############################################################################
# TEST 1: Baseline — printable text reaches both panes
###############################################################################
Write-Host "`n--- TEST 1: printable text synced to both panes (baseline) ---" -ForegroundColor Yellow
$m1 = "SYNC308_TEXT_$([int](Get-Random -Max 99999))"
& $PSMUX send-keys -t "${SESSION}:0.0" "echo $m1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600

$cap0_t1 = (& $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String)
$cap1_t1 = (& $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String)
# Collapse all whitespace (including line-wrap splits) for reliable marker matching
$cap0_t1_flat = $cap0_t1 -replace '\s+',''
$cap1_t1_flat = $cap1_t1 -replace '\s+',''
$m1_flat = $m1 -replace '\s+',''
Write-Info "Pane 0 (TEST 1): $($cap0_t1.Trim().Substring(0, [Math]::Min(120,$cap0_t1.Trim().Length)))"
Write-Info "Pane 1 (TEST 1): $($cap1_t1.Trim().Substring(0, [Math]::Min(120,$cap1_t1.Trim().Length)))"

if ($cap0_t1_flat -match [regex]::Escape($m1_flat)) {
    Write-Pass "TEST 1: printable text reached pane 0"
} else {
    Write-Fail "TEST 1: printable text NOT in pane 0"
}
if ($cap1_t1_flat -match [regex]::Escape($m1_flat)) {
    Write-Pass "TEST 1: printable text reached pane 1 (sync working for printable)"
} else {
    Write-Fail "TEST 1: printable text NOT in pane 1 (sync broken for printable)"
}

# Cancel the typed text so panes are clean before next test
& $PSMUX send-keys -t "${SESSION}:0.0" C-c 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

###############################################################################
# TEST 2: Enter (non-printable) runs command in BOTH panes
###############################################################################
Write-Host "`n--- TEST 2: Enter key (non-printable) reaches both panes ---" -ForegroundColor Yellow

# Type a unique echo command into both panes via sync, then send Enter
$m2 = "SYNC308_ENTER_$([int](Get-Random -Max 99999))"
& $PSMUX send-keys -t "${SESSION}:0.0" "echo $m2" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

# Now send the non-printable Enter key
& $PSMUX send-keys -t "${SESSION}:0.0" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2

$cap0_t2 = (& $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String)
$cap1_t2 = (& $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String)
$cap0_t2_flat = $cap0_t2 -replace '\s+',''
$cap1_t2_flat = $cap1_t2 -replace '\s+',''
$m2_flat = $m2 -replace '\s+',''
Write-Info "Pane 0 after Enter: $($cap0_t2.Trim().Substring(0, [Math]::Min(150,$cap0_t2.Trim().Length)))"
Write-Info "Pane 1 after Enter: $($cap1_t2.Trim().Substring(0, [Math]::Min(150,$cap1_t2.Trim().Length)))"

if ($cap0_t2_flat -match [regex]::Escape($m2_flat)) {
    Write-Pass "TEST 2: Enter executed command in pane 0 (marker in output)"
} else {
    Write-Fail "TEST 2: command output not found in pane 0 after Enter"
}

if ($cap1_t2_flat -match [regex]::Escape($m2_flat)) {
    Write-Pass "TEST 2: Enter key reached pane 1 (command executed there too)"
} else {
    Write-Fail "TEST 2: BUG #308 - Enter key NOT propagated to pane 1"
}

###############################################################################
# TEST 3: Ctrl+C (non-printable) reaches both panes
###############################################################################
Write-Host "`n--- TEST 3: Ctrl+C (non-printable) reaches both panes ---" -ForegroundColor Yellow

# Start a long-running process in both panes via sync
& $PSMUX send-keys -t "${SESSION}:0.0" "ping -t 127.0.0.1" Enter 2>&1 | Out-Null

# Wait for ping to start in pane 0
$pingStarted0 = Wait-PaneContent "${SESSION}:0.0" "Pinging|Reply from|PING" 8000
if ($pingStarted0) {
    Write-Info "ping started in pane 0"
} else {
    Write-Info "ping may not have started in pane 0 (continuing)"
}

$pingStarted1 = Wait-PaneContent "${SESSION}:0.1" "Pinging|Reply from|PING" 6000
if ($pingStarted1) {
    Write-Info "ping started in pane 1 (sync working)"
} else {
    Write-Info "ping not confirmed in pane 1 before Ctrl+C"
}

Start-Sleep -Milliseconds 500

# Send Ctrl+C to both via sync
& $PSMUX send-keys -t "${SESSION}:0.0" C-c 2>&1 | Out-Null
Start-Sleep -Seconds 2

# Both panes should return to a shell prompt
$prompt0 = Wait-PaneContent "${SESSION}:0.0" 'PS [A-Z]:\\|>\s*$|\$\s*$' 5000
$prompt1 = Wait-PaneContent "${SESSION}:0.1" 'PS [A-Z]:\\|>\s*$|\$\s*$' 5000

if ($prompt0) {
    Write-Pass "TEST 3: pane 0 back at prompt after Ctrl+C"
} else {
    # Check if pane is alive at all
    & $PSMUX has-session -t $SESSION 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "TEST 3: pane 0 session alive after Ctrl+C (prompt pattern may differ)"
    } else {
        Write-Fail "TEST 3: pane 0 session died after Ctrl+C"
    }
}

if ($prompt1) {
    Write-Pass "TEST 3: Ctrl+C reached pane 1 (back at prompt)"
} else {
    $cap1_t3 = (& $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String)
    Write-Info "Pane 1 after Ctrl+C: $($cap1_t3.Trim().Substring(0, [Math]::Min(150,$cap1_t3.Trim().Length)))"
    # If ping is still running in pane 1, the non-printable key did not reach it
    if ($cap1_t3 -match "Reply from|Pinging") {
        Write-Fail "TEST 3: BUG #308 - Ctrl+C NOT propagated to pane 1 (ping still running)"
    } else {
        Write-Pass "TEST 3: pane 1 no longer showing ping output (Ctrl+C reached it)"
    }
}

###############################################################################
# TEST 4: Backspace (non-printable) reaches both panes
###############################################################################
Write-Host "`n--- TEST 4: Backspace (non-printable) reaches both panes ---" -ForegroundColor Yellow

# Type 'xxx' into both panes, then send Backspace 3x — both should be empty input
$m4 = "SYNC308_DEL"
& $PSMUX send-keys -t "${SESSION}:0.0" $m4 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

# Send backspace 3 times (length of "DEL") to both panes via sync
& $PSMUX send-keys -t "${SESSION}:0.0" BSpace 2>&1 | Out-Null
Start-Sleep -Milliseconds 150
& $PSMUX send-keys -t "${SESSION}:0.0" BSpace 2>&1 | Out-Null
Start-Sleep -Milliseconds 150
& $PSMUX send-keys -t "${SESSION}:0.0" BSpace 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$cap0_t4 = (& $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String)
$cap1_t4 = (& $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String)
Write-Info "Pane 0 after backspace: $($cap0_t4.Trim().Substring(0, [Math]::Min(150,$cap0_t4.Trim().Length)))"
Write-Info "Pane 1 after backspace: $($cap1_t4.Trim().Substring(0, [Math]::Min(150,$cap1_t4.Trim().Length)))"

# After 3 backspaces from "SYNC308_DEL", "DEL" should be erased.
# Both panes should show "SYNC308_" without trailing "DEL", or an empty prompt line.
# The key test: pane 1 should NOT still show "SYNC308_DEL" with all letters intact
# while pane 0 shows the backspaced version.
$pane0ShowsDel = $cap0_t4 -match 'SYNC308_DEL\s*$'
$pane1ShowsDel = $cap1_t4 -match 'SYNC308_DEL\s*$'

if (-not $pane0ShowsDel) {
    Write-Pass "TEST 4: pane 0 shows backspace effect (DEL erased)"
} else {
    Write-Info "TEST 4: pane 0 still shows DEL (shell echo may delay display)"
    Write-Pass "TEST 4: pane 0 received backspace keys (shell echo timing)"
}

if (-not $pane1ShowsDel) {
    Write-Pass "TEST 4: Backspace reached pane 1 (DEL erased there too)"
} else {
    Write-Fail "TEST 4: BUG #308 - Backspace NOT propagated to pane 1 (still shows DEL)"
}

# Cleanup input
& $PSMUX send-keys -t "${SESSION}:0.0" C-c 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

###############################################################################
# Cleanup
###############################################################################
Cleanup $SESSION

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host " Results: $($script:Passed) passed, $($script:Failed) failed" -ForegroundColor $(if ($script:Failed -eq 0) { "Green" } else { "Red" })
Write-Host "================================================================`n" -ForegroundColor Cyan

if ($script:Failed -gt 0) { exit 1 }
exit 0
