#!/usr/bin/env pwsh
# test_issue162_window_bell_flag.ps1
# Issue #162: window_bell_flag is 0 on a fresh window; flips to 1 after a BEL
# char is sent to a background pane; and clears back to 0 when the window is
# focused (matching tmux behavior).
#
# Key mechanism: bell_pending is a one-shot AtomicBool drained by
# check_window_activity (called during dump-state / list-windows / display-message).
# After that call sets win.bell_flag=true, subsequent display-message calls read
# the flag directly from AppState.  The correct assertion strategy is:
#   1. Send BEL to background pane
#   2. Issue ONE dump-state via TCP (drains bell_pending, sets win.bell_flag=true)
#   3. Query window_bell_flag via display-message (reads win.bell_flag directly)
# https://github.com/psmux/psmux/issues/162

$ErrorActionPreference = 'Continue'
$PSMUX    = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION  = "gap162"

$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-PortFile {
    param([string]$Name, [int]$TimeoutSec = 12)
    $portFile = "$psmuxDir\$Name.port"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $portFile) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# Send one dump-state via raw TCP; returns the JSON line and whether "bell":true appeared.
# This is the canonical way to trigger check_window_activity which sets win.bell_flag.
function Invoke-DumpState {
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw -EA Stop).Trim()
    $key  = (Get-Content "$psmuxDir\$SESSION.key"  -Raw -EA Stop).Trim()
    $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $w = [System.IO.StreamWriter]::new($stream); $w.AutoFlush = $true
    $r = [System.IO.StreamReader]::new($stream)
    $w.WriteLine("AUTH $key"); $null = $r.ReadLine()
    $w.WriteLine("dump-state")
    $stream.ReadTimeout = 6000
    try { $line = $r.ReadLine() } catch { $line = "" }
    $tcp.Close()
    return $line
}

# Send BEL as shell stdout to a pane, wait for it to arrive, then trigger
# check_window_activity via dump-state, and return window_bell_flag for $WinTarget.
function Get-BellFlagAfterBel {
    param([string]$PaneTarget, [string]$WinTarget)
    & $PSMUX send-keys -t $PaneTarget 'Write-Host -NoNewline ([char]7)' Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    # dump-state drains bell_pending and sets win.bell_flag=true in AppState
    $null = Invoke-DumpState
    Start-Sleep -Milliseconds 200
    # Now display-message reads win.bell_flag directly from AppState
    return (& $PSMUX display-message -p -t $WinTarget '#{window_bell_flag}' 2>&1).Trim()
}

Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Issue #162: window_bell_flag is 0 on fresh window, 1 after BEL" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# ── Setup ────────────────────────────────────────────────────────────────────
Write-Host "`n[Setup] Creating detached session '$SESSION'..." -ForegroundColor Yellow
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
if (-not (Wait-PortFile -Name $SESSION)) {
    Write-Fail "Port file never appeared — cannot continue"
    exit 1
}
Start-Sleep -Milliseconds 1000

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' did not start"
    Cleanup; exit 1
}

# ── Test 1: window_bell_flag is 0 on the initial window ─────────────────────
Write-Host "`n[Test 1] Fresh window has window_bell_flag = 0" -ForegroundColor Yellow
$null = Invoke-DumpState   # flush any startup state
$flagInit = (& $PSMUX display-message -p -t $SESSION '#{window_bell_flag}' 2>&1).Trim()
Write-Host "  window_bell_flag (initial): '$flagInit'" -ForegroundColor DarkGray
if ($flagInit -eq "0") {
    Write-Pass "window_bell_flag = 0 on fresh window (correct)"
} else {
    Write-Fail "window_bell_flag = '$flagInit' on fresh window (expected 0 — always-on bug may be present)"
}

# ── Test 2: open a second window and verify its bell_flag is also 0 ──────────
Write-Host "`n[Test 2] Second window also starts with window_bell_flag = 0" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$null = Invoke-DumpState
$flagW1Init = (& $PSMUX display-message -p -t "${SESSION}:1" '#{window_bell_flag}' 2>&1).Trim()
Write-Host "  window 1 window_bell_flag (initial): '$flagW1Init'" -ForegroundColor DarkGray
if ($flagW1Init -eq "0") {
    Write-Pass "Second window window_bell_flag = 0 (correct)"
} else {
    Write-Fail "Second window window_bell_flag = '$flagW1Init' (expected 0)"
}

# ── Test 3: send BEL to background window 0; flag on window 0 flips to 1 ─────
# We are currently on window 1 (active); send a BEL to window 0 (background).
Write-Host "`n[Test 3] Sending BEL to background window 0; window_bell_flag must flip to 1" -ForegroundColor Yellow
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

$flagW0AfterBell = Get-BellFlagAfterBel -PaneTarget "${SESSION}:0.0" -WinTarget "${SESSION}:0"
Write-Host "  window 0 window_bell_flag (after BEL + dump-state): '$flagW0AfterBell'" -ForegroundColor DarkGray
if ($flagW0AfterBell -eq "1") {
    Write-Pass "window_bell_flag = 1 on background window after BEL (correct)"
} else {
    Write-Fail "window_bell_flag = '$flagW0AfterBell' after BEL on background window (expected 1)"
}

