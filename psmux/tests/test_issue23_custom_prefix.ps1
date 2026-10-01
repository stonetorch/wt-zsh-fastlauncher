# test_issue23_custom_prefix.ps1
# Verify custom prefix key set in config file takes effect
# https://github.com/psmux/psmux/issues/23
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue23_custom_prefix.ps1

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-Test($msg) { Write-Host "  [TEST] $msg" -ForegroundColor White }

$PSMUX   = (Get-Command psmux -ErrorAction Stop).Source
Write-Info "Binary: $PSMUX"

$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION  = "gap23_$(Get-Random)"
$CONF     = "$env:TEMP\psmux_issue23_$(Get-Random).conf"

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
Write-Host "  ISSUE #23: Custom prefix key from config file" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Magenta

# --- Write temp config with custom prefix C-a ---
Write-Test "Writing temp config with prefix C-a"
@"
# Issue #23 test: custom prefix
set -g prefix C-a
unbind-key C-b
bind-key C-a send-prefix
"@ | Set-Content -Path $CONF -Encoding UTF8 -NoNewline
Write-Info "Config: $CONF"

# =============================================================================
# TEST 1: Session starts with -f <config>
# =============================================================================
Write-Host ""
Write-Test "TEST 1: Start session via -f $CONF"
Start-Process -FilePath $PSMUX -ArgumentList "-f", "`"$CONF`"", "new-session", "-d", "-s", $SESSION -WindowStyle Hidden | Out-Null

if (Wait-Session $SESSION 12000) {
    Write-Pass "Session '$SESSION' started with custom prefix config"
} else {
    Write-Fail "Session '$SESSION' failed to start"
    Cleanup
    Write-Host ""; Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed"
    exit 1
}

# =============================================================================
# TEST 2: show-options -g prefix reports C-a
# =============================================================================
Write-Host ""
Write-Test "TEST 2: show-options -g prefix == C-a"
Start-Sleep -Milliseconds 500
$opts = (& $PSMUX show-options -g -t $SESSION 2>&1) -join "`n"
Write-Info "Relevant show-options lines:"
$opts -split "`n" | Where-Object { $_ -match "prefix" } | ForEach-Object { Write-Info "  $_" }

# C-a can appear as literal "C-a" or as the control character (0x01)
if ($opts -match "(?m)^prefix\s+C-a") {
    Write-Pass "prefix is C-a as reported by show-options"
} else {
    Write-Fail "prefix is NOT C-a in show-options"
    Write-Info "Full show-options:"
    $opts -split "`n" | ForEach-Object { Write-Info "  $_" }
}

# =============================================================================
# TEST 3: C-b is NOT listed as prefix in the prefix key-table
# =============================================================================
Write-Host ""
Write-Test "TEST 3: C-b is unbound (unbind-key C-b took effect)"
$keys = (& $PSMUX list-keys -t $SESSION 2>&1) -join "`n"
Write-Info "Key table (prefix-related lines):"
$keys -split "`n" | Where-Object { $_ -match "C-b|C-a|send-prefix" } | ForEach-Object { Write-Info "  $_" }

# After unbind C-b the prefix table should show C-a send-prefix, not C-b
if ($keys -match "C-a.*send-prefix|send-prefix.*C-a") {
    Write-Pass "C-a send-prefix binding is present (new prefix registered)"
} else {
    Write-Fail "C-a send-prefix binding is missing"
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
Write-Host "  ISSUE #23 RESULTS" -ForegroundColor White
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor Red
Write-Host ("=" * 70) -ForegroundColor White

if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
