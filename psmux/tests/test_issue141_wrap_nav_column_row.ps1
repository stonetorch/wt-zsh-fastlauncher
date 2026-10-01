# psmux Issue #141 - Wrapped directional pane navigation can jump rows or columns
#
# Verifies that when the active pane is the only pane in its column (or row),
# wrapped directional navigation stays within that column (or row) rather than
# jumping sideways into a neighboring column (or row).
#
# The exact reproduction from the issue:
#   new-session -d
#   split-window -h        => %1 %2 (active=%2)
#   split-window -h -d     => %1 %2 %3 (active still %2, %3 created detached)
#   select-pane -U on %2   => sole pane in its column, should wrap to itself
#
# Expected (tmux parity): select-pane -U wraps to self when sole in column
# Bug (old behavior):     select-pane -U jumped sideways to %3
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue141_wrap_nav_column_row.ps1

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass { param($msg) Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }
function Write-Info { param($msg) Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-Test { param($msg) Write-Host "`n[TEST] $msg" -ForegroundColor White }

$PSMUX = "$env:USERPROFILE\.cargo\bin\psmux.exe"
if (-not (Test-Path $PSMUX)) {
    $PSMUX = (Get-Command psmux -ErrorAction SilentlyContinue).Source
}
if (-not $PSMUX -or -not (Test-Path $PSMUX)) { Write-Error "psmux binary not found"; exit 1 }
Write-Info "Using: $PSMUX"

$SESSION = "gap141"

function Wait-ForSession {
    param($name, $timeout = 12)
    $deadline = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $deadline) {
        & $PSMUX has-session -t $name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-ActivePaneId {
    (& $PSMUX display-message -t $SESSION -p '#{pane_id}' 2>&1 | Out-String).Trim()
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>$null
    Start-Sleep -Milliseconds 300
}

# Kill any leftover session
& $PSMUX kill-session -t $SESSION 2>$null
Start-Sleep -Milliseconds 500

Write-Host ""
Write-Host ("=" * 60)
Write-Host "ISSUE #141: Wrapped directional pane navigation column/row jump"
Write-Host ("=" * 60)

# ===========================================================
# Test 1: Exact reproduction from issue #141
#   Layout: %A | %B | %C  (three side-by-side panes)
#   Active: %B (sole pane in its column)
#   select-pane -U -> should stay on %B (wrap to self)
# ===========================================================
Write-Test "1: Exact issue #141 repro - select-pane -U on sole-column pane wraps to self"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }
    Start-Sleep -Milliseconds 500

    # split-window -h creates second pane, active moves to it
    & $PSMUX split-window -h -t $SESSION 2>$null
    Start-Sleep -Milliseconds 600

    # split-window -h -d creates third pane without taking focus
    & $PSMUX split-window -h -d -t $SESSION 2>$null
    Start-Sleep -Milliseconds 600

    # Active pane is the middle one, sole pane in its column
    $idBefore = Get-ActivePaneId
    Write-Info "Active pane before -U: $idBefore"

    $paneList = & $PSMUX list-panes -t $SESSION 2>&1 | Out-String
    Write-Info "Layout:`n$paneList"

    # select-pane -U: no pane above, sole in column -> must wrap to self
    & $PSMUX select-pane -U -t $SESSION 2>$null
    Start-Sleep -Milliseconds 400

    $idAfter = Get-ActivePaneId
    Write-Info "Active pane after -U: $idAfter"

    if ($idAfter -eq $idBefore) {
        Write-Pass "1: select-pane -U on sole-column pane wrapped to self ($idBefore -> $idAfter)"
    } else {
        Write-Fail "1: select-pane -U jumped from $idBefore to $idAfter (should have stayed on $idBefore)"
    }
} catch {
    Write-Fail "1: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 2: select-pane -D on sole-column pane wraps to self
# ===========================================================
Write-Test "2: select-pane -D on sole-column pane wraps to self"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }
    Start-Sleep -Milliseconds 500

    & $PSMUX split-window -h -t $SESSION 2>$null
    Start-Sleep -Milliseconds 600
    & $PSMUX split-window -h -d -t $SESSION 2>$null
    Start-Sleep -Milliseconds 600

    $idBefore = Get-ActivePaneId
    Write-Info "Active pane before -D: $idBefore"

    & $PSMUX select-pane -D -t $SESSION 2>$null
    Start-Sleep -Milliseconds 400

    $idAfter = Get-ActivePaneId
    if ($idAfter -eq $idBefore) {
        Write-Pass "2: select-pane -D on sole-column pane wrapped to self ($idBefore -> $idAfter)"
    } else {
        Write-Fail "2: select-pane -D jumped from $idBefore to $idAfter (should have stayed on $idBefore)"
    }
} catch {
    Write-Fail "2: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 3: Repeated -U wraps do not bounce between panes
#   (the issue: repeating -U bounced %B <-> %C)
# ===========================================================
Write-Test "3: Repeated select-pane -U on sole-column pane never leaves that pane"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }
    Start-Sleep -Milliseconds 500

    & $PSMUX split-window -h -t $SESSION 2>$null
    Start-Sleep -Milliseconds 600
    & $PSMUX split-window -h -d -t $SESSION 2>$null
    Start-Sleep -Milliseconds 600

    $idStart = Get-ActivePaneId
    $allSelf = $true

    for ($i = 0; $i -lt 4; $i++) {
        & $PSMUX select-pane -U -t $SESSION 2>$null
        Start-Sleep -Milliseconds 300
        $cur = Get-ActivePaneId
        if ($cur -ne $idStart) {
            Write-Info "  Iteration $($i+1): jumped from $idStart to $cur"
            $allSelf = $false
            break
        }
    }

    if ($allSelf) {
        Write-Pass "3: 4x select-pane -U stayed on $idStart every time"
    } else {
        Write-Fail "3: Repeated -U bounced off the sole-column pane"
    }
} catch {
    Write-Fail "3: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 4: Sole-row pane - select-pane -L wraps to self
#   Layout: top-left | top-right
#            bottom (spans full width)
#   Active: bottom pane (sole in its row)
#   select-pane -L -> wrap to self
# ===========================================================
Write-Test "4: select-pane -L on sole-row pane wraps to self"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }
    Start-Sleep -Milliseconds 500

    # Create vertical split: top and bottom
    & $PSMUX split-window -v -t $SESSION 2>$null
    Start-Sleep -Milliseconds 600
    # Add a horizontal pane beside top only (detached, does not steal focus)
    & $PSMUX split-window -h -d -t "${SESSION}:.0" 2>$null
    Start-Sleep -Milliseconds 600

    # The bottom pane should be active (it was created by split-window -v)
    # Verify it is the sole pane in its row by checking pane_top value differs
    $paneList = & $PSMUX list-panes -t $SESSION -F '#{pane_id} #{pane_top} #{pane_left}' 2>&1
    Write-Info "Pane coords: $($paneList | Out-String)"

    # Select the bottom pane explicitly (lowest pane_top value that has no H-neighbor)
    # The bottom pane is the last one created (active after -v split)
    $idBefore = Get-ActivePaneId
    Write-Info "Active pane before -L: $idBefore"

    & $PSMUX select-pane -L -t $SESSION 2>$null
    Start-Sleep -Milliseconds 400

    $idAfter = Get-ActivePaneId
    if ($idAfter -eq $idBefore) {
        Write-Pass "4: select-pane -L on sole-row pane wrapped to self ($idBefore -> $idAfter)"
    } else {
        Write-Fail "4: select-pane -L jumped from $idBefore to $idAfter (should have stayed on $idBefore)"
    }
} catch {
    Write-Fail "4: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 5: Sole-row pane - select-pane -R wraps to self
# ===========================================================
Write-Test "5: select-pane -R on sole-row pane wraps to self"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }
    Start-Sleep -Milliseconds 500

    & $PSMUX split-window -v -t $SESSION 2>$null
    Start-Sleep -Milliseconds 600
    & $PSMUX split-window -h -d -t "${SESSION}:.0" 2>$null
    Start-Sleep -Milliseconds 600

    $idBefore = Get-ActivePaneId
    Write-Info "Active pane before -R: $idBefore"

    & $PSMUX select-pane -R -t $SESSION 2>$null
    Start-Sleep -Milliseconds 400

    $idAfter = Get-ActivePaneId
    if ($idAfter -eq $idBefore) {
        Write-Pass "5: select-pane -R on sole-row pane wrapped to self ($idBefore -> $idAfter)"
    } else {
        Write-Fail "5: select-pane -R jumped from $idBefore to $idAfter (should have stayed on $idBefore)"
    }
} catch {
    Write-Fail "5: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 6: Normal multi-pane navigation still works
#   Two panes side by side: select-pane -R wraps correctly
# ===========================================================
Write-Test "6: Normal 2-pane layout: select-pane -R wraps left->right->left"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }
    Start-Sleep -Milliseconds 500

    & $PSMUX split-window -h -t $SESSION 2>$null
    Start-Sleep -Milliseconds 600

    # Active is right pane (index 1). -R should wrap to left pane.
    $idRight = Get-ActivePaneId
    Write-Info "Starting at right pane: $idRight"

    & $PSMUX select-pane -R -t $SESSION 2>$null
    Start-Sleep -Milliseconds 400
    $idLeft = Get-ActivePaneId
    Write-Info "After -R (wrap): $idLeft"

    if ($idLeft -ne $idRight) {
        Write-Pass "6a: select-pane -R moved from right to left ($idRight -> $idLeft)"
    } else {
        Write-Fail "6a: select-pane -R did not move (stayed at $idRight)"
    }

    # Now -R again should go back to the right pane
    & $PSMUX select-pane -R -t $SESSION 2>$null
    Start-Sleep -Milliseconds 400
    $idBack = Get-ActivePaneId
    if ($idBack -eq $idRight) {
        Write-Pass "6b: second select-pane -R returned to right pane ($idLeft -> $idBack)"
    } else {
        Write-Fail "6b: second select-pane -R ended on $idBack, expected $idRight"
    }
} catch {
    Write-Fail "6: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Summary
# ===========================================================
Write-Host ""
Write-Host ("=" * 60)
Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed"
Write-Host ("=" * 60)
exit $script:TestsFailed
