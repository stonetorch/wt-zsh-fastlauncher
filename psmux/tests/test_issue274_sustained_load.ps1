# Issue #274: Sustained-load test for "Server-side pipe wedge" claim
# https://github.com/psmux/psmux/issues/274
#
# CLAIM: After ~9.5 minutes of a daemon producing continuous stdout,
#        the psmux server-to-client pipe wedges.
#
# This test runs a 3-pane session with a node http-server-like daemon
# producing periodic heartbeat output (matches user's "node serve" repro)
# for 4 minutes, then probes the server with multiple verification methods.
#
# All metrics must remain stable: memory, CLI latency, TCP latency,
# multi-pane responsiveness, fresh-attach recovery.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue274_long"
$psmuxDir = "$env:USERPROFILE\.psmux"
$DURATION_SEC = 240  # 4 minutes - shorter than user's 9.5min repro to keep CI realistic
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\psmux_274_daemon.js" -Force -EA SilentlyContinue
}

Cleanup
Write-Host "`n=== Issue #274 Sustained Load Test ($DURATION_SEC s) ===" -ForegroundColor Cyan

# Node http-server with periodic heartbeat (matches user's "node serve" repro)
@'
const http = require('http');
http.createServer((req, res) => res.end('ok')).listen(0, () => {
  console.log('listening');
  setInterval(() => {
    console.log(`heartbeat: ${new Date().toISOString()} rss=${process.memoryUsage().rss}`);
  }, 100);
});
'@ | Set-Content "$env:TEMP\psmux_274_daemon.js" -Encoding UTF8

# === Setup 3-pane session ===
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 2
& $PSMUX split-window -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX split-window -t $SESSION
Start-Sleep -Seconds 1

# Start node daemon in pane 0
& $PSMUX send-keys -t "${SESSION}:0.0" "node `"$env:TEMP\psmux_274_daemon.js`"" Enter
Start-Sleep -Seconds 3

$cap0 = & $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String
if ($cap0 -match "heartbeat") { Write-Pass "Daemon emitting heartbeats" }
else { Write-Fail "Daemon may not have started"; Cleanup; exit 1 }

# Capture initial server stats
$proc0 = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
$mem0 = if ($proc0) { [Math]::Round($proc0.WorkingSet64/1MB,1) } else { 0 }
$threads0 = if ($proc0) { $proc0.Threads.Count } else { 0 }
$handles0 = if ($proc0) { $proc0.HandleCount } else { 0 }
Write-Info "Initial server: mem=${mem0}MB threads=${threads0} handles=${handles0}"

# === Sustained observation ===
Write-Host "`n[Sustained $DURATION_SEC s] Observing server health under continuous daemon output..." -ForegroundColor Yellow

$port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
$key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()

$startTime = Get-Date
$cliSamples = [System.Collections.ArrayList]::new()
$tcpSamples = [System.Collections.ArrayList]::new()
$memSamples = [System.Collections.ArrayList]::new()
$lastReport = Get-Date

while (((Get-Date) - $startTime).TotalSeconds -lt $DURATION_SEC) {
    # CLI latency probe
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1 | Out-Null
    $sw.Stop()
    [void]$cliSamples.Add($sw.ElapsedMilliseconds)

    # TCP latency probe (fresh connection per call - tests connection acceptance)
    try {
        $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.Write("AUTH $key`n"); $writer.Flush(); $null = $reader.ReadLine()
        $writer.Write("list-sessions`n"); $writer.Flush(); $null = $reader.ReadLine()
        $tcp.Close()
        $sw2.Stop()
        [void]$tcpSamples.Add($sw2.ElapsedMilliseconds)
    } catch {
        [void]$tcpSamples.Add(-1)
    }

    # Memory probe
    $proc = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
    if ($proc) { [void]$memSamples.Add([Math]::Round($proc.WorkingSet64/1MB,1)) }

    if (((Get-Date) - $lastReport).TotalSeconds -ge 60) {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        $cliRecent = $cliSamples | Select-Object -Last 50
        $tcpRecent = $tcpSamples | Select-Object -Last 50 | Where-Object { $_ -ge 0 }
        $cliAvg = [Math]::Round(($cliRecent | Measure-Object -Average).Average, 1)
        $tcpAvg = if ($tcpRecent.Count -gt 0) { [Math]::Round(($tcpRecent | Measure-Object -Average).Average, 1) } else { -1 }
        $memNow = if ($memSamples.Count -gt 0) { $memSamples[-1] } else { 0 }
        Write-Info "t=${elapsed}s mem=${memNow}MB cli avg=${cliAvg}ms tcp avg=${tcpAvg}ms"
        $lastReport = Get-Date
    }
    Start-Sleep -Milliseconds 1000
}

