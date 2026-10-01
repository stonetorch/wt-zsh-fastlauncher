#!/usr/bin/env pwsh
# Issue #61: Directional pane navigation does not wrap (tmux parity divergence)
# Verifies that select-pane -L/-R/-U/-D wraps at layout edges (cyclic, tmux parity).
# Uses CLI path only (detached session). Assertions via display-message #{pane_index}.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "gap61"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# Wait for the .port file to appear (up to 12s)
function Wait-Port {
    $portFile = "$psmuxDir\$SESSION.port"
    for ($i = 0; $i -lt 24; $i++) {
        if (Test-Path $portFile) {
            $val = (Get-Content $portFile -Raw -EA SilentlyContinue).Trim()
            if ($val -match '^\d+$' -and [int]$val -gt 0) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Fmt { param($f)
    (& $PSMUX display-message -t $SESSION -p $f 2>&1 | Out-String).Trim()
}

# ─── Setup ───────────────────────────────────────────────────────────────────
Cleanup
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
if (-not (Wait-Port)) {
    Write-Host "[ERROR] Session port file did not appear within 12s" -ForegroundColor Red
    Cleanup; exit 1
}

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Session creation failed" -ForegroundColor Red
    Cleanup; exit 1
}

Write-Host "`n=== Issue #61: Directional pane wrap navigation ===" -ForegroundColor Cyan

# ─── Horizontal wrap tests ───────────────────────────────────────────────────
Write-Host "`n--- Horizontal layout (split-window -h) ---" -ForegroundColor Magenta

# Create a horizontal split: pane 0 (left) and pane 1 (right)
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$panes = (Fmt '#{window_panes}')
if ($panes -ne "2") {
    Write-Host "[ERROR] Expected 2 panes after split, got $panes" -ForegroundColor Red
    Cleanup; exit 1
}

# [Test 1] From rightmost (index 1), select-pane -R must wrap to index 0
Write-Host "`n[Test 1] -R from rightmost pane wraps to leftmost" -ForegroundColor Yellow
& $PSMUX select-pane -t "${SESSION}:.1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$before = Fmt '#{pane_index}'
& $PSMUX select-pane -R -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$after = Fmt '#{pane_index}'
if ($before -eq "1" -and $after -eq "0") {
    Write-Pass "select-pane -R wrap: index $before -> $after (rightmost wraps to leftmost)"
} else {
    Write-Fail "select-pane -R wrap: expected 1->0, got $before->$after"
}

# [Test 2] From leftmost (index 0), select-pane -L must wrap to index 1
Write-Host "`n[Test 2] -L from leftmost pane wraps to rightmost" -ForegroundColor Yellow
& $PSMUX select-pane -t "${SESSION}:.0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$before = Fmt '#{pane_index}'
& $PSMUX select-pane -L -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$after = Fmt '#{pane_index}'
if ($before -eq "0" -and $after -eq "1") {
    Write-Pass "select-pane -L wrap: index $before -> $after (leftmost wraps to rightmost)"
} else {
    Write-Fail "select-pane -L wrap: expected 0->1, got $before->$after"
}

# ─── Vertical wrap tests ─────────────────────────────────────────────────────
Write-Host "`n--- Vertical layout (new window + split-window -v) ---" -ForegroundColor Magenta

& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$panes = (Fmt '#{window_panes}')
if ($panes -ne "2") {
    Write-Host "[ERROR] Expected 2 panes in new window, got $panes" -ForegroundColor Red
    Cleanup; exit 1
}

# [Test 3] From bottom pane (index 1), select-pane -D must wrap to top (index 0)
Write-Host "`n[Test 3] -D from bottom pane wraps to top" -ForegroundColor Yellow
& $PSMUX select-pane -t "${SESSION}:.1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$before = Fmt '#{pane_index}'
& $PSMUX select-pane -D -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$after = Fmt '#{pane_index}'
if ($before -eq "1" -and $after -eq "0") {
    Write-Pass "select-pane -D wrap: index $before -> $after (bottom wraps to top)"
} else {
    Write-Fail "select-pane -D wrap: expected 1->0, got $before->$after"
}

# [Test 4] From top pane (index 0), select-pane -U must wrap to bottom (index 1)
Write-Host "`n[Test 4] -U from top pane wraps to bottom" -ForegroundColor Yellow
& $PSMUX select-pane -t "${SESSION}:.0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$before = Fmt '#{pane_index}'
& $PSMUX select-pane -U -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$after = Fmt '#{pane_index}'
if ($before -eq "0" -and $after -eq "1") {
    Write-Pass "select-pane -U wrap: index $before -> $after (top wraps to bottom)"
} else {
    Write-Fail "select-pane -U wrap: expected 0->1, got $before->$after"
}

# ─── Multi-pane wrap (3 panes horizontal) ────────────────────────────────────
Write-Host "`n--- 3-pane horizontal layout ---" -ForegroundColor Magenta

& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$panes = (Fmt '#{window_panes}')
if ($panes -ne "3") {
    Write-Host "[SKIP] Expected 3 panes, got $panes - skipping 3-pane tests" -ForegroundColor DarkYellow
} else {
    # Find the rightmost pane index
    $paneList = & $PSMUX list-panes -t $SESSION 2>&1
    $indices = $paneList | ForEach-Object { if ($_ -match '^(\d+):') { [int]$Matches[1] } }
    $maxIdx = ($indices | Measure-Object -Maximum).Maximum
    $minIdx = ($indices | Measure-Object -Minimum).Minimum

    # [Test 5] From rightmost pane, -R wraps to leftmost
    Write-Host "`n[Test 5] 3-pane: -R from rightmost (idx $maxIdx) wraps to leftmost (idx $minIdx)" -ForegroundColor Yellow
    & $PSMUX select-pane -t "${SESSION}:.$maxIdx" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $before = Fmt '#{pane_index}'
    & $PSMUX select-pane -R -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $after = Fmt '#{pane_index}'
    if ($before -eq "$maxIdx" -and $after -eq "$minIdx") {
        Write-Pass "3-pane -R wrap: index $before -> $after"
    } else {
        Write-Fail "3-pane -R wrap: expected $maxIdx->$minIdx, got $before->$after"
    }

    # [Test 6] From leftmost pane, -L wraps to rightmost
    Write-Host "`n[Test 6] 3-pane: -L from leftmost (idx $minIdx) wraps to rightmost (idx $maxIdx)" -ForegroundColor Yellow
    & $PSMUX select-pane -t "${SESSION}:.$minIdx" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $before = Fmt '#{pane_index}'
    & $PSMUX select-pane -L -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $after = Fmt '#{pane_index}'
    if ($before -eq "$minIdx" -and $after -eq "$maxIdx") {
        Write-Pass "3-pane -L wrap: index $before -> $after"
    } else {
        Write-Fail "3-pane -L wrap: expected $minIdx->$maxIdx, got $before->$after"
    }
}

# ─── Verify with #{pane_active} and #{pane_id} ───────────────────────────────
Write-Host "`n--- Verify with pane_active/pane_id format vars ---" -ForegroundColor Magenta

& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

# Get the two pane IDs
$paneData = & $PSMUX list-panes -t $SESSION -F '#{pane_index} #{pane_id}' 2>&1
$p0id = ($paneData | Where-Object { $_ -match '^0 ' } | ForEach-Object { ($_ -split ' ')[1] } | Select-Object -First 1)
$p1id = ($paneData | Where-Object { $_ -match '^1 ' } | ForEach-Object { ($_ -split ' ')[1] } | Select-Object -First 1)

if ($p0id -and $p1id) {
    # [Test 7] #{pane_active} changes on wrap; #{pane_id} confirms correct pane
    Write-Host "`n[Test 7] #{pane_id} confirms correct pane after wrap (-R from pane 1)" -ForegroundColor Yellow
    & $PSMUX select-pane -t "${SESSION}:.1" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $idBefore = Fmt '#{pane_id}'
    & $PSMUX select-pane -R -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $idAfter = Fmt '#{pane_id}'
    $activeFlag = Fmt '#{pane_active}'
    if ($idBefore -eq $p1id -and $idAfter -eq $p0id -and $activeFlag -eq "1") {
        Write-Pass "pane_id wrap confirmed: $idBefore -> $idAfter (pane_active=$activeFlag)"
    } else {
        Write-Fail "pane_id wrap: before=$idBefore(want $p1id) after=$idAfter(want $p0id) active=$activeFlag"
    }
} else {
    Write-Host "  [INFO] Could not parse pane IDs from list-panes output, skipping pane_id test" -ForegroundColor DarkYellow
}

# ─── Teardown ────────────────────────────────────────────────────────────────
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -gt 0) {
    Write-Host "`n  VERDICT: VERIFIED_BROKEN - select-pane wrap navigation fails" -ForegroundColor Red
} else {
    Write-Host "`n  VERDICT: PASS - select-pane -L/-R/-U/-D wraps at layout edges (tmux parity)" -ForegroundColor Green
}

exit $script:TestsFailed
