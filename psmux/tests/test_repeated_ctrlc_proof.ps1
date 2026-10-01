# Repeated Ctrl+C proof test
#
# Bug: pressing Ctrl+C repeatedly at a PowerShell (PSReadLine) prompt inside a
# psmux pane only cancelled the input line on the FIRST press; every subsequent
# Ctrl+C was silently dropped.
#
# Root cause: send_ctrl_c_event() re-enabled ENABLE_PROCESSED_INPUT on the
# shell's ConPTY console (to make GenerateConsoleCtrlEvent fire) and never
# restored it.  PSReadLine deliberately runs the console RAW so it can read
# Ctrl+C as a key event; once the flag is stuck on, the raw 0x03 byte is
# swallowed as a no-op CTRL_C_EVENT at a bare prompt instead of reaching
# PSReadLine, so only the first press cancelled the line.
#
# Fix: restore the shell's original (raw) console mode after firing the signal.
#
# This test hosts psmux under a REAL pseudoconsole (exactly like Windows
# Terminal) so Ctrl+C travels the genuine keyboard path (0x03 byte -> ConPTY).
# A WriteConsoleInput injector CANNOT reproduce this bug because it bypasses
# the console mode that the bug depends on.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "repeated_ctrlc_proof"
$psmuxDir = "$env:USERPROFILE\.psmux"
$ctrl = "$env:TEMP\conpty_ctrl.txt"
$hostExe = "$env:TEMP\conpty_ctrlc_host.exe"
$hostSrc = Join-Path $PSScriptRoot "conpty_ctrlc_host.cs"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

function Stop-Host {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $hp = Get-Content "$env:TEMP\conpty_proof_pid.txt" -EA SilentlyContinue
    if ($hp) { try { Stop-Process -Id $hp -Force -EA SilentlyContinue } catch {} }
    Get-Process conpty_ctrlc_host -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 300
}

# --- Compile the ConPTY host (once) ---
if (-not (Test-Path $hostExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    }
    & $csc /nologo /optimize /out:$hostExe $hostSrc 2>&1 | Out-Null
}
if (-not (Test-Path $hostExe)) { Write-Fail "could not compile ConPTY host"; exit 1 }

Stop-Host
if ([System.IO.File]::Exists($ctrl)) { [System.IO.File]::Delete($ctrl) }
[System.IO.File]::WriteAllText($ctrl, "")

Write-Host "`n=== Repeated Ctrl+C proof (psmux under a real ConPTY) ===" -ForegroundColor Cyan

# --- Host psmux under the pseudoconsole, exactly like Windows Terminal ---
$h = Start-Process -FilePath $hostExe -ArgumentList "`"$PSMUX`"","new-session","-s",$S -PassThru -WindowStyle Hidden
$h.Id | Set-Content "$env:TEMP\conpty_proof_pid.txt"
Start-Sleep -Seconds 6
& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "psmux session did not start under ConPTY"; Stop-Host; exit 1 }
Write-Pass "psmux session running under a real pseudoconsole"

# === TEST 1: 8 repeated Ctrl+C at the prompt each cancel their line ===
Write-Host "`n[Test 1] 8 repeated Ctrl+C at the PSReadLine prompt" -ForegroundColor Yellow
$through = 0
for ($i = 1; $i -le 8; $i++) {
    $marker = "MK${i}ZZ"
    Add-Content $ctrl "TYPE $marker`n"; Start-Sleep -Milliseconds 600
    Add-Content $ctrl "CTRLC 1`n";      Start-Sleep -Milliseconds 900
    $cap = & $PSMUX capture-pane -t $S -p 2>&1 | Out-String
    if ($cap -match "$marker\^C") { $through++ }
}
if ($through -eq 8) { Write-Pass "all 8 repeated Ctrl+C cancelled their line ($through/8)" }
else { Write-Fail "only $through/8 Ctrl+C got through (bug: typically 1/8)" }

# === TEST 2: Ctrl+C still interrupts a running child (regression guard, #346) ===
Write-Host "`n[Test 2] Ctrl+C interrupts a running child (ping)" -ForegroundColor Yellow
Add-Content $ctrl "CR`n"; Start-Sleep -Milliseconds 800
Add-Content $ctrl "TEXT ping -n 30 127.0.0.1`n"; Start-Sleep -Seconds 3
$running = (& $PSMUX capture-pane -t $S -p 2>&1 | Out-String) -match "Reply from 127.0.0.1"
Add-Content $ctrl "CTRLC 1`n"; Start-Sleep -Seconds 3
$cap = & $PSMUX capture-pane -t $S -p 2>&1 | Out-String
if ($running -and ($cap -match "Control-C")) { Write-Pass "Ctrl+C interrupted the running ping" }
else { Write-Fail "ping interrupt regressed (running=$running)" }

# === TEST 3: single Ctrl+C still cancels (sanity) ===
Write-Host "`n[Test 3] single Ctrl+C cancels the prompt line" -ForegroundColor Yellow
Add-Content $ctrl "TYPE LONELYMARK`n"; Start-Sleep -Milliseconds 700
Add-Content $ctrl "CTRLC 1`n"; Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $S -p 2>&1 | Out-String
if ($cap -match "LONELYMARK\^C") { Write-Pass "single Ctrl+C cancels the line" }
else { Write-Fail "single Ctrl+C did not cancel" }

Stop-Host
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
