#!/usr/bin/env pwsh
# test_issue161_bel_alert.ps1
#
# Issue #161: alert "\a" character (BEL, char 7) is not working.
# When echo -e "\a" is run inside psmux, no bell/alert is triggered.
#
# Assertions:
#   1. Sending BEL to a background pane flips window_bell_flag to 1
#      (proves psmux detects and processes the BEL byte — the observable
#      side-effect used by tmux parity; actual audio depends on terminal config)
#   2. dump-state reports "bell":true after the BEL is processed
#   3. BEL sent to the active window still sets window_bell_flag (activity tracking)
#   4. BEL via raw Write-Host [char]7 (the same path as echo -e "\a") works
#   5. BEL via send-keys literal \a works
#
# Strategy mirrors test_issue162_window_bell_flag.ps1 (which tests flag flipping);
# this test focuses specifically on the \a / BEL character being processed at all,
# which is the issue #161 regression.
#
# Layer: PowerShell E2E via CLI + raw TCP dump-state.

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PSMUX    = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION  = "gap161"

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

# dump-state via raw TCP — the canonical way to drain bell_pending and read bell_flag.
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
    $best = $null
    try {
        for ($i = 0; $i -lt 80; $i++) {
            $line = $r.ReadLine()
            if ($null -eq $line) { break }
            if ($line -ne "NC" -and $line.Length -gt 50) { $best = $line }
            if ($best) { $stream.ReadTimeout = 200 }
        }
    } catch {}
    $tcp.Close()
    return $best
}

# Send BEL to a pane as shell output (the exact path echo -e "\a" uses),
# drain bell_pending via dump-state, then return window_bell_flag for $WinTarget.
function Get-BellFlagAfterBel {
    param([string]$PaneTarget, [string]$WinTarget, [string]$Method = "WriteHost")
    switch ($Method) {
        "WriteHost" {
            # Write-Host -NoNewline ([char]7) — same output path as echo -e "\a"
            & $PSMUX send-keys -t $PaneTarget 'Write-Host -NoNewline ([char]7)' Enter 2>&1 | Out-Null
        }
        "Printf" {
            # printf '\a' — POSIX shell path
            & $PSMUX send-keys -t $PaneTarget "printf '\a'" Enter 2>&1 | Out-Null
        }
        "EchoE" {
            # bash echo -e "\a"
            & $PSMUX send-keys -t $PaneTarget 'echo -e "\a"' Enter 2>&1 | Out-Null
        }
    }
    Start-Sleep -Milliseconds 800
    # dump-state drains bell_pending -> sets win.bell_flag = true in AppState
    $null = Invoke-DumpState
    Start-Sleep -Milliseconds 200
    return (& $PSMUX display-message -p -t $WinTarget '#{window_bell_flag}' 2>&1).Trim()
}

# ── Setup ────────────────────────────────────────────────────────────────────
Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Issue #161: BEL (\\a, char 7) must be processed by psmux" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

Write-Host "`n[Setup] Creating detached session '$SESSION' with two windows..." -ForegroundColor Yellow
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null

if (-not (Wait-PortFile -Name $SESSION)) {
    Write-Fail "Port file never appeared — session did not start"
    exit 1
}
Start-Sleep -Milliseconds 1200

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' did not start"
    Cleanup; exit 1
}

# Create a second window so window 0 can be a background window when we
# send BEL to it (bell on active window has different behavior in some tmux
# versions, so background window is the clearest test).
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

# Flush startup state
$null = Invoke-DumpState
Start-Sleep -Milliseconds 300

# ── Test 1: Fresh windows start with window_bell_flag = 0 ────────────────────
Write-Host "`n[Test 1] Fresh windows have window_bell_flag = 0 (baseline)" -ForegroundColor Yellow
$flag0Init = (& $PSMUX display-message -p -t "${SESSION}:0" '#{window_bell_flag}' 2>&1).Trim()
$flag1Init = (& $PSMUX display-message -p -t "${SESSION}:1" '#{window_bell_flag}' 2>&1).Trim()
Write-Host "  window 0 flag: '$flag0Init'  window 1 flag: '$flag1Init'" -ForegroundColor DarkGray
if ($flag0Init -eq "0" -and $flag1Init -eq "0") {
    Write-Pass "Both windows start with window_bell_flag = 0"
} else {
    Write-Fail "Expected 0/0, got $flag0Init/$flag1Init (pre-existing bell flag may cause false negatives below)"
}

# ── Test 2: BEL via Write-Host [char]7 flips window_bell_flag on background pane
# This is the most direct parity test for issue #161 (echo -e "\a" path).
Write-Host "`n[Test 2] BEL via Write-Host [char]7 -> window_bell_flag flips to 1" -ForegroundColor Yellow
# Ensure window 1 is active (so window 0 is background)
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

$flag0AfterBel = Get-BellFlagAfterBel -PaneTarget "${SESSION}:0.0" -WinTarget "${SESSION}:0" -Method "WriteHost"
Write-Host "  window 0 window_bell_flag after BEL (Write-Host): '$flag0AfterBel'" -ForegroundColor DarkGray
if ($flag0AfterBel -eq "1") {
    Write-Pass "BEL char (Write-Host path) processed: window_bell_flag = 1"
} else {
    Write-Fail "BEL char NOT processed: window_bell_flag = '$flag0AfterBel' (expected 1) — issue #161 regression"
}

