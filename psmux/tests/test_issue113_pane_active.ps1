#!/usr/bin/env pwsh
# test_issue113_pane_active.ps1
# Issue #113: display-message -t <pane> reports correct #{pane_active} for the TARGETED pane
# https://github.com/psmux/psmux/issues/113
#
# Assertion: after a horizontal split, querying each pane by its %id via display-message -t
# returns pane_active=0 for the inactive pane and pane_active=1 for the active pane.

$ErrorActionPreference = 'Continue'
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "gap113"

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

Cleanup
# Kill any leftover server state so warm-pool pane IDs do not bleed across runs
& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Issue #113: display-message -t reports correct pane_active per pane" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# ── Setup: create detached session ──────────────────────────────────────────
Write-Host "`n[Setup] Creating detached session '$SESSION'..." -ForegroundColor Yellow
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
if (-not (Wait-PortFile -Name $SESSION)) {
    Write-Fail "Session '$SESSION' port file never appeared — cannot continue"
    exit 1
}
Start-Sleep -Milliseconds 800

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' did not start"
    Cleanup; exit 1
}

# ── Split into two panes ─────────────────────────────────────────────────────
# After split-window -h the new right pane gets focus (active=1), original left pane is inactive (active=0)
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 1000

# ── Test 1: list-panes shows exactly one active pane ────────────────────────
Write-Host "`n[Test 1] list-panes confirms exactly one pane is active" -ForegroundColor Yellow
$lp = & $PSMUX list-panes -t $SESSION -F '#{pane_id}|#{pane_active}' 2>&1
Write-Host "  list-panes output:" -ForegroundColor DarkGray
$lp | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

$activeCount = ($lp | Where-Object { $_ -match '\|1$' }).Count
$inactiveCount = ($lp | Where-Object { $_ -match '\|0$' }).Count
if ($activeCount -eq 1 -and $inactiveCount -eq 1) {
    Write-Pass "list-panes: 1 active, 1 inactive (correct split state)"
} else {
    Write-Fail "list-panes: expected 1 active + 1 inactive, got active=$activeCount inactive=$inactiveCount"
}

# ── Collect pane IDs from list-panes ────────────────────────────────────────
$paneLines = $lp | Where-Object { $_ -match '^%\d+\|[01]$' }
$activeLine   = $paneLines | Where-Object { $_ -match '\|1$' }
$inactiveLine = $paneLines | Where-Object { $_ -match '\|0$' }

$activePaneId   = if ($activeLine)   { ($activeLine   -split '\|')[0].Trim() } else { $null }
$inactivePaneId = if ($inactiveLine) { ($inactiveLine -split '\|')[0].Trim() } else { $null }

Write-Host "  Active pane id:   $activePaneId" -ForegroundColor DarkGray
Write-Host "  Inactive pane id: $inactivePaneId" -ForegroundColor DarkGray

if (-not $activePaneId -or -not $inactivePaneId) {
    Write-Fail "Could not parse pane IDs from list-panes output — remaining tests skipped"
    Cleanup; exit $script:TestsFailed
}

# ── Test 2: display-message -t <active pane id> reports pane_active=1 ───────
Write-Host "`n[Test 2] display-message -t $activePaneId reports pane_active=1" -ForegroundColor Yellow
$activeResult = (& $PSMUX display-message -p -t $activePaneId '#{pane_id}|#{pane_active}' 2>&1).Trim()
Write-Host "  Result: $activeResult" -ForegroundColor DarkGray
if ($activeResult -match '\|1$') {
    Write-Pass "display-message -t $activePaneId => pane_active=1 (correct)"
} else {
    Write-Fail "display-message -t $activePaneId => '$activeResult' (expected pane_active=1)"
}

