# test_issue317_if_shell_brace.ps1
# Verify if-shell brace-block form only runs when condition succeeds
# https://github.com/psmux/psmux/issues/317
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue317_if_shell_brace.ps1

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-Test($msg) { Write-Host "  [TEST] $msg" -ForegroundColor White }

$PSMUX    = (Get-Command psmux -ErrorAction Stop).Source
Write-Info "Binary: $PSMUX"

$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION  = "gap317_$(Get-Random)"
$CONF     = "$env:TEMP\psmux_issue317_$(Get-Random).conf"

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 12000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -ErrorAction SilentlyContinue)
            if ($port -and $port.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port.Trim())
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -ErrorAction SilentlyContinue
    Remove-Item $CONF -Force -ErrorAction SilentlyContinue
}

# --- guard: kill any leftover session ---
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

# =============================================================================
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Magenta
Write-Host "  ISSUE #317: if-shell brace-block conditional execution" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Magenta

# On Windows, "exit 1" / "exit 0" need to be valid shell commands.
# psmux runs if-shell conditions through cmd.exe or pwsh; use the classic
# 3-argument form as a baseline and the brace-block form as the regression test.
#
# The brace-block form that was broken:
#   if-shell 'false' {
#       set -g @option VALUE
#   }
#
# On Windows, psmux typically invokes the condition via cmd.exe /C or similar.
# We use "cmd /c exit 1" and "cmd /c exit 0" to be explicit.
Write-Test "Writing temp config with if-shell brace blocks"
@"
# Issue #317 regression test
# false condition: body must NOT run
if-shell 'cmd /c exit 1' {
    set -g @if317 SHOULD_NOT_RUN
}
# true condition: body MUST run
if-shell 'cmd /c exit 0' {
    set -g @if317b SHOULD_RUN
}
"@ | Set-Content -Path $CONF -Encoding UTF8 -NoNewline
Write-Info "Config: $CONF"
Get-Content $CONF | ForEach-Object { Write-Info "  $_" }

# =============================================================================
# TEST 1: Session starts
# =============================================================================
Write-Host ""
Write-Test "TEST 1: Start session with if-shell config"
Start-Process -FilePath $PSMUX -ArgumentList "-f", "`"$CONF`"", "new-session", "-d", "-s", $SESSION -WindowStyle Hidden | Out-Null

if (Wait-Session $SESSION 12000) {
    Write-Pass "Session '$SESSION' started"
} else {
    Write-Fail "Session '$SESSION' failed to start"
    Cleanup
    Write-Host ""; Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed"
    exit 1
}
Start-Sleep -Milliseconds 800

# =============================================================================
# TEST 2: @if317 must NOT be set (false condition body did not run)
# =============================================================================
Write-Host ""
Write-Test "TEST 2: @if317 is NOT set (false condition body skipped)"
$opts = (& $PSMUX show-options -g -t $SESSION 2>&1) -join "`n"
Write-Info "show-options (user-option lines):"
$opts -split "`n" | Where-Object { $_ -match "@if317" } | ForEach-Object { Write-Info "  $_" }

if ($opts -match "@if317\b" -and $opts -notmatch "@if317b") {
    # @if317 present but only check for the exact name without 'b' suffix
    # Use word-boundary-safe check
    $has317    = ($opts -split "`n") | Where-Object { $_ -match "^\s*@if317\s" }
    if ($has317) {
        Write-Fail "@if317 IS set (SHOULD_NOT_RUN) - bug: false condition body executed"
        Write-Info "Offending line: $has317"
    } else {
        Write-Pass "@if317 is NOT set - false condition body was correctly skipped"
    }
} else {
    $has317 = ($opts -split "`n") | Where-Object { $_ -match "^@if317\s|^\s+@if317\s" }
    if ($has317) {
        Write-Fail "@if317 IS set (SHOULD_NOT_RUN) - bug: false condition body executed"
        Write-Info "Offending line(s): $($has317 -join ', ')"
    } else {
        Write-Pass "@if317 is NOT set - false condition body was correctly skipped"
    }
}

# =============================================================================
# TEST 3: @if317b MUST be set to SHOULD_RUN (true condition body ran)
# =============================================================================
Write-Host ""
Write-Test "TEST 3: @if317b IS set to SHOULD_RUN (true condition body ran)"
$has317b = ($opts -split "`n") | Where-Object { $_ -match "@if317b" }
Write-Info "Lines matching @if317b: $($has317b -join ' | ')"

if ($has317b -and ($has317b -join "") -match "SHOULD_RUN") {
    Write-Pass "@if317b == SHOULD_RUN - true condition body was executed"
} else {
    Write-Fail "@if317b is NOT set or does not equal SHOULD_RUN - true condition body did not run"
    Write-Info "Full show-options:"
    $opts -split "`n" | ForEach-Object { Write-Info "  $_" }
}

# =============================================================================
# TEST 4: 3-argument form baseline - classic form still correct
# =============================================================================
Write-Host ""
Write-Test "TEST 4: 3-argument if-shell baseline (classic form)"
$r4_false = (& $PSMUX if-shell -t $SESSION 'cmd /c exit 1' 'set -g @if317_classic WRONG' 2>&1) -join ""
Start-Sleep -Milliseconds 400
$r4_true  = (& $PSMUX if-shell -t $SESSION 'cmd /c exit 0' 'set -g @if317_classic2 RIGHT' 2>&1) -join ""
Start-Sleep -Milliseconds 400

$opts2 = (& $PSMUX show-options -g -t $SESSION 2>&1) -join "`n"
$has_classic  = ($opts2 -split "`n") | Where-Object { $_ -match "@if317_classic\b" -and $_ -notmatch "@if317_classic2" }
$has_classic2 = ($opts2 -split "`n") | Where-Object { $_ -match "@if317_classic2" }

if ($has_classic) {
    Write-Fail "3-arg false form set @if317_classic (WRONG) - baseline broken"
} else {
    Write-Pass "3-arg false form: @if317_classic NOT set (correct)"
}

if ($has_classic2 -and ($has_classic2 -join "") -match "RIGHT") {
    Write-Pass "3-arg true form: @if317_classic2 == RIGHT (correct)"
} else {
    Write-Fail "3-arg true form: @if317_classic2 not set or wrong"
    Write-Info "Lines: $($has_classic2 -join ' | ')"
}

# =============================================================================
# CLEANUP
# =============================================================================
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Yellow
Write-Host "  CLEANUP" -ForegroundColor Yellow
Write-Host ("=" * 70) -ForegroundColor Yellow
Cleanup
Write-Info "Cleaned up session and temp config"

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  ISSUE #317 RESULTS" -ForegroundColor White
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor Red
Write-Host ("=" * 70) -ForegroundColor White

if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