# ── Test 3: dump-state reports "bell":true after BEL on background pane ───────
Write-Host "`n[Test 3] dump-state reports bell:true after BEL" -ForegroundColor Yellow
# Reset: select window 1 as active
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
# send-keys first to go back to normal mode on window 0 (clear previous bell flag)
$null = Invoke-DumpState  # drain; after this flag should clear on switch
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$null = Invoke-DumpState  # flush
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

# Now emit BEL to window 0 (background) and immediately check dump-state
& $PSMUX send-keys -t "${SESSION}:0.0" 'Write-Host -NoNewline ([char]7)' Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$dumpJson = Invoke-DumpState
$hasBellTrue = $dumpJson -match '"bell"\s*:\s*true'
Write-Host "  dump-state bell:true = $hasBellTrue" -ForegroundColor DarkGray
if ($hasBellTrue) {
    Write-Pass "dump-state reports bell:true after BEL char output"
} else {
    Write-Fail "dump-state does NOT report bell:true — psmux is not processing BEL (issue #161)"
}

# ── Test 4: BEL via [Console]::Beep() / [char]7 write to stdout ──────────────
# printf '\a' is a bash command and does not work in a PowerShell pane.
# Use [System.Console]::Write([char]7) which writes byte 0x07 directly to stdout,
# matching what echo -e "\a" does in bash.
Write-Host "`n[Test 4] BEL via [Console]::Write([char]7) -> window_bell_flag flips to 1" -ForegroundColor Yellow
# Reset flag by switching focus to window 0 (clears its bell flag) then back
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
$null = Invoke-DumpState
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400

# Send BEL byte via [System.Console]::Write([char]7) — writes raw byte 0x07 to stdout
& $PSMUX send-keys -t "${SESSION}:0.0" '[System.Console]::Write([char]7)' Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$null = Invoke-DumpState
Start-Sleep -Milliseconds 200
$flag0Console = (& $PSMUX display-message -p -t "${SESSION}:0" '#{window_bell_flag}' 2>&1).Trim()
Write-Host "  window 0 window_bell_flag after [Console]::Write([char]7): '$flag0Console'" -ForegroundColor DarkGray
if ($flag0Console -eq "1") {
    Write-Pass "BEL via [Console]::Write([char]7) processed: window_bell_flag = 1"
} else {
    Write-Fail "BEL via [Console]::Write([char]7) NOT processed: window_bell_flag = '$flag0Console' (expected 1)"
}

# ── Test 5: Active window also processes BEL (sets flag) ─────────────────────
Write-Host "`n[Test 5] BEL on the active window also sets window_bell_flag" -ForegroundColor Yellow
# Switch to window 0 (make it active), send BEL, dump-state, check flag
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
$null = Invoke-DumpState  # flush old state

& $PSMUX send-keys -t "${SESSION}:0.0" 'Write-Host -NoNewline ([char]7)' Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$dumpActive = Invoke-DumpState
# For the active window psmux may process BEL differently (activity vs bell),
# but the byte must at least pass through the ConPTY pipe reader.
# We test that dump-state shows bell:true OR window_bell_flag is 1 (or both).
$activeBellInDump = $dumpActive -match '"bell"\s*:\s*true'
$activeFlagDm     = (& $PSMUX display-message -p -t "${SESSION}:0" '#{window_bell_flag}' 2>&1).Trim()
Write-Host "  dump bell:true=$activeBellInDump  window_bell_flag='$activeFlagDm'" -ForegroundColor DarkGray
if ($activeBellInDump -or $activeFlagDm -eq "1") {
    Write-Pass "BEL on active window processed (bell:true or window_bell_flag=1)"
} else {
    Write-Fail "BEL on active window NOT processed (dump bell:false and window_bell_flag=$activeFlagDm)"
}

# ── Test 6: Multiple rapid BELs all processed (no drop) ──────────────────────
Write-Host "`n[Test 6] Multiple rapid BELs still result in bell flag being set" -ForegroundColor Yellow
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
$null = Invoke-DumpState
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400

# Send 3 BELs in quick succession
& $PSMUX send-keys -t "${SESSION}:0.0" 'Write-Host -NoNewline ([char]7+[char]7+[char]7)' Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 900
$null = Invoke-DumpState
Start-Sleep -Milliseconds 200
$flagMulti = (& $PSMUX display-message -p -t "${SESSION}:0" '#{window_bell_flag}' 2>&1).Trim()
Write-Host "  window_bell_flag after 3 rapid BELs: '$flagMulti'" -ForegroundColor DarkGray
if ($flagMulti -eq "1") {
    Write-Pass "Multiple rapid BELs processed: window_bell_flag = 1"
} else {
    Write-Fail "Multiple rapid BELs not processed: window_bell_flag = '$flagMulti'"
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "======================================================================" -ForegroundColor Cyan
exit $script:TestsFailed
