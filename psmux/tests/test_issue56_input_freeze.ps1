# Issue #56: Not responsive to any input in window, just freeze
# Verify: a freshly created pane accepts send-keys input and capture-pane reflects it.
# The original report: new-session created a window that ignored all keyboard input
# (cursor froze, could only detach with prefix+d).
# Strategy: create a session, send a unique marker + Enter via send-keys (CLI path),
#           poll capture-pane for the marker, assert it appears within a timeout,
#           then do a follow-up command to confirm continued responsiveness.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "gap56"
$pass = 0; $fail = 0

function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green; $script:pass++ }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:fail++ }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }

# Cleanup any leftover
& $PSMUX kill-session -t $SESSION 2>$null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "ISSUE #56: Pane input freeze test" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

# --- Create detached session ---
Write-Info "Creating detached session '$SESSION'..."
& $PSMUX new-session -d -s $SESSION -x 200 -y 40 2>$null
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' could not be created"
    exit 1
}
Write-Info "Session created OK"

# Poll for port file up to 12s (server startup)
$portFile = "$psmuxDir\$SESSION.port"
$portReady = $false
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $portFile) { $portReady = $true; break }
}
Write-Info "Port file ready: $portReady"

# --- TEST 1: Pane accepts input - send marker, assert in capture-pane ---
Write-Host ""
Write-Host "--- TEST 1: Pane accepts send-keys input ---" -ForegroundColor Yellow

$marker1 = "ISSUE56INPUT_$(Get-Random -Maximum 9999)"
& $PSMUX send-keys -t $SESSION "echo $marker1" Enter 2>$null

# Poll capture-pane for up to 8s
$found1 = $false
for ($i = 0; $i -lt 16; $i++) {
    Start-Sleep -Milliseconds 500
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap -match $marker1) { $found1 = $true; break }
}

if ($found1) {
    Write-Pass "TEST 1: Marker '$marker1' appeared in capture-pane (pane IS responsive to input)"
} else {
    Write-Fail "TEST 1: Marker '$marker1' NOT found after 8s - pane is FROZEN / not accepting input"
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    Write-Info "  capture-pane content: $($cap.Substring(0, [Math]::Min(300, $cap.Length)))"
}

# --- TEST 2: Follow-up command returns promptly (< 3s) ---
Write-Host ""
Write-Host "--- TEST 2: Follow-up command responsiveness after input test ---" -ForegroundColor Yellow

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dmOut = & $PSMUX display-message -t $SESSION -p "RESPONSIVE_#{session_name}" 2>&1 | Out-String
$sw.Stop()
$elapsed = $sw.ElapsedMilliseconds

if ($dmOut -match "RESPONSIVE_$SESSION" -and $elapsed -le 3000) {
    Write-Pass "TEST 2: display-message returned 'RESPONSIVE_$SESSION' in ${elapsed}ms (session alive)"
} elseif ($dmOut -match "RESPONSIVE_$SESSION") {
    Write-Fail "TEST 2: display-message responded but slow: ${elapsed}ms (>3000ms)"
} else {
    Write-Fail "TEST 2: display-message did not respond within timeout (${elapsed}ms)"
    Write-Info "  Got: $($dmOut.Substring(0, [Math]::Min(100, $dmOut.Length)))"
}

# --- TEST 3: Second send-keys - confirm pane still accepts input (not a one-shot) ---
Write-Host ""
Write-Host "--- TEST 3: Second send-keys - pane continues accepting input ---" -ForegroundColor Yellow

$marker2 = "ISSUE56SECOND_$(Get-Random -Maximum 9999)"
& $PSMUX send-keys -t $SESSION "echo $marker2" Enter 2>$null

$found2 = $false
for ($i = 0; $i -lt 16; $i++) {
    Start-Sleep -Milliseconds 500
    $cap2 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap2 -match $marker2) { $found2 = $true; break }
}

if ($found2) {
    Write-Pass "TEST 3: Second marker '$marker2' appeared - pane remains responsive"
} else {
    Write-Fail "TEST 3: Second marker '$marker2' NOT found - pane froze after first input"
}

# --- TEST 4: has-session returns 0 (session still alive, not crashed) ---
Write-Host ""
Write-Host "--- TEST 4: Session is still alive after input tests ---" -ForegroundColor Yellow

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "TEST 4: has-session returns 0 - session alive throughout tests"
} else {
    Write-Fail "TEST 4: has-session returned non-zero - session died during input test"
}

# --- Cleanup ---
& $PSMUX kill-session -t $SESSION 2>$null
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "RESULTS: $pass PASS, $fail FAIL" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
Write-Host ("=" * 70) -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 } else { exit 0 }
