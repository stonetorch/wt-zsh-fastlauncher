#!/usr/bin/env pwsh
# test_issue152_copy_mode.ps1
#
# Issue #152: psmux v3.3.0 copy mode stopped working — can enter copy-mode
# but cannot select anything; can exit though.
#
# Assertions:
#   1. copy-mode can be entered (pane_in_mode = 1, dump-state copy_mode:true)
#   2. Cursor navigation works (copy_cursor_x / copy_cursor_y change)
#   3. Selection can be started (send-keys -X begin-selection)
#   4. copy-mode can be exited cleanly (pane_in_mode = 0)
#   5. dump-state copy_mode:false after exit
#
# Layer: PowerShell E2E via CLI + raw TCP dump-state.

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PSMUX    = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION  = "gap152"

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

function Query-Format {
    param([string]$Fmt)
    return (& $PSMUX display-message -t $SESSION -p $Fmt 2>&1 | Out-String).Trim()
}

# ── Setup ────────────────────────────────────────────────────────────────────
Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Issue #152: copy-mode enter / navigate / select / exit" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

Write-Host "`n[Setup] Creating detached session '$SESSION'..." -ForegroundColor Yellow
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

# Seed the scrollback with known text so the cursor has content to navigate over.
& $PSMUX send-keys -t $SESSION "echo line_one_alpha" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $SESSION "echo line_two_beta" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $SESSION "echo line_three_gamma" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ── Test 1: Enter copy-mode; pane_in_mode = 1 ────────────────────────────────
Write-Host "`n[Test 1] Enter copy-mode -> pane_in_mode must be 1" -ForegroundColor Yellow
& $PSMUX copy-mode -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$inMode = Query-Format "#{pane_in_mode}"
Write-Host "  pane_in_mode: '$inMode'" -ForegroundColor DarkGray
if ($inMode -eq "1") {
    Write-Pass "copy-mode entered (pane_in_mode = 1)"
} else {
    Write-Fail "copy-mode NOT entered (pane_in_mode = '$inMode', expected 1)"
}

# ── Test 2: dump-state shows copy_mode:true ──────────────────────────────────
Write-Host "`n[Test 2] dump-state must report copy_mode:true while in copy-mode" -ForegroundColor Yellow
$state = Invoke-DumpState
$hasCopyModeTrue = $state -match '"copy_mode"\s*:\s*true'
Write-Host "  dump-state copy_mode:true = $hasCopyModeTrue" -ForegroundColor DarkGray
if ($hasCopyModeTrue) {
    Write-Pass "dump-state shows copy_mode:true"
} else {
    Write-Fail "dump-state does NOT show copy_mode:true (copy-mode may not be active)"
}

# ── Test 3: Cursor navigation works (j/k change copy_cursor_y) ───────────────
Write-Host "`n[Test 3] Cursor navigation (j/k) changes copy_cursor_y" -ForegroundColor Yellow
# Move to top of scrollback first
& $PSMUX send-keys -t $SESSION -X top-line 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

$yBefore = Query-Format "#{copy_cursor_y}"
Write-Host "  copy_cursor_y before j: '$yBefore'" -ForegroundColor DarkGray

# Move down
& $PSMUX send-keys -t $SESSION j 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$yAfterJ = Query-Format "#{copy_cursor_y}"
Write-Host "  copy_cursor_y after j:  '$yAfterJ'" -ForegroundColor DarkGray

if ([int]$yAfterJ -gt [int]$yBefore) {
    Write-Pass "j moved cursor down: $yBefore -> $yAfterJ"
} else {
    Write-Fail "j did NOT move cursor down (y before=$yBefore, after=$yAfterJ) — navigation broken (issue #152 symptom)"
}

# Move back up
& $PSMUX send-keys -t $SESSION k 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$yAfterK = Query-Format "#{copy_cursor_y}"
Write-Host "  copy_cursor_y after k:  '$yAfterK'" -ForegroundColor DarkGray

if ([int]$yAfterK -lt [int]$yAfterJ) {
    Write-Pass "k moved cursor up: $yAfterJ -> $yAfterK"
} else {
    Write-Fail "k did NOT move cursor up (y before=$yAfterJ, after=$yAfterK)"
}

# ── Test 4: Horizontal navigation (h/l changes copy_cursor_x) ────────────────
Write-Host "`n[Test 4] Cursor navigation (h/l) changes copy_cursor_x" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION 0 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$xAtBol = Query-Format "#{copy_cursor_x}"
Write-Host "  copy_cursor_x at BOL: '$xAtBol'" -ForegroundColor DarkGray

& $PSMUX send-keys -t $SESSION l 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $SESSION l 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$xAfterLL = Query-Format "#{copy_cursor_x}"
Write-Host "  copy_cursor_x after ll: '$xAfterLL'" -ForegroundColor DarkGray

if ([int]$xAfterLL -gt [int]$xAtBol) {
    Write-Pass "l moved cursor right: $xAtBol -> $xAfterLL"
} else {
    Write-Fail "l did NOT move cursor right (x=$xAtBol -> $xAfterLL)"
}

