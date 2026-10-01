#!/usr/bin/env pwsh
# Issue #109: Error when create new session (NullReferenceException / PSReadLine crash)
# Verifies that new-session creates successfully without spurious errors and
# that the pane output does not contain NullReferenceException, MethodInvocationException,
# GetHistoryItems, or other PSReadLine crash text.

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

function Wait-ForSession {
    param([string]$Name, [int]$TimeoutSec = 12)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $portFile = "$psmuxDir\$Name.port"
        if (Test-Path $portFile) {
            $port = (Get-Content $portFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($port -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new()
                    $tcp.Connect("127.0.0.1", [int]$port)
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Magenta
Write-Host "  Issue #109: new-session completes without PSReadLine crash" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Magenta

# Error patterns from the issue report (PSReadLine NullReferenceException family)
$crashPatterns = @(
    "NullReferenceException",
    "GetHistoryItems",
    "MethodInvocationException",
    "thread.*panicked",
    "RUST_BACKTRACE",
    "Object reference not set"
)

# -----------------------------------------------------------------------
# TEST 1: new-session -d creates session, exits 0, no error output
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 1] new-session -d succeeds with exit 0 and no error output" -ForegroundColor Yellow

$S1 = "gap109a"
& $PSMUX kill-session -t $S1 2>$null | Out-Null
Start-Sleep -Milliseconds 300

Write-Test "psmux new-session -d -s $S1"
$nsOut = & $PSMUX new-session -d -s $S1 2>&1
$nsExit = $LASTEXITCODE
$nsText = $nsOut -join "`n"
Write-Info "Exit code: $nsExit"
Write-Info "Output: $nsText"

if ($nsExit -eq 0) {
    Write-Pass "new-session exited 0"
} else {
    Write-Fail "new-session exited $nsExit (expected 0)"
}

if ($nsText -match ($crashPatterns -join "|")) {
    Write-Fail "Crash/error pattern in new-session output: $nsText"
} else {
    Write-Pass "No crash or error pattern in new-session output"
}

# -----------------------------------------------------------------------
# TEST 2: has-session returns 0 after creation (session is reachable)
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 2] has-session returns 0 after new-session" -ForegroundColor Yellow

$alive = Wait-ForSession -Name $S1 -TimeoutSec 12
& $PSMUX has-session -t $S1 2>$null | Out-Null
$hsExit = $LASTEXITCODE
Write-Info "has-session exit code: $hsExit"

if ($hsExit -eq 0) {
    Write-Pass "has-session returns 0: session is reachable"
} else {
    Write-Fail "has-session returned ${hsExit}: session NOT reachable after new-session"
}

# -----------------------------------------------------------------------
# TEST 3: pane output after startup contains no crash text
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 3] Pane output contains no PSReadLine crash errors" -ForegroundColor Yellow

# Give the shell a moment to fully initialize
Start-Sleep -Seconds 3

$paneOut = & $PSMUX capture-pane -t $S1 -p 2>&1 | Out-String
Write-Info "Pane output (first 400 chars): $($paneOut.Substring(0, [Math]::Min(400, $paneOut.Length)))"

$foundCrash = $false
foreach ($pattern in $crashPatterns) {
    if ($paneOut -match $pattern) {
        Write-Fail "Crash pattern '$pattern' found in pane output"
        $foundCrash = $true
    }
}
if (-not $foundCrash) {
    Write-Pass "No crash/exception patterns in pane output"
}

# -----------------------------------------------------------------------
# TEST 4: Second new-session also works (no residual state from first)
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 4] Second new-session succeeds (no residual error state)" -ForegroundColor Yellow

$S4 = "gap109b"
& $PSMUX kill-session -t $S4 2>$null | Out-Null
Start-Sleep -Milliseconds 300

$ns4Out = & $PSMUX new-session -d -s $S4 2>&1
$ns4Exit = $LASTEXITCODE
$ns4Text = $ns4Out -join "`n"
Write-Info "Second new-session exit: $ns4Exit, output: $ns4Text"

$alive4 = Wait-ForSession -Name $S4 -TimeoutSec 12
& $PSMUX has-session -t $S4 2>$null | Out-Null
$hs4Exit = $LASTEXITCODE

if ($hs4Exit -eq 0) {
    Write-Pass "Second new-session also created successfully (has-session = 0)"
} else {
    Write-Fail "Second new-session failed: has-session = $hs4Exit"
}

if ($ns4Text -match ($crashPatterns -join "|")) {
    Write-Fail "Crash pattern in second new-session output"
} else {
    Write-Pass "No crash pattern in second new-session output"
}

# -----------------------------------------------------------------------
# TEST 5: list-sessions shows both sessions (no ghost or duplicate)
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 5] list-sessions (ls) shows both sessions cleanly" -ForegroundColor Yellow

$lsOut = & $PSMUX ls 2>&1 | Out-String
Write-Info "psmux ls output: $($lsOut.Trim())"

if ($lsOut -match [regex]::Escape($S1)) {
    Write-Pass "Session $S1 appears in ls"
} else {
    Write-Fail "Session $S1 missing from ls"
}

if ($lsOut -match [regex]::Escape($S4)) {
    Write-Pass "Session $S4 appears in ls"
} else {
    Write-Fail "Session $S4 missing from ls"
}

# -----------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------
& $PSMUX kill-session -t $S1 2>$null | Out-Null
& $PSMUX kill-session -t $S4 2>$null | Out-Null

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  Issue #109 Results" -ForegroundColor White
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
