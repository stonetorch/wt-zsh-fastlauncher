#!/usr/bin/env pwsh
# Issue #119: `-f <file>` no longer works as a global option
# Verifies that `psmux -f <config>` loads the specified config at startup
# and that the settings in that config are applied to the new session.

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
Write-Host "  Issue #119: psmux -f <file> global config option" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Magenta

# -----------------------------------------------------------------------
# TEST 1: -f option does NOT treat the filename as a command
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 1] -f <file> is not treated as a command name" -ForegroundColor Yellow

$cfgFile1 = "$env:TEMP\psmux_issue119_t1.conf"
@"
set -g status-right "CFG119MARK"
set -g base-index 7
"@ | Set-Content -Path $cfgFile1 -Encoding UTF8

$S1 = "gap119a"
& $PSMUX kill-session -t $S1 2>$null | Out-Null

Write-Test "Run: psmux -f <config> new-session -d -s $S1"
$proc = Start-Process -FilePath $PSMUX `
    -ArgumentList "-f", $cfgFile1, "new-session", "-d", "-s", $S1 `
    -WindowStyle Hidden -PassThru
$proc.WaitForExit(8000) | Out-Null
Write-Info "Exit code: $($proc.ExitCode)"

# Capture stderr/stdout via direct invocation too
$directOut = & $PSMUX -f $cfgFile1 new-session -d -s "${S1}_direct" 2>&1
Write-Info "Direct invocation output: $($directOut -join ' | ')"

# The file path must NOT appear as "unknown command" error
$unknownCmd = $directOut | Where-Object { $_ -match "unknown command.*\.conf|unknown command.*psmux" }
if ($unknownCmd) {
    Write-Fail "Filename treated as command: $($unknownCmd -join '; ')"
} else {
    Write-Pass "-f <file> not treated as a command name (no 'unknown command' for .conf path)"
}

# -----------------------------------------------------------------------
# TEST 2: Session created successfully via -f flag (positive assertion)
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 2] Session created successfully when using -f" -ForegroundColor Yellow

$alive = Wait-ForSession -Name $S1 -TimeoutSec 12
if (-not $alive) {
    # Try the _direct variant
    $alive = Wait-ForSession -Name "${S1}_direct" -TimeoutSec 5
}

$lsOut = & $PSMUX ls 2>&1 | Out-String
Write-Info "psmux ls: $($lsOut.Trim())"

if ($lsOut -match [regex]::Escape($S1) -or $lsOut -match [regex]::Escape("${S1}_direct")) {
    Write-Pass "Session created with -f flag (appears in ls)"
} else {
    Write-Fail "Session NOT found in ls after psmux -f <config> new-session"
}

# -----------------------------------------------------------------------
# TEST 3: Config setting (base-index 7) is applied in the session
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 3] Config setting base-index=7 is applied" -ForegroundColor Yellow

# Determine which session name was actually created
$targetSession = $null
if ($lsOut -match [regex]::Escape($S1)) { $targetSession = $S1 }
elseif ($lsOut -match [regex]::Escape("${S1}_direct")) { $targetSession = "${S1}_direct" }

if ($targetSession) {
    Start-Sleep -Milliseconds 500
    $opts = & $PSMUX show-options -g -t $targetSession 2>&1 | Out-String
    Write-Info "show-options -g output (trimmed): $($opts.Substring(0, [Math]::Min(400, $opts.Length)))"

    if ($opts -match "base-index\s+7") {
        Write-Pass "base-index is 7 (config loaded via -f)"
    } else {
        Write-Fail "base-index != 7; config was NOT applied (opts: $($opts.Trim() | Select-Object -First 5))"
    }
} else {
    Write-Fail "Skipping option check: no session was created"
}

# -----------------------------------------------------------------------
# TEST 4: Config setting status-right "CFG119MARK" is applied
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 4] Config setting status-right=CFG119MARK is applied" -ForegroundColor Yellow

if ($targetSession) {
    $opts2 = & $PSMUX show-options -g -t $targetSession 2>&1 | Out-String
    if ($opts2 -match "CFG119MARK") {
        Write-Pass "status-right contains CFG119MARK (config loaded via -f)"
    } else {
        Write-Fail "status-right does NOT contain CFG119MARK (config not applied via -f)"
    }
} else {
    Write-Fail "Skipping status-right check: no session was created"
}

# -----------------------------------------------------------------------
# TEST 5: Passing a nonexistent config file gives a clear error (not crash)
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "[Test 5] Nonexistent config file gives clean error, not panic" -ForegroundColor Yellow

$S5 = "gap119b"
& $PSMUX kill-session -t $S5 2>$null | Out-Null
$errOut = & $PSMUX -f "C:\nonexistent_psmux_config_119.conf" new-session -d -s $S5 2>&1
$errText = $errOut -join "`n"
Write-Info "Output for nonexistent config: $errText"

$hasPanic = $errText -match "panic|thread.*panicked|RUST_BACKTRACE"
if ($hasPanic) {
    Write-Fail "Rust panic on nonexistent config file"
} else {
    Write-Pass "No panic for nonexistent config file (clean error or silent)"
}

# -----------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------
& $PSMUX kill-session -t $S1 2>$null | Out-Null
& $PSMUX kill-session -t "${S1}_direct" 2>$null | Out-Null
& $PSMUX kill-session -t $S5 2>$null | Out-Null
Remove-Item $cfgFile1 -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  Issue #119 Results" -ForegroundColor White
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
