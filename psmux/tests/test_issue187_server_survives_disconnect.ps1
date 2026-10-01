# Issue #187: Session server dies on SSH disconnect
#
# Root issue: when the SSH client disconnected (or the controlling terminal
# closed), the psmux server process exited, destroying all sessions.
#
# SSH probe: sshd not available on this machine. PROXY path used.
#
# PROXY: Assert the server survives a client detach/disconnect.
#   1. Start a session.
#   2. Attach a second Start-Process client (simulates an SSH-spawned client).
#   3. Kill that client process (simulates SSH disconnect / SIGHUP).
#   4. has-session must still exit 0 — server survived.
#   5. Send a command and verify pane still responds.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue187_server_survives_disconnect.ps1

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA SilentlyContinue).Source
if (-not $PSMUX) { Write-Host "[FAIL] psmux not found in PATH" -ForegroundColor Red; exit 1 }

$SESSION  = "gap187"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0

function Write-Pass($msg)  { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }
function Write-Skip($msg)  { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info($msg)  { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-PortFile {
    param([string]$Name, [int]$MaxSeconds = 12)
    $deadline = [DateTime]::Now.AddSeconds($MaxSeconds)
    while ([DateTime]::Now -lt $deadline) {
        if (Test-Path "$psmuxDir\$Name.port") { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# ── SSH availability check ───────────────────────────────────────────────────
Write-Host "`n=== Issue #187: server survives client disconnect (SSH proxy test) ===" -ForegroundColor Cyan
$sshAvail = $false
$sshTest = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 localhost "echo SSHPROBE_OK" 2>&1
if ($sshTest -match "SSHPROBE_OK") { $sshAvail = $true }
if (-not $sshAvail) {
    Write-Info "SSH server not available. Running PROXY assertions (client kill + has-session check)."
}

# ── Setup ───────────────────────────────────────────────────────────────────
Cleanup
& $PSMUX new-session -d -s $SESSION -x 220 -y 50
if (-not (Wait-PortFile $SESSION)) {
    Write-Fail "Session '$SESSION' port file never appeared"
    exit 1
}
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session not alive after startup"; exit 1 }
Start-Sleep -Milliseconds 800

# ── [Test 1] Baseline: session alive before attach ───────────────────────────
Write-Host "`n[Test 1] Baseline: has-session exits 0 before any attach" -ForegroundColor Yellow
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "Session '$SESSION' alive before attach"
} else {
    Write-Fail "Session not alive before attach (exit $LASTEXITCODE)"
}

# ── [Test 2] PROXY: attach a client process, then kill it ────────────────────
Write-Host "`n[Test 2] PROXY: spawn attach client then kill it (simulates SSH disconnect)" -ForegroundColor Yellow
# Spawn a detached attach process (it will try to attach; we kill it immediately)
$clientProc = Start-Process -FilePath $PSMUX -ArgumentList "attach-session -t $SESSION" `
    -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 1200
Write-Info "Spawned attach client PID=$($clientProc.Id)"

# Kill it hard — simulates SSH client disconnect / SIGHUP
try {
    Stop-Process -Id $clientProc.Id -Force -EA SilentlyContinue
    Write-Info "Killed attach client PID=$($clientProc.Id)"
} catch {
    Write-Info "Kill error (process may have already exited): $_"
}
Start-Sleep -Milliseconds 1500

# ── [Test 3] PROXY: has-session still 0 after client kill ────────────────────
Write-Host "`n[Test 3] PROXY: has-session exits 0 after client kill (server survived)" -ForegroundColor Yellow
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "PROXY_PASS: Server survived client kill — has-session exits 0"
} else {
    Write-Fail "PROXY_FAIL: Server DIED after client kill — has-session exits $LASTEXITCODE (issue #187 regression)"
}

# ── [Test 4] PROXY: session still responsive after client kill ───────────────
Write-Host "`n[Test 4] PROXY: pane still responds to send-keys after client kill" -ForegroundColor Yellow
$marker = "SURVIVE_$(Get-Random -Maximum 99999)"
& $PSMUX send-keys -t $SESSION "echo $marker" Enter
Start-Sleep -Milliseconds 1200
$cap = (& $PSMUX capture-pane -t $SESSION -p 2>&1) | Out-String
if ($cap -match [regex]::Escape($marker)) {
    Write-Pass "PROXY_PASS: Pane responds after client kill — output '$marker' visible"
} else {
    Write-Fail "Pane NOT responding after client kill — '$marker' not in capture. Server may have died."
}

# ── [Test 5] PROXY: detach-client does not kill server ───────────────────────
Write-Host "`n[Test 5] PROXY: detach-client command does not kill server" -ForegroundColor Yellow
& $PSMUX detach-client -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "PROXY_PASS: Server alive after detach-client"
} else {
    Write-Fail "Server died after detach-client — issue #187 regression"
}

# ── [Test 6] PROXY: second kill-client cycle still survives ─────────────────
Write-Host "`n[Test 6] PROXY: second attach-kill cycle — server still alive" -ForegroundColor Yellow
$clientProc2 = Start-Process -FilePath $PSMUX -ArgumentList "attach-session -t $SESSION" `
    -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 1000
try {
    Stop-Process -Id $clientProc2.Id -Force -EA SilentlyContinue
} catch {}
Start-Sleep -Milliseconds 1500
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "PROXY_PASS: Server survived second attach-kill cycle"
} else {
    Write-Fail "Server died on second attach-kill — issue #187 regression"
}

# ── SSH skip notice ──────────────────────────────────────────────────────────
Write-Skip "REAL SSH PATH: server-survives-SSH-disconnect requires sshd with key auth — not available on this host"

# ── Teardown ─────────────────────────────────────────────────────────────────
Cleanup

Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "RESULTS  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)  Skipped: $($script:TestsSkipped)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""
exit $script:TestsFailed
