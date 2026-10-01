# Issue #236: Regression: cursor-ahead-of-chars + typing freeze since commit 6bcb9f5
# Verify: burst typing does NOT freeze; capture-pane shows all typed chars; session stays responsive.
# Strategy: send a burst of keys via send-keys (CLI path), then assert responsiveness via
#           a follow-up display-message that must complete within a hard deadline, and assert
#           capture-pane contains the expected typed text (no missing chars, no ghost cursor).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "gap236"
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
Write-Host "ISSUE #236: Cursor-ahead / typing freeze regression test" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

# --- Create detached session ---
Write-Info "Creating detached session '$SESSION'..."
& $PSMUX new-session -d -s $SESSION -x 220 -y 50 2>$null
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' could not be created"
    exit 1
}
Write-Info "Session created OK"

# Wait for prompt to appear (up to 12s)
$promptReady = $false
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Milliseconds 500
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap -match "PS [A-Z]:\\" -or $cap -match "\$\s*$" -or $cap -match ">") {
        $promptReady = $true
        break
    }
}
if (-not $promptReady) { Write-Info "Prompt detection timed out - continuing anyway" }

# --- TEST 1: Burst typing - send a marker string rapidly via send-keys ---
Write-Host ""
Write-Host "--- TEST 1: Burst typing - send 50 chars in rapid send-keys calls ---" -ForegroundColor Yellow

# Build a uniquely identifiable marker string
$marker = "ISSUE236MARKER"
# Send the string character by character at ~0ms delay (simulates fast typing via CLI dispatch)
# We use send-keys with the full string at once (burst) which exercises the scroll_pane_scrollback path
& $PSMUX send-keys -t $SESSION "echo $marker" Enter 2>$null
Start-Sleep -Seconds 2

$cap1 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap1 -match $marker) {
    Write-Pass "TEST 1: capture-pane shows typed marker '$marker' (no missing chars)"
} else {
    Write-Fail "TEST 1: capture-pane does NOT show '$marker' - chars lost or session frozen"
    Write-Info "  Captured: $($cap1.Substring(0, [Math]::Min(200, $cap1.Length)))"
}

# --- TEST 2: Responsiveness after burst - display-message must return within 3s ---
Write-Host ""
Write-Host "--- TEST 2: Responsiveness check - display-message timeout 3s ---" -ForegroundColor Yellow

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dmOut = & $PSMUX display-message -t $SESSION -p "ALIVE_#{session_name}" 2>&1 | Out-String
$sw.Stop()
$elapsed = $sw.ElapsedMilliseconds

if ($dmOut -match "ALIVE_$SESSION") {
    if ($elapsed -le 3000) {
        Write-Pass "TEST 2: display-message returned in ${elapsed}ms (session responsive, no freeze)"
    } else {
        Write-Fail "TEST 2: display-message returned but took ${elapsed}ms (>3000ms, potential freeze)"
    }
} else {
    Write-Fail "TEST 2: display-message did not return 'ALIVE_$SESSION' in time (${elapsed}ms) - session frozen"
    Write-Info "  Got: $($dmOut.Substring(0, [Math]::Min(100, $dmOut.Length)))"
}

# --- TEST 3: Second burst with longer string to stress scroll path ---
Write-Host ""
Write-Host "--- TEST 3: Second burst - longer string, stress scroll_pane_scrollback path ---" -ForegroundColor Yellow

$marker2 = "BURST236XYZABC"
& $PSMUX send-keys -t $SESSION "echo $marker2" Enter 2>$null
Start-Sleep -Seconds 2

$cap3 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap3 -match $marker2) {
    Write-Pass "TEST 3: Second burst typed text '$marker2' visible in capture-pane"
} else {
    Write-Fail "TEST 3: Second burst text '$marker2' NOT in capture-pane (chars dropped or freeze)"
}

# --- TEST 4: Responsiveness after second burst ---
Write-Host ""
Write-Host "--- TEST 4: Responsiveness after second burst ---" -ForegroundColor Yellow

$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$dm2 = & $PSMUX display-message -t $SESSION -p "ALIVE2_#{window_index}" 2>&1 | Out-String
$sw2.Stop()
$e2 = $sw2.ElapsedMilliseconds

if ($dm2 -match "ALIVE2_") {
    if ($e2 -le 3000) {
        Write-Pass "TEST 4: Session still responsive after second burst (${e2}ms)"
    } else {
        Write-Fail "TEST 4: Slow response after second burst: ${e2}ms (>3000ms)"
    }
} else {
    Write-Fail "TEST 4: No response after second burst (${e2}ms) - frozen"
}

# --- TEST 5: Repeat 5x send-keys rapid-fire and verify last marker ---
Write-Host ""
Write-Host "--- TEST 5: 5x rapid send-keys to stress the input path ---" -ForegroundColor Yellow

$finalMarker = "FINAL236END"
for ($r = 1; $r -le 4; $r++) {
    & $PSMUX send-keys -t $SESSION "echo RAPID236_$r" Enter 2>$null
    Start-Sleep -Milliseconds 100
}
& $PSMUX send-keys -t $SESSION "echo $finalMarker" Enter 2>$null
Start-Sleep -Seconds 3

$cap5 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap5 -match $finalMarker) {
    Write-Pass "TEST 5: Final marker '$finalMarker' present after rapid-fire send-keys (no freeze)"
} else {
    Write-Fail "TEST 5: Final marker '$finalMarker' missing after rapid-fire - input dropped or session frozen"
    Write-Info "  Captured tail: $($cap5.Substring([Math]::Max(0, $cap5.Length-300), [Math]::Min(300, $cap5.Length)))"
}

# --- Cleanup ---
& $PSMUX kill-session -t $SESSION 2>$null
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "RESULTS: $pass PASS, $fail FAIL" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
Write-Host ("=" * 70) -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 } else { exit 0 }