& $PSMUX send-keys -t $SESSION h 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$xAfterH = Query-Format "#{copy_cursor_x}"
Write-Host "  copy_cursor_x after h: '$xAfterH'" -ForegroundColor DarkGray

if ([int]$xAfterH -lt [int]$xAfterLL) {
    Write-Pass "h moved cursor left: $xAfterLL -> $xAfterH"
} else {
    Write-Fail "h did NOT move cursor left (x=$xAfterLL -> $xAfterH)"
}

# ── Test 5: Selection can be started (begin-selection) ───────────────────────
Write-Host "`n[Test 5] begin-selection activates selection mode" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION 0 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $SESSION -X begin-selection 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Move a few chars to extend selection
& $PSMUX send-keys -t $SESSION l 2>&1 | Out-Null
Start-Sleep -Milliseconds 200
& $PSMUX send-keys -t $SESSION l 2>&1 | Out-Null
Start-Sleep -Milliseconds 200
& $PSMUX send-keys -t $SESSION l 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

# pane_in_mode should still be 1 (still in copy-mode with selection active)
$inModeWhileSelecting = Query-Format "#{pane_in_mode}"
Write-Host "  pane_in_mode while selecting: '$inModeWhileSelecting'" -ForegroundColor DarkGray

$xWhileSelecting = Query-Format "#{copy_cursor_x}"
Write-Host "  copy_cursor_x while selecting: '$xWhileSelecting'" -ForegroundColor DarkGray

if ($inModeWhileSelecting -eq "1") {
    Write-Pass "Selection active: still in copy-mode (pane_in_mode = 1)"
} else {
    Write-Fail "copy-mode exited unexpectedly during selection (pane_in_mode = '$inModeWhileSelecting')"
}

# Cancel selection
& $PSMUX send-keys -t $SESSION -X clear-selection 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

# ── Test 6: Exit copy-mode with q -> pane_in_mode = 0 ────────────────────────
Write-Host "`n[Test 6] Exit copy-mode with q -> pane_in_mode must be 0" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION q 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$inModeAfterQ = Query-Format "#{pane_in_mode}"
Write-Host "  pane_in_mode after q: '$inModeAfterQ'" -ForegroundColor DarkGray
if ($inModeAfterQ -eq "0") {
    Write-Pass "copy-mode exited with q (pane_in_mode = 0)"
} else {
    Write-Fail "copy-mode NOT exited after q (pane_in_mode = '$inModeAfterQ')"
}

# ── Test 7: dump-state shows copy_mode:false after exit ──────────────────────
Write-Host "`n[Test 7] dump-state must report copy_mode:false after exit" -ForegroundColor Yellow
$state2 = Invoke-DumpState
$hasCopyModeFalse = $state2 -match '"copy_mode"\s*:\s*false'
Write-Host "  dump-state copy_mode:false = $hasCopyModeFalse" -ForegroundColor DarkGray
if ($hasCopyModeFalse) {
    Write-Pass "dump-state shows copy_mode:false after exit"
} else {
    Write-Fail "dump-state does NOT show copy_mode:false after exit"
}

# ── Test 8: Re-enter copy-mode and exit via Escape ───────────────────────────
Write-Host "`n[Test 8] Re-enter copy-mode; exit via Escape -> pane_in_mode = 0" -ForegroundColor Yellow
& $PSMUX copy-mode -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$inModeReentry = Query-Format "#{pane_in_mode}"
Write-Host "  pane_in_mode after re-entry: '$inModeReentry'" -ForegroundColor DarkGray

& $PSMUX send-keys -t $SESSION Escape 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$inModeAfterEsc = Query-Format "#{pane_in_mode}"
Write-Host "  pane_in_mode after Escape: '$inModeAfterEsc'" -ForegroundColor DarkGray

if ($inModeReentry -eq "1" -and $inModeAfterEsc -eq "0") {
    Write-Pass "copy-mode re-entry and Escape exit both work"
} elseif ($inModeReentry -ne "1") {
    Write-Fail "copy-mode re-entry failed (pane_in_mode = '$inModeReentry')"
} else {
    Write-Fail "Escape did not exit copy-mode (pane_in_mode = '$inModeAfterEsc')"
}

# ── Test 9: copy-mode -u (PageUp variant) enters copy-mode at top ────────────
Write-Host "`n[Test 9] copy-mode -u enters copy-mode scrolled to top" -ForegroundColor Yellow
& $PSMUX copy-mode -u -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$inModeU = Query-Format "#{pane_in_mode}"
Write-Host "  pane_in_mode after copy-mode -u: '$inModeU'" -ForegroundColor DarkGray
if ($inModeU -eq "1") {
    Write-Pass "copy-mode -u entered copy-mode"
} else {
    Write-Fail "copy-mode -u failed to enter copy-mode (pane_in_mode = '$inModeU')"
}
& $PSMUX send-keys -t $SESSION q 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ── Cleanup ──────────────────────────────────────────────────────────────────
Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "======================================================================" -ForegroundColor Cyan
exit $script:TestsFailed