# ── Test 3: display-message -t <inactive pane id> reports pane_active=0 ─────
Write-Host "`n[Test 3] display-message -t $inactivePaneId reports pane_active=0" -ForegroundColor Yellow
$inactiveResult = (& $PSMUX display-message -p -t $inactivePaneId '#{pane_id}|#{pane_active}' 2>&1).Trim()
Write-Host "  Result: $inactiveResult" -ForegroundColor DarkGray
if ($inactiveResult -match '\|0$') {
    Write-Pass "display-message -t $inactivePaneId => pane_active=0 (correct)"
} else {
    Write-Fail "display-message -t $inactivePaneId => '$inactiveResult' (expected pane_active=0)"
}

# ── Test 4: pane_index is resolved correctly alongside pane_active ───────────
Write-Host "`n[Test 4] pane_index is also correct when queried via -t pane-id" -ForegroundColor Yellow
$idxActive   = (& $PSMUX display-message -p -t $activePaneId   '#{pane_index}' 2>&1).Trim()
$idxInactive = (& $PSMUX display-message -p -t $inactivePaneId '#{pane_index}' 2>&1).Trim()
Write-Host "  $activePaneId pane_index=$idxActive  |  $inactivePaneId pane_index=$idxInactive" -ForegroundColor DarkGray
if ($idxActive -ne $idxInactive -and $idxActive -match '^\d+$' -and $idxInactive -match '^\d+$') {
    Write-Pass "pane_index: $activePaneId=$idxActive and $inactivePaneId=$idxInactive (distinct, numeric)"
} else {
    Write-Fail "pane_index mismatch: $activePaneId=$idxActive $inactivePaneId=$idxInactive"
}

# ── Test 5: querying the inactive pane does NOT steal focus ──────────────────
Write-Host "`n[Test 5] display-message -t inactive pane does not steal active focus" -ForegroundColor Yellow
$focusBefore = (& $PSMUX display-message -p -t $SESSION '#{pane_id}' 2>&1).Trim()
$null = (& $PSMUX display-message -p -t $inactivePaneId '#{pane_active}' 2>&1)
$focusAfter  = (& $PSMUX display-message -p -t $SESSION '#{pane_id}' 2>&1).Trim()
Write-Host "  Focus before: $focusBefore  after: $focusAfter" -ForegroundColor DarkGray
if ($focusBefore -eq $focusAfter) {
    Write-Pass "Focus unchanged after querying inactive pane (focus stayed on $focusAfter)"
} else {
    Write-Fail "Focus changed from $focusBefore to $focusAfter after display-message -t inactive pane"
}

# ── Test 6: three-pane scenario — only one active ────────────────────────────
Write-Host "`n[Test 6] Three-pane scenario: exactly one pane active" -ForegroundColor Yellow
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$lp3 = & $PSMUX list-panes -t $SESSION -F '#{pane_id}|#{pane_active}' 2>&1
$lp3 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
$active3   = ($lp3 | Where-Object { $_ -match '\|1$' }).Count
$inactive3 = ($lp3 | Where-Object { $_ -match '\|0$' }).Count
if ($active3 -eq 1 -and $inactive3 -eq 2) {
    Write-Pass "Three panes: exactly 1 active, 2 inactive"
} else {
    Write-Fail "Three panes: expected 1 active + 2 inactive, got active=$active3 inactive=$inactive3"
}

# Verify display-message agrees with list-panes for all three panes
$lp3Lines = $lp3 | Where-Object { $_ -match '^%\d+\|[01]$' }
$allMatch = $true
foreach ($line in $lp3Lines) {
    $parts    = $line.Trim() -split '\|'
    $pid3     = $parts[0]
    $expected = $parts[1]
    $dmResult = (& $PSMUX display-message -p -t $pid3 '#{pane_active}' 2>&1).Trim()
    if ($dmResult -ne $expected) {
        Write-Host "    display-message -t $pid3 returned '$dmResult', list-panes says '$expected'" -ForegroundColor DarkGray
        $allMatch = $false
    }
}
if ($allMatch) {
    Write-Pass "display-message pane_active agrees with list-panes for all 3 panes"
} else {
    Write-Fail "display-message pane_active disagrees with list-panes for one or more panes"
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "======================================================================" -ForegroundColor Cyan
exit $script:TestsFailed
