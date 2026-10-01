# Issue #402 Claim A/C: run-shell behavior on Windows
# Reporter: bind-key ... run-shell -b "psmux new-window ..." does NOTHING (no window created)
# Reporter: run-shell -b "Start-Sleep ...; psmux send-keys pi Enter" (a PowerShell command) also unreliable
# This test drives run-shell DIRECTLY via CLI (not via bind) to isolate run-shell's command execution.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue402RS"
$psmuxDir = "$env:USERPROFILE\.psmux"
$DIR = "$env:USERPROFILE\psmux_test402\project"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Cleanup
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

function WinCount {
    (& $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Measure-Object -Line).Lines
}

Write-Host "`n=== Issue #402 Claim A/C: run-shell via CLI ===" -ForegroundColor Cyan

# --- TEST 1: run-shell -b "psmux new-window ..." (async) ---
Write-Host "`n[Test 1] run-shell -b ""psmux new-window -n RS_ASYNC -c DIR""" -ForegroundColor Yellow
$before = WinCount
Write-Info "windows before: $before"
& $PSMUX run-shell -t $SESSION -b "psmux new-window -n RS_ASYNC -c '$DIR'" 2>&1 | Out-Null
Start-Sleep -Seconds 3
$after = WinCount
Write-Info "windows after: $after"
$wins = & $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Out-String
Write-Info "windows: $($wins -replace "`r?`n"," ")"
if ($wins -match "RS_ASYNC") { Write-Pass "run-shell -b created RS_ASYNC window" }
else { Write-Fail "REPRODUCED: run-shell -b did NOT create RS_ASYNC window" }

# --- TEST 2: run-shell (synchronous, no -b) "psmux new-window ..." ---
Write-Host "`n[Test 2] run-shell (sync) ""psmux new-window -n RS_SYNC -c DIR""" -ForegroundColor Yellow
& $PSMUX run-shell -t $SESSION "psmux new-window -n RS_SYNC -c '$DIR'" 2>&1 | Out-Null
Start-Sleep -Seconds 3
$wins2 = & $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Out-String
Write-Info "windows: $($wins2 -replace "`r?`n"," ")"
if ($wins2 -match "RS_SYNC") { Write-Pass "run-shell (sync) created RS_SYNC window" }
else { Write-Fail "REPRODUCED: run-shell (sync) did NOT create RS_SYNC window" }

# --- TEST 3: What shell does run-shell use? Write a marker file two ways ---
Write-Host "`n[Test 3] Which shell interprets run-shell? (cmd vs pwsh)" -ForegroundColor Yellow
$markCmd = "$env:TEMP\psmux402_cmd_marker.txt"
$markPwsh = "$env:TEMP\psmux402_pwsh_marker.txt"
Remove-Item $markCmd,$markPwsh -Force -EA SilentlyContinue
# cmd.exe syntax: echo hi> file  (works in cmd, differs in pwsh)
& $PSMUX run-shell -t $SESSION "echo CMDSHELL> `"$markCmd`"" 2>&1 | Out-Null
# pwsh syntax: Set-Content
& $PSMUX run-shell -t $SESSION "Set-Content -Path '$markPwsh' -Value PWSHSHELL" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cmdRan = Test-Path $markCmd
$pwshRan = Test-Path $markPwsh
Write-Info "cmd-syntax marker file exists: $cmdRan"
Write-Info "pwsh-syntax marker file exists: $pwshRan"
if ($cmdRan) { Write-Info "run-shell appears to use CMD.EXE" }
if ($pwshRan) { Write-Info "run-shell appears to use PowerShell" }
if (-not $cmdRan -and -not $pwshRan) { Write-Info "run-shell ran NEITHER - may not spawn a shell at all" }

# --- TEST 4: run-shell with a PowerShell-only command (reporter's Claim C style) ---
Write-Host "`n[Test 4] run-shell -b ""Start-Sleep -Milliseconds 500; psmux new-window -n RS_PSCMD -c DIR""" -ForegroundColor Yellow
& $PSMUX run-shell -t $SESSION -b "Start-Sleep -Milliseconds 500; psmux new-window -n RS_PSCMD -c '$DIR'" 2>&1 | Out-Null
Start-Sleep -Seconds 3
$wins4 = & $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Out-String
Write-Info "windows: $($wins4 -replace "`r?`n"," ")"
if ($wins4 -match "RS_PSCMD") { Write-Pass "run-shell with Start-Sleep (pwsh) created RS_PSCMD window" }
else { Write-Fail "REPRODUCED: run-shell with pwsh-only syntax (Start-Sleep) did NOT create window" }

Cleanup
Remove-Item $markCmd,$markPwsh -Force -EA SilentlyContinue
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
