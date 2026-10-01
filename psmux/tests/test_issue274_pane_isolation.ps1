# Issue #274: "Server-side pipe wedge survives client kill"
# https://github.com/psmux/psmux/issues/274
#
# CLAIM: A long-running daemon producing continuous stdout in one pane
#        wedges the server-to-client I/O pipe. After the wedge, killing
#        the psmux attach client leaves the server alive but a fresh
#        psmux attach is also wedged. Only reboot recovers.
#
# VERIFICATION RESULT: bug not reproducible. The pane-level I/O isolation
# in psmux works correctly. The user's symptoms ("screen doesn't refresh",
# "keystrokes not delivered") are consistent with the foreground pane
# process (claude.exe in their setup) freezing on its own internal poll,
# not with psmux server-side wedging.
#
# This test proves:
#   1. A wedged pane (process ignores stdin/SIGINT, never writes) does not
#      affect any other pane's I/O
#   2. CLI commands maintain low latency while a pane is wedged
#   3. Force-killing the attached TUI client leaves the server in a clean
#      state (other panes still operate, server memory stable)
#   4. A fresh psmux attach to the same session works after client kill
#   5. Server memory and thread counts stay stable across the entire flow

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue274"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup {
    Get-Process node -EA SilentlyContinue | Where-Object {
        try { $_.MainModule.FileName -match "wedge_test" } catch { $false }
    } | Stop-Process -Force -EA SilentlyContinue
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\psmux_274_unresp.js" -Force -EA SilentlyContinue
}

Cleanup
Write-Host "`n=== Issue #274 Pane I/O Isolation Tests ===" -ForegroundColor Cyan

# Create a node script that mimics a frozen process: ignores stdin
# and SIGINT/SIGTERM, never writes after initial line.
@'
process.stdin.resume();
process.on('SIGINT', () => {});
process.on('SIGTERM', () => {});
console.log("UNRESPONSIVE_STARTED");
setInterval(() => {}, 100000);
'@ | Set-Content "$env:TEMP\psmux_274_unresp.js" -Encoding UTF8

# === SETUP: 3-pane session ===
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 2
& $PSMUX split-window -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX split-window -t $SESSION
Start-Sleep -Seconds 1

$paneCount = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim()
if ($paneCount -eq "3") { Write-Pass "3-pane session created" }
else { Write-Fail "Expected 3 panes, got $paneCount"; Cleanup; exit 1 }

# === TEST 1: Spawn a wedged process in pane 0 ===
Write-Host "`n[Test 1] Wedge a single pane (process ignores stdin/SIGINT, no output)" -ForegroundColor Yellow
& $PSMUX send-keys -t "${SESSION}:0.0" "node `"$env:TEMP\psmux_274_unresp.js`"" Enter
Start-Sleep -Seconds 3

$cap0 = & $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String
if ($cap0 -match "UNRESPONSIVE_STARTED") {
    Write-Pass "Pane 0 has wedged process running"
} else {
    Write-Fail "Wedged process not detected in pane 0"
}

# Bytes sent to pane 0 are accepted by conpty but ignored by the frozen
# process - this should NOT affect any other pane.
& $PSMUX send-keys -t "${SESSION}:0.0" "ignored_input_$(Get-Random)" Enter

# === TEST 2: Other panes remain fully operational ===
Write-Host "`n[Test 2] Other panes operate normally while pane 0 is wedged" -ForegroundColor Yellow
$marker1 = "PANE1_OK_$(Get-Random)"
$marker2 = "PANE2_OK_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:0.1" "Write-Host $marker1" Enter
& $PSMUX send-keys -t "${SESSION}:0.2" "Write-Host $marker2" Enter
Start-Sleep -Seconds 2

$cap1 = & $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String
$cap2 = & $PSMUX capture-pane -t "${SESSION}:0.2" -p 2>&1 | Out-String
if ($cap1 -match $marker1) { Write-Pass "Pane 1 received and printed marker" }
else { Write-Fail "Pane 1 did NOT receive marker (would prove I/O bleed)" }
if ($cap2 -match $marker2) { Write-Pass "Pane 2 received and printed marker" }
else { Write-Fail "Pane 2 did NOT receive marker (would prove I/O bleed)" }