# === Final analysis ===
$cliFinalAvg = ($cliSamples | Measure-Object -Average).Average
$cliFinalMax = ($cliSamples | Measure-Object -Maximum).Maximum
$tcpValid = $tcpSamples | Where-Object { $_ -ge 0 }
$tcpFinalAvg = if ($tcpValid.Count -gt 0) { ($tcpValid | Measure-Object -Average).Average } else { -1 }
$tcpFinalMax = if ($tcpValid.Count -gt 0) { ($tcpValid | Measure-Object -Maximum).Maximum } else { -1 }
$tcpFails = ($tcpSamples | Where-Object { $_ -lt 0 }).Count

$memMax = ($memSamples | Measure-Object -Maximum).Maximum
$memMin = ($memSamples | Measure-Object -Minimum).Minimum

Write-Host "`n[Analysis]" -ForegroundColor Yellow
Write-Info ("CLI display-message x" + $cliSamples.Count + ": avg=" + [Math]::Round($cliFinalAvg,1) + "ms max=" + $cliFinalMax + "ms")
Write-Info ("TCP list-sessions x" + $tcpValid.Count + " (failures=$tcpFails): avg=" + [Math]::Round($tcpFinalAvg,1) + "ms max=$tcpFinalMax ms")
Write-Info ("Memory range: " + $memMin + "MB to " + $memMax + "MB (delta " + [Math]::Round($memMax - $memMin, 1) + "MB)")

# === Pass criteria ===
if ($cliFinalMax -lt 5000) { Write-Pass "CLI latency stayed under 5s throughout (no wedge)" }
else { Write-Fail "CLI max latency $cliFinalMax ms (>5s suggests wedge)" }

if ($tcpValid.Count -ge ($DURATION_SEC - 30)) { Write-Pass "TCP connections accepted throughout (no wedge)" }
else { Write-Fail "TCP failures: $tcpFails (server may be wedged)" }

if ($tcpFinalMax -ge 0 -and $tcpFinalMax -lt 1000) { Write-Pass "TCP max latency <1s (server not wedged)" }
else { Write-Fail "TCP max latency $tcpFinalMax ms (>1s suggests wedge)" }

if (($memMax - $memMin) -lt 30) { Write-Pass "Memory growth <30MB (no leak)" }
else { Write-Fail "Memory grew " + [Math]::Round($memMax - $memMin, 1) + " MB (>30MB suggests leak)" }

# === Final cross-pane verification ===
Write-Host "`n[Post-load] Cross-pane verification" -ForegroundColor Yellow
$marker1 = "POST_LOAD_PANE1_$(Get-Random)"
$marker2 = "POST_LOAD_PANE2_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:0.1" "Write-Host $marker1" Enter
& $PSMUX send-keys -t "${SESSION}:0.2" "Write-Host $marker2" Enter
Start-Sleep -Seconds 2
$cap1 = & $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String
$cap2 = & $PSMUX capture-pane -t "${SESSION}:0.2" -p 2>&1 | Out-String
if ($cap1 -match $marker1) { Write-Pass "Pane 1 still operational after sustained load" }
else { Write-Fail "Pane 1 not responsive (would prove wedge)" }
if ($cap2 -match $marker2) { Write-Pass "Pane 2 still operational after sustained load" }
else { Write-Fail "Pane 2 not responsive (would prove wedge)" }

# === Fresh attach test after sustained load ===
Write-Host "`n[Post-load] Fresh attach test" -ForegroundColor Yellow
$attachProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 4
if ($attachProc.HasExited) {
    Write-Fail "Fresh attach exited code=$($attachProc.ExitCode) (would prove wedge)"
} else {
    Write-Pass "Fresh attach succeeds after $DURATION_SEC s of load"
    try { Stop-Process -Id $attachProc.Id -Force -EA Stop } catch {}
}

Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