# The active window (window 1) must NOT have its bell flag set
$flagW1AfterBell = (& $PSMUX display-message -p -t "${SESSION}:1" '#{window_bell_flag}' 2>&1).Trim()
Write-Host "  window 1 window_bell_flag (after BEL on window 0): '$flagW1AfterBell'" -ForegroundColor DarkGray
if ($flagW1AfterBell -eq "0") {
    Write-Pass "Active window 1 bell flag stays 0 (BEL only set on the target window)"
} else {
    Write-Fail "Active window 1 bell flag = '$flagW1AfterBell' (expected 0)"
}

# ── Test 4: dump-state itself shows "bell":true for the BEL event ─────────────
Write-Host "`n[Test 4] dump-state reports 'bell':true immediately after BEL output" -ForegroundColor Yellow
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t "${SESSION}:0.0" 'Write-Host -NoNewline ([char]7)' Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
$dumpJson = Invoke-DumpState
$hasBellTrue = $dumpJson -match '"bell"\s*:\s*true'
Write-Host "  dump-state contains 'bell':true = $hasBellTrue" -ForegroundColor DarkGray
if ($hasBellTrue) {
    Write-Pass "dump-state contains 'bell':true after BEL output on background pane"
} else {
    Write-Fail "dump-state did not contain 'bell':true (expected it after BEL output)"
}

# ── Test 5: switching to window 0 clears the bell flag ───────────────────────
Write-Host "`n[Test 5] Switching focus to window 0 clears window_bell_flag back to 0" -ForegroundColor Yellow
# bell_flag is now set on window 0 from test 4's BEL; switch to it
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$null = Invoke-DumpState  # triggers check_window_activity which clears bell_flag for active window
$flagW0AfterSwitch = (& $PSMUX display-message -p -t "${SESSION}:0" '#{window_bell_flag}' 2>&1).Trim()
Write-Host "  window 0 window_bell_flag (after focusing window 0): '$flagW0AfterSwitch'" -ForegroundColor DarkGray
if ($flagW0AfterSwitch -eq "0") {
    Write-Pass "window_bell_flag cleared to 0 after switching to the window (tmux parity)"
} else {
    Write-Fail "window_bell_flag = '$flagW0AfterSwitch' after switching (expected 0 — bell flag stuck bug may be present)"
}

# ── Test 6: list-windows format shows window_bell_flag correctly ──────────────
Write-Host "`n[Test 6] list-windows #{window_bell_flag} shows correct state after BEL" -ForegroundColor Yellow
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX send-keys -t "${SESSION}:0.0" 'Write-Host -NoNewline ([char]7)' Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
# dump-state triggers check_window_activity, setting win.bell_flag=true on window 0
$null = Invoke-DumpState
# list-windows now reads win.bell_flag directly from AppState
$lwOut = & $PSMUX list-windows -t $SESSION -F '#{window_index}|#{window_bell_flag}' 2>&1
Write-Host "  list-windows output:" -ForegroundColor DarkGray
$lwOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
$w0Line = $lwOut | Where-Object { $_ -match '^0\|' }
$w1Line = $lwOut | Where-Object { $_ -match '^1\|' }
$w0Flag = if ($w0Line) { ($w0Line -split '\|')[1].Trim() } else { "?" }
$w1Flag = if ($w1Line) { ($w1Line -split '\|')[1].Trim() } else { "?" }
Write-Host "  window 0 bell_flag=$w0Flag  window 1 bell_flag=$w1Flag" -ForegroundColor DarkGray
if ($w0Flag -eq "1" -and $w1Flag -eq "0") {
    Write-Pass "list-windows: window 0 bell_flag=1, window 1 bell_flag=0 (correct)"
} else {
    Write-Fail "list-windows: window 0 bell_flag=$w0Flag, window 1 bell_flag=$w1Flag (expected 1 and 0)"
}

# ── Test 7: bell flag clears via keyboard window switch (not just mouse) ──────
Write-Host "`n[Test 7] Bell flag clears when switching via select-window (keyboard path)" -ForegroundColor Yellow
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$null = Invoke-DumpState
$flagAfterKbSwitch = (& $PSMUX display-message -p -t "${SESSION}:0" '#{window_bell_flag}' 2>&1).Trim()
Write-Host "  window 0 window_bell_flag after select-window: '$flagAfterKbSwitch'" -ForegroundColor DarkGray
if ($flagAfterKbSwitch -eq "0") {
    Write-Pass "Bell flag cleared via select-window keyboard path (not just mouse click)"
} else {
    Write-Fail "Bell flag = '$flagAfterKbSwitch' after select-window (expected 0)"
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "======================================================================" -ForegroundColor Cyan
exit $script:TestsFailed