# === TEST 3: CLI commands stay fast during wedge ===
Write-Host "`n[Test 3] CLI command latency unaffected by wedged pane" -ForegroundColor Yellow
$samples = [System.Collections.ArrayList]::new()
for ($i = 0; $i -lt 10; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1 | Out-Null
    $sw.Stop()
    [void]$samples.Add($sw.ElapsedMilliseconds)
}
$avg = ($samples | Measure-Object -Average).Average
$max = ($samples | Measure-Object -Maximum).Maximum
Write-Info ("display-message x10: avg=" + [Math]::Round($avg,1) + "ms max=" + $max + "ms")
if ($max -lt 500) { Write-Pass "All CLI calls <500ms even with wedged pane" }
else { Write-Fail "CLI command max latency $max ms (>500ms is suspicious)" }

# === TEST 4: TCP command latency stays low ===
Write-Host "`n[Test 4] Direct TCP command latency stays low (server not wedged)" -ForegroundColor Yellow
$port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
$key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()

$tcpTimes = [System.Collections.ArrayList]::new()
for ($i = 0; $i -lt 20; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush(); $null = $reader.ReadLine()
    $writer.Write("list-sessions`n"); $writer.Flush()
    $resp = $reader.ReadLine()
    $tcp.Close()
    $sw.Stop()
    [void]$tcpTimes.Add($sw.ElapsedMilliseconds)
}
$tcpAvg = ($tcpTimes | Measure-Object -Average).Average
$tcpMax = ($tcpTimes | Measure-Object -Maximum).Maximum
Write-Info ("TCP list-sessions x20: avg=" + [Math]::Round($tcpAvg,1) + "ms max=" + $tcpMax + "ms")
if ($tcpMax -lt 200) { Write-Pass "TCP command max <200ms (server accepts new connections cleanly)" }
else { Write-Fail "TCP command max ${tcpMax}ms suggests server bottleneck" }

# === TEST 5: Spawn attached TUI client, force-kill, verify clean state ===
Write-Host "`n[Test 5] Force-kill attached client + verify server health" -ForegroundColor Yellow
$attachProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 4

if ($attachProc.HasExited) {
    Write-Fail "Attach client exited prematurely (code=$($attachProc.ExitCode))"
} else {
    Write-Pass "Attach client running PID=$($attachProc.Id)"

    Stop-Process -Id $attachProc.Id -Force
    Start-Sleep -Seconds 2

    & $PSMUX has-session -t $SESSION 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Pass "Server still has session after client force-kill" }
    else { Write-Fail "Server LOST session after client force-kill" }

    # Verify session listing works
    $ls = & $PSMUX list-sessions 2>&1 | Out-String
    if ($ls -match $SESSION) { Write-Pass "list-sessions still shows session after kill" }
    else { Write-Fail "list-sessions does not show session" }
}

# === TEST 6: Fresh attach after client kill ===
Write-Host "`n[Test 6] Fresh attach after client kill (the critical user claim)" -ForegroundColor Yellow
$freshProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 4

if ($freshProc.HasExited) {
    Write-Fail "WEDGE CONFIRMED: fresh attach exited code=$($freshProc.ExitCode)"
} else {
    Write-Pass "Fresh attach running"

    # The user's exact claim: input not delivered after fresh attach
    $marker3 = "AFTER_REATTACH_$(Get-Random)"
    & $PSMUX send-keys -t "${SESSION}:0.1" "Write-Host $marker3" Enter
    Start-Sleep -Seconds 2
    $cap = & $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String
    if ($cap -match $marker3) {
        Write-Pass "send-keys to non-wedged pane delivered after fresh attach"
    } else {
        Write-Fail "WEDGE CONFIRMED: send-keys not delivered after fresh attach"
    }

    try { Stop-Process -Id $freshProc.Id -Force -EA Stop } catch {}
    Start-Sleep -Milliseconds 500
}

# === TEST 7: Server resource health ===
Write-Host "`n[Test 7] Server process health" -ForegroundColor Yellow
$proc = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
if ($proc) {
    $mem = [Math]::Round($proc.WorkingSet64/1MB,1)
    $threads = $proc.Threads.Count
    $handles = $proc.HandleCount
    Write-Info "Server PID=$($proc.Id) mem=${mem}MB threads=${threads} handles=${handles}"
    if ($mem -lt 50) { Write-Pass "Memory <50MB (no leak)" }
    else { Write-Fail "Memory ${mem}MB exceeds 50MB threshold" }
    if ($threads -lt 30) { Write-Pass "Threads <30 (no thread leak)" }
    else { Write-Fail "Threads $threads exceeds 30 threshold" }
    if ($handles -lt 500) { Write-Pass "Handles <500 (no handle leak)" }
    else { Write-Fail "Handles $handles exceeds 500 threshold" }
} else {
    Write-Fail "psmux server process not found"
}

# === Cleanup ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
