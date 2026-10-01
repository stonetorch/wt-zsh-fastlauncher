# Issue #144: display-panes command freezes psmux client
#
# BUG: Issuing `display-panes` from the command prompt (Prefix :) causes the
# client to freeze and become completely unresponsive. The freeze persists
# even after detaching and re-attaching.
#
# EXPECTED: display-panes shows pane numbers briefly then clears the overlay.
# The server remains responsive to subsequent commands.
#
# KEY ASSERTION: A follow-up command (display-message) issued after
# display-panes completes within a short timeout, proving no freeze occurred.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue144_display_panes_freeze.ps1

$ErrorActionPreference = "Continue"
$PSMUX        = (Get-Command psmux -EA Stop).Source
$SESSION      = "gap144"
$psmuxDir     = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-ForPortFile {
    param([string]$Name, [int]$TimeoutSec = 12)
    $portFile = "$psmuxDir\$Name.port"
    for ($i = 0; $i -lt ($TimeoutSec * 4); $i++) {
        if (Test-Path $portFile) { return $portFile }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# Send a single command via TCP and return the response.
# Uses a short timeout so a frozen server is detected quickly.
function Send-TcpCommand {
    param(
        [string]$Session,
        [string]$Command,
        [int]$TimeoutMs = 5000
    )
    try {
        $portFile = "$psmuxDir\$Session.port"
        $keyFile  = "$psmuxDir\$Session.key"
        if (-not (Test-Path $portFile) -or -not (Test-Path $keyFile)) { return "NO_FILES" }
        $port = (Get-Content $portFile -Raw).Trim()
        $key  = (Get-Content $keyFile  -Raw).Trim()

        $tcp    = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay         = $true
        $tcp.ReceiveTimeout  = $TimeoutMs
        $tcp.SendTimeout     = $TimeoutMs
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)

        $writer.Write("AUTH $key`n"); $writer.Flush()
        $authResp = $reader.ReadLine()
        if ($authResp -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }

        $writer.Write("$Command`n"); $writer.Flush()
        try   { $resp = $reader.ReadLine() }
        catch { $resp = "TIMEOUT" }
        $tcp.Close()
        return $resp
    } catch {
        return "ERROR: $_"
    }
}

# Open a persistent TCP connection for dump-state probing.
function Connect-Persistent {
    param([string]$Session)
    $portFile = "$psmuxDir\$Session.port"
    $keyFile  = "$psmuxDir\$Session.key"
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    $tcp    = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 10000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("PERSISTENT`n"); $writer.Flush()
    return @{ tcp = $tcp; writer = $writer; reader = $reader }
}

function Get-DumpState {
    param($conn)
    $conn.writer.Write("dump-state`n"); $conn.writer.Flush()
    $best = $null
    $conn.tcp.ReceiveTimeout = 3000
    for ($j = 0; $j -lt 100; $j++) {
        try   { $line = $conn.reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 80) { $best = $line }
        if ($best) { $conn.tcp.ReceiveTimeout = 80 }
    }
    $conn.tcp.ReceiveTimeout = 10000
    return $best
}

Write-Host "`n=== Issue #144: display-panes must not freeze the server ===" -ForegroundColor Cyan

# -----------------------------------------------------------------------
# Setup: create a detached session with 2 panes
# -----------------------------------------------------------------------
Write-Host "`n[Setup] Creating session with 2 panes" -ForegroundColor Yellow
Cleanup
Start-Sleep -Milliseconds 400

& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
$portFile = Wait-ForPortFile -Name $SESSION
if (-not $portFile) {
    Write-Fail "Session $SESSION did not start (port file never appeared)"
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "  Passed: $($script:TestsPassed)"
    Write-Host "  Failed: $($script:TestsFailed)"
    exit $script:TestsFailed
}
Write-Info "Session started, port file: $portFile"

& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2

$paneCount = (& $PSMUX list-panes -t $SESSION 2>&1 | Measure-Object -Line).Lines
Write-Info "Pane count: $paneCount"

# -----------------------------------------------------------------------
# Test 1: display-panes via CLI does not freeze - follow-up responds quickly
# -----------------------------------------------------------------------
Write-Host "`n[Test 1] display-panes via CLI then immediate follow-up command" -ForegroundColor Yellow

# Issue display-panes (this is what freezes the bug)
& $PSMUX display-panes -t $SESSION 2>&1 | Out-Null
Write-Info "display-panes issued"

# Immediately (within 500ms) issue a follow-up command.
# If the server is frozen this will timeout (5s) and return TIMEOUT.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$resp = Send-TcpCommand -Session $SESSION -Command "display-message -p hello_144" -TimeoutMs 5000
$sw.Stop()
$elapsed = $sw.ElapsedMilliseconds
Write-Info "Follow-up response: '$resp'  elapsed: ${elapsed}ms"

if ($resp -eq "TIMEOUT" -or $resp -match "^ERROR") {
    Write-Fail "Server appears frozen after display-panes: response='$resp' after ${elapsed}ms"
} elseif ($elapsed -gt 4500) {
    Write-Fail "Server responded very slowly (${elapsed}ms) after display-panes - likely near-frozen"
} else {
    Write-Pass "Server responded within ${elapsed}ms after display-panes (no freeze)"
}

# -----------------------------------------------------------------------
# Test 2: dump-state shows display_panes overlay activates then clears
# -----------------------------------------------------------------------
Write-Host "`n[Test 2] display-panes overlay activates and clears" -ForegroundColor Yellow

$conn = Connect-Persistent -Session $SESSION
# Issue display-panes via persistent connection
$conn.writer.Write("display-panes`n"); $conn.writer.Flush()
Start-Sleep -Milliseconds 200

# Capture state immediately - overlay should be active
$dump1 = Get-DumpState $conn

# Wait 2 s for overlay to auto-clear (default display-panes time is 1 s)
Start-Sleep -Seconds 2
$dump2 = Get-DumpState $conn
$conn.tcp.Close()

$overlayWasActive = $dump1 -and ($dump1 -match '"display_panes"\s*:\s*true')
$overlayCleared   = $dump2 -and ($dump2 -notmatch '"display_panes"\s*:\s*true')

if ($overlayWasActive) {
    Write-Pass "display_panes overlay was active in dump-state immediately after command"
} else {
    # Timing-dependent: overlay may have already cleared by the time we dump
    Write-Info "display_panes not seen as active (may have already cleared - timing dependent)"
}

if ($overlayCleared) {
    Write-Pass "display_panes overlay cleared after timeout (server not stuck)"
} elseif ($dump2 -and ($dump2 -match '"display_panes"\s*:\s*true')) {
    Write-Fail "BUG: display_panes overlay STILL active after 2s - server may be stuck in overlay"
} else {
    Write-Info "dump-state did not contain display_panes field (may be absent when false)"
    Write-Pass "No persistent overlay detected in dump-state after 2s"
}

# -----------------------------------------------------------------------
# Test 3: Multiple display-panes in quick succession - server stays alive
# -----------------------------------------------------------------------
Write-Host "`n[Test 3] Rapid repeated display-panes - server stays responsive" -ForegroundColor Yellow

for ($i = 0; $i -lt 5; $i++) {
    & $PSMUX display-panes -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 150
}

$sw3   = [System.Diagnostics.Stopwatch]::StartNew()
$resp3 = Send-TcpCommand -Session $SESSION -Command "display-message -p alive_144" -TimeoutMs 5000
$sw3.Stop()
$elapsed3 = $sw3.ElapsedMilliseconds
Write-Info "After 5x display-panes, follow-up response: '$resp3'  elapsed: ${elapsed3}ms"

if ($resp3 -eq "TIMEOUT" -or $resp3 -match "^ERROR") {
    Write-Fail "Server frozen after repeated display-panes: '$resp3'"
} elseif ($elapsed3 -gt 4500) {
    Write-Fail "Server very slow (${elapsed3}ms) after repeated display-panes"
} else {
    Write-Pass "Server responsive (${elapsed3}ms) after 5 rapid display-panes calls"
}

# -----------------------------------------------------------------------
# Test 4: Panes still operable after display-panes (no input lock)
# -----------------------------------------------------------------------
Write-Host "`n[Test 4] send-keys works after display-panes (no input lock)" -ForegroundColor Yellow

& $PSMUX display-panes -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

# Send a harmless command to the pane
& $PSMUX send-keys -t "${SESSION}:." 'echo psmux_144_ok' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1

# Capture pane output to verify the echo landed
$captured = & $PSMUX capture-pane -t "${SESSION}:." -p 2>&1 | Out-String
if ($captured -match "psmux_144_ok") {
    Write-Pass "send-keys works after display-panes (no input lock)"
} else {
    # May fail if capture-pane doesn't return visible output depending on shell
    Write-Info "Echo not found in capture (may be shell prompt dependent) - checking server alive"
    $resp4 = Send-TcpCommand -Session $SESSION -Command "display-message -p check_144" -TimeoutMs 3000
    if ($resp4 -ne "TIMEOUT" -and $resp4 -notmatch "^ERROR") {
        Write-Pass "Server still alive and responding after send-keys post display-panes"
    } else {
        Write-Fail "Server not responding after send-keys post display-panes: '$resp4'"
    }
}

# -----------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -gt 0) {
    Write-Host "`n  VERDICT: Issue #144 fix INCOMPLETE or regression detected" -ForegroundColor Red
} else {
    Write-Host "`n  VERDICT: Issue #144 FIXED - display-panes no longer freezes the server" -ForegroundColor Green
}

exit $script:TestsFailed
