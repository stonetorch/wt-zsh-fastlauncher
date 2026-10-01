# psmux Issue #89 - Behavior different between tmux and psmux
#
# The specific bug: psmux always created sessions named "default", whereas
# tmux uses numeric auto-increment (0, 1, 2 ...).
#
# After the fix, psmux must:
#   1. Name the first unnamed session "0"  (not "default")
#   2. Name each subsequent unnamed session with the next integer
#   3. Never create a session named "default" automatically
#   4. Named sessions (-s myname) still use the provided name
#   5. After killing session "0", a new unnamed session gets the next
#      available integer (tmux parity: fills gaps from 0)
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue89_session_naming.ps1

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

# Session names this test owns - all prefixed gap89
$S0 = "gap89_0"
$S1 = "gap89_1"
$S2 = "gap89_2"

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

function Get-SessionNames {
    (& $PSMUX list-sessions -F '#{session_name}' 2>&1) | Where-Object { $_ -match '\S' }
}

function Cleanup {
    & $PSMUX kill-session -t $S0 2>$null
    & $PSMUX kill-session -t $S1 2>$null
    & $PSMUX kill-session -t $S2 2>$null
    Start-Sleep -Milliseconds 300
}

# Kill any leftover sessions from this test
Cleanup

Write-Host ""
Write-Host ("=" * 60)
Write-Host "ISSUE #89: Session auto-naming matches tmux (numeric, not 'default')"
Write-Host ("=" * 60)

# ===========================================================
# Test 1: new-session -d without -s uses numeric name "0"-style
#   We use gap89_0 as our named session to avoid touching other
#   sessions, but also test the raw unnamed behavior in isolation
#   by checking psmux list-sessions after a clean new-session.
# ===========================================================
Write-Test "1: new-session -d -s gap89_0 creates session with exact name (baseline)"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $S0 -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $S0)) { throw "session $S0 did not start" }

    $names = Get-SessionNames
    Write-Info "Sessions: $($names -join ', ')"

    if ($names -contains $S0) {
        Write-Pass "1: Named session '$S0' created successfully"
    } else {
        Write-Fail "1: Session '$S0' not found in list-sessions output"
    }
} catch {
    Write-Fail "1: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 2: No session named "default" is auto-created
#   Kill server, start fresh unnamed session, verify name is
#   numeric (0, 1, etc.) and NOT "default"
# ===========================================================
Write-Test "2: Fresh unnamed new-session is NOT named 'default'"
try {
    # Kill the server entirely so we get a clean first session
    & $PSMUX kill-server 2>$null
    Start-Sleep -Seconds 2

    # Start an unnamed session
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -d" -WindowStyle Hidden
    Start-Sleep -Seconds 3

    $names = Get-SessionNames
    Write-Info "Session names after unnamed new-session: $($names -join ', ')"

    $hasDefault = $names | Where-Object { $_ -eq "default" }
    if ($hasDefault) {
        Write-Fail "2: Session was named 'default' - old bug still present"
    } else {
        Write-Pass "2: No session named 'default' - correct tmux-parity naming"
    }

    # Verify the name is a digit string (tmux uses "0", "1", ...)
    $isNumeric = $names | Where-Object { $_ -match '^\d+$' }
    if ($isNumeric) {
        Write-Pass "2b: First unnamed session has numeric name ('$($isNumeric | Select-Object -First 1)')"
    } else {
        Write-Fail "2b: First unnamed session does not have a numeric name (got '$($names -join ', ')')"
    }
} catch {
    Write-Fail "2: Exception: $_"
} finally {
    & $PSMUX kill-server 2>$null
    Start-Sleep -Seconds 2
}

# ===========================================================
# Test 3: Sequential unnamed sessions get incrementing numeric names
#   0, 1, 2 in order
# ===========================================================
Write-Test "3: Three sequential unnamed sessions get names 0, 1, 2"
try {
    & $PSMUX kill-server 2>$null
    Start-Sleep -Seconds 2

    Start-Process -FilePath $PSMUX -ArgumentList "new-session -d" -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $after1 = Get-SessionNames
    Write-Info "After 1st new-session: $($after1 -join ', ')"

    Start-Process -FilePath $PSMUX -ArgumentList "new-session -d" -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $after2 = Get-SessionNames
    Write-Info "After 2nd new-session: $($after2 -join ', ')"

    Start-Process -FilePath $PSMUX -ArgumentList "new-session -d" -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $after3 = Get-SessionNames
    Write-Info "After 3rd new-session: $($after3 -join ', ')"

    # All three should be present and numeric
    $has0 = $after3 -contains "0"
    $has1 = $after3 -contains "1"
    $has2 = $after3 -contains "2"

    if ($has0 -and $has1 -and $has2) {
        Write-Pass "3: Sessions named 0, 1, 2 all present after three unnamed new-sessions"
    } else {
        Write-Fail "3: Expected sessions 0, 1, 2 but got: $($after3 -join ', ')"
    }

    # None should be named "default"
    $anyDefault = $after3 | Where-Object { $_ -eq "default" }
    if (-not $anyDefault) {
        Write-Pass "3b: No 'default' session name present"
    } else {
        Write-Fail "3b: 'default' session name found - old bug still present"
    }
} catch {
    Write-Fail "3: Exception: $_"
} finally {
    & $PSMUX kill-server 2>$null
    Start-Sleep -Seconds 2
}

# ===========================================================
# Test 4: Explicitly named sessions still use the provided name
# ===========================================================
Write-Test "4: new-session -s myname still uses exactly 'myname'"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $S0 -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $S0)) { throw "session $S0 did not start" }

    $names = Get-SessionNames
    Write-Info "Sessions: $($names -join ', ')"

    if ($names -contains $S0) {
        Write-Pass "4: Explicit name '$S0' used correctly"
    } else {
        Write-Fail "4: Explicit name '$S0' not found, got: $($names -join ', ')"
    }
} catch {
    Write-Fail "4: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 5: Mixed named + unnamed sessions - unnamed gets next numeric
# ===========================================================
Write-Test "5: Unnamed session created alongside named session gets a numeric name"
try {
    & $PSMUX kill-server 2>$null
    Start-Sleep -Seconds 2

    # Create a named session first
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s mysession -d" -WindowStyle Hidden
    Start-Sleep -Seconds 3

    # Then an unnamed one
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -d" -WindowStyle Hidden
    Start-Sleep -Seconds 2

    $names = Get-SessionNames
    Write-Info "Sessions: $($names -join ', ')"

    # mysession should exist
    if ($names -contains "mysession") {
        Write-Pass "5a: Named session 'mysession' still present"
    } else {
        Write-Fail "5a: Named session 'mysession' missing"
    }

    # An unnamed (numeric) session should also exist
    $numeric = $names | Where-Object { $_ -match '^\d+$' }
    if ($numeric) {
        Write-Pass "5b: Unnamed session got numeric name ('$($numeric | Select-Object -First 1)')"
    } else {
        Write-Fail "5b: No numeric-named session found alongside named session"
    }

    # No "default" name
    if ($names -notcontains "default") {
        Write-Pass "5c: No 'default' session name (correct tmux parity)"
    } else {
        Write-Fail "5c: 'default' session name found - old bug"
    }
} catch {
    Write-Fail "5: Exception: $_"
} finally {
    & $PSMUX kill-server 2>$null
    Start-Sleep -Seconds 2
}

# ===========================================================
# Summary
# ===========================================================
Write-Host ""
Write-Host ("=" * 60)
Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed"
Write-Host ("=" * 60)
exit $script:TestsFailed
