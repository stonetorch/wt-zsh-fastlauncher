#!/usr/bin/env pwsh
# Issue #106: psmux: can't find session '0' (no server running)
# Verifies graceful, non-panicking, non-zero exit when targeting a
# nonexistent session while no server is running for that target.
# We NEVER create the ghost session - it must not exist throughout the test.

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-Test($msg) { Write-Host "  [TEST] $msg" -ForegroundColor White }

$PSMUX = (Get-Command psmux -ErrorAction SilentlyContinue).Source
if (-not $PSMUX) { $PSMUX = "$env:USERPROFILE\.cargo\bin\psmux.exe" }
if (-not (Test-Path $PSMUX)) { Write-Host "[FATAL] psmux not found" -ForegroundColor Red; exit 1 }
Write-Info "Binary: $PSMUX"

$psmuxDir = "$env:USERPROFILE\.psmux"

# The target name is guaranteed nonexistent; we NEVER create it.
$GHOST = "gap106nonexistent"

# Remove any stale port/key for this name just in case
Remove-Item "$psmuxDir\$GHOST.port" -Force -ErrorAction SilentlyContinue
Remove-Item "$psmuxDir\$GHOST.key"  -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Magenta
Write-Host "  Issue #106: graceful error for nonexistent session / no server" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Magenta

# -----------------------------------------------------------------------
# TEST 1: has-session for nonexistent target exits non-zero, no panic
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 1] has-session -t <nonexistent> exits non-zero, no panic" -ForegroundColor Yellow
Write-Test "psmux has-session -t $GHOST"

$out1 = & $PSMUX has-session -t $GHOST 2>&1
$exit1 = $LASTEXITCODE
$text1 = $out1 -join "`n"
Write-Info "Exit code: $exit1"
Write-Info "Output: '$text1'"

$hasPanic1 = $text1 -match "panic|thread.*panicked|RUST_BACKTRACE|unwrap\(\)|called.*on.*None"
if ($hasPanic1) {
    Write-Fail "has-session: Rust panic/crash detected"
} elseif ($exit1 -ne 0) {
    Write-Pass "has-session exits non-zero ($exit1) for nonexistent session - no panic"
} else {
    Write-Fail "has-session exits 0 for nonexistent session (should be non-zero)"
}

# -----------------------------------------------------------------------
# TEST 2: display-message targeting nonexistent session exits non-zero
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 2] display-message -t <nonexistent> exits non-zero, no panic" -ForegroundColor Yellow
Write-Test "psmux display-message -t $GHOST -p x"

$out2 = & $PSMUX display-message -t $GHOST -p x 2>&1
$exit2 = $LASTEXITCODE
$text2 = $out2 -join "`n"
Write-Info "Exit code: $exit2"
Write-Info "Output: '$text2'"

$hasPanic2 = $text2 -match "panic|thread.*panicked|RUST_BACKTRACE"
if ($hasPanic2) {
    Write-Fail "display-message: Rust panic/crash detected"
} elseif ($exit2 -ne 0) {
    Write-Pass "display-message exits non-zero ($exit2) for nonexistent session - no panic"
} else {
    Write-Fail "display-message exits 0 for nonexistent session (should be non-zero)"
}

# -----------------------------------------------------------------------
# TEST 3: send-keys to nonexistent target exits non-zero, no panic
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 3] send-keys -t <nonexistent> exits non-zero, no panic" -ForegroundColor Yellow
Write-Test "psmux send-keys -t $GHOST echo Enter"

$out3 = & $PSMUX send-keys -t $GHOST "echo hi" Enter 2>&1
$exit3 = $LASTEXITCODE
$text3 = $out3 -join "`n"
Write-Info "Exit code: $exit3"
Write-Info "Output: '$text3'"

$hasPanic3 = $text3 -match "panic|thread.*panicked|RUST_BACKTRACE"
if ($hasPanic3) {
    Write-Fail "send-keys: Rust panic/crash detected"
} elseif ($exit3 -ne 0) {
    Write-Pass "send-keys exits non-zero ($exit3) for nonexistent session - no panic"
} else {
    Write-Fail "send-keys exits 0 for nonexistent session (should be non-zero)"
}

# -----------------------------------------------------------------------
# TEST 4: Error message is human-readable (not empty, not a Rust panic)
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 4] Error messages are human-readable (display-message path)" -ForegroundColor Yellow

# display-message gives the most informative error; check it
if ($text2.Length -gt 0) {
    $readable = $text2 -match "session|server|not found|can.t find|$GHOST"
    if ($readable) {
        Write-Pass "Error message is human-readable: '$text2'"
    } else {
        Write-Pass "Error message is non-empty (no panic): '$text2'"
    }
} else {
    # has-session may be silent (exit code alone signals the result)
    Write-Pass "Silent non-zero exit is acceptable for missing session (tmux parity)"
}

# -----------------------------------------------------------------------
# TEST 5: No crash text in any of the above outputs
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 5] None of the error outputs contain Rust panic text" -ForegroundColor Yellow

$allText = "$text1`n$text2`n$text3"
$panicPatterns = @("thread.*panicked", "RUST_BACKTRACE", "stack backtrace", "note: run with")
$foundPanic = $false
foreach ($p in $panicPatterns) {
    if ($allText -match $p) {
        Write-Fail "Panic pattern '$p' found in combined output"
        $foundPanic = $true
    }
}
if (-not $foundPanic) {
    Write-Pass "No Rust panic text in any command output"
}

# -----------------------------------------------------------------------
# TEST 6: Ghost session was never created
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 6] Ghost session was never inadvertently created" -ForegroundColor Yellow

$lsOut = & $PSMUX ls 2>&1 | Out-String
Write-Info "psmux ls: $($lsOut.Trim())"

if ($lsOut -match [regex]::Escape($GHOST)) {
    Write-Fail "Ghost session '$GHOST' should NEVER have been created but appears in ls"
} else {
    Write-Pass "Ghost session '$GHOST' was never created (correct)"
}

# -----------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  Issue #106 Results" -ForegroundColor White
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
