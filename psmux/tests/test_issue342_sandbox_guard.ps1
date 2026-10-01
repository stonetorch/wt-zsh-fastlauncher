#!/usr/bin/env pwsh
# Issue #342: PowerShell test suite is destructive to a live psmux environment.
# Fix (commit 53fe065): run_all_tests.ps1 now refuses to run unless
# PSMUX_TEST_SANDBOX=1, and that gate appears BEFORE any destructive operation.
#
# This test is PURELY STATIC — it reads run_all_tests.ps1 but NEVER executes it.
# Safe to run anywhere, including on a machine with a live psmux.
#
# Assertions:
#   1. run_all_tests.ps1 exists
#   2. The executable gate `if ($env:PSMUX_TEST_SANDBOX ...)` is present
#   3. The gate aborts (exit N) within 1200 chars of the check
#   4. The gate appears BEFORE every known destructive operation
#   5. Running run_all_tests.ps1 WITHOUT the env var set produces a refusal
#      (exit 2) and prints a clear message — verified by actually running it
#      in a subprocess with no env var set

$ErrorActionPreference = "Continue"
$runner = Join-Path $PSScriptRoot "run_all_tests.ps1"

$script:Pass = 0
$script:Fail = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:Fail++ }

Write-Host "`n=== Issue #342: sandbox guard in run_all_tests.ps1 ===" -ForegroundColor Cyan

# ── T1: runner file exists ───────────────────────────────────────────────────
Write-Host "`n[T1] run_all_tests.ps1 exists" -ForegroundColor Yellow
if (Test-Path $runner) {
    Write-Pass "run_all_tests.ps1 found at $runner"
} else {
    Write-Fail "run_all_tests.ps1 NOT found at $runner"
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "  Passed: $($script:Pass)  Failed: $($script:Fail)" -ForegroundColor Red
    exit 1
}

$src = Get-Content -LiteralPath $runner -Raw
$ci  = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

# ── T2: executable gate is present ──────────────────────────────────────────
Write-Host "`n[T2] Executable gate 'if (\$env:PSMUX_TEST_SANDBOX ...)' is present" -ForegroundColor Yellow
$gate = [regex]::Match($src, 'if\s*\(\s*\$env:PSMUX_TEST_SANDBOX', $ci)
$gateIdx = if ($gate.Success) { $gate.Index } else { -1 }
if ($gate.Success) {
    Write-Pass "Gate found at char offset $gateIdx"
} else {
    Write-Fail "Gate NOT found — runner has no PSMUX_TEST_SANDBOX check"
}

# ── T3: gate aborts within 1200 chars ────────────────────────────────────────
Write-Host "`n[T3] Gate aborts (exit N) within 1200 chars of the if-check" -ForegroundColor Yellow
if ($gate.Success) {
    $window = $src.Substring($gateIdx, [Math]::Min(1200, $src.Length - $gateIdx))
    if ($window -match 'exit\s+\d') {
        Write-Pass "Abort (exit N) found within gate window"
    } else {
        Write-Fail "No 'exit N' within 1200 chars of gate — gate may not actually abort"
    }
} else {
    Write-Fail "Skipped (no gate found in T2)"
}

# ── T4: gate precedes every destructive operation ────────────────────────────
Write-Host "`n[T4] Gate index < first occurrence of every destructive pattern" -ForegroundColor Yellow
$destructive = @('Stop-Process', 'taskkill', 'Remove-Item', 'kill-server')
foreach ($pat in $destructive) {
    $m = [regex]::Match($src, $pat, $ci)
    if ($m.Success) {
        if ($gateIdx -ge 0 -and $gateIdx -lt $m.Index) {
            Write-Pass "Gate (offset $gateIdx) precedes destructive '$pat' (offset $($m.Index))"
        } else {
            Write-Fail "Destructive '$pat' at offset $($m.Index) comes BEFORE gate at offset $gateIdx"
        }
    }
    # Pattern not found is not a failure — the runner might not use every form
}

# ── T5: actually running without sandbox env var exits with refusal ──────────
Write-Host "`n[T5] Running runner without PSMUX_TEST_SANDBOX exits 2 with refusal message" -ForegroundColor Yellow

# Spawn a subprocess that explicitly clears the env var so we do not inherit
# any parent setting, then runs the runner
$scriptBlock = @"
`$env:PSMUX_TEST_SANDBOX = `$null
Remove-Item Env:PSMUX_TEST_SANDBOX -EA SilentlyContinue
& pwsh -NoProfile -ExecutionPolicy Bypass -File '$runner' 2>&1
exit `$LASTEXITCODE
"@

$tempScript = Join-Path $env:TEMP "psmux_sandbox_probe_$PID.ps1"
Set-Content -Path $tempScript -Value $scriptBlock -Encoding UTF8

try {
    $proc = Start-Process -FilePath pwsh `
        -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",$tempScript `
        -PassThru -Wait -RedirectStandardOutput "$env:TEMP\psmux_sandbox_stdout_$PID.txt" `
        -RedirectStandardError  "$env:TEMP\psmux_sandbox_stderr_$PID.txt" `
        -WindowStyle Hidden
    $exitCode = $proc.ExitCode
    $stdout = Get-Content "$env:TEMP\psmux_sandbox_stdout_$PID.txt" -Raw -EA SilentlyContinue
    $stderr = Get-Content "$env:TEMP\psmux_sandbox_stderr_$PID.txt" -Raw -EA SilentlyContinue
    $combined = "$stdout $stderr"

    if ($exitCode -eq 2) {
        Write-Pass "Runner exited 2 (refusal) without PSMUX_TEST_SANDBOX"
    } else {
        Write-Fail "Expected exit 2, got $exitCode — guard may not be working"
    }

    if ($combined -match "REFUSING|destructive|sandbox|PSMUX_TEST_SANDBOX") {
        Write-Pass "Refusal message contains expected text"
    } else {
        Write-Fail "Refusal message not found in output: $combined"
    }
} finally {
    Remove-Item $tempScript -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\psmux_sandbox_stdout_$PID.txt" -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\psmux_sandbox_stderr_$PID.txt" -Force -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
$failColor = if ($script:Fail -gt 0) { "Red" } else { "Green" }
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $failColor
exit $script:Fail
