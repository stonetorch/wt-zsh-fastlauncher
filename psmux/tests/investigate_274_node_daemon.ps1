# Issue #274 - Test with actual node + http.server daemon (matches user's repro)
# User reported: node serve --port 5155 producing periodic stdout

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "wedge_node_274"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Log($msg) {
    $stamp = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$stamp] $msg"
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\wedge_test_server.js" -Force -EA SilentlyContinue
}

Cleanup

# Create a node http server that emits periodic stdout (like user's "node serve")
$serverJs = @'
const http = require('http');
const server = http.createServer((req, res) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.url}`);
  res.end('ok');
});
server.listen(0, () => {
  console.log(`Listening on port ${server.address().port}`);
  // Heartbeat output every 100ms to mimic active daemon logging
  setInterval(() => {
    console.log(`[${new Date().toISOString()}] heartbeat: rss=${process.memoryUsage().rss}`);
  }, 100);
});
'@
$serverJs | Set-Content "$env:TEMP\wedge_test_server.js" -Encoding UTF8

Log "Creating session"
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 2
& $PSMUX split-window -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX split-window -t $SESSION
Start-Sleep -Seconds 1

# Start a node daemon in pane 0 (matches user's repro)
Log "Starting node daemon in pane 0"
& $PSMUX send-keys -t "${SESSION}:0.0" "node `"$env:TEMP\wedge_test_server.js`"" Enter
Start-Sleep -Seconds 3

# Verify daemon is running
$cap0 = & $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String
if ($cap0 -match "heartbeat") {
    Log "Node daemon running and emitting heartbeats"
} else {
    Log "Daemon may not have started; capture: $($cap0 -replace "`r?`n", " | ")"
}

# Now run a 3-minute observation
Log "Observing for 3 minutes..."
$startTime = Get-Date
$samples = [System.Collections.ArrayList]::new()
$lastReport = Get-Date

while (((Get-Date) - $startTime).TotalSeconds -lt 180) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1
    $sw.Stop()
    [void]$samples.Add($sw.ElapsedMilliseconds)

    if (((Get-Date) - $lastReport).TotalSeconds -ge 30) {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        $proc = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
        $mem = if ($proc) { [Math]::Round($proc.WorkingSet64 / 1MB, 1) } else { 0 }
        $avg = [Math]::Round(($samples | Select-Object -Last 50 | Measure-Object -Average).Average, 1)
        $max = ($samples | Select-Object -Last 50 | Measure-Object -Maximum).Maximum
        Log ("t=" + $elapsed + "s mem=" + $mem + "MB cli avg=" + $avg + "ms max=" + $max + "ms")
        $lastReport = Get-Date
    }
    Start-Sleep -Milliseconds 500
}

# Check if other panes still respond
& $PSMUX send-keys -t "${SESSION}:0.1" "echo PANE1_AFTER_3MIN" Enter
& $PSMUX send-keys -t "${SESSION}:0.2" "echo PANE2_AFTER_3MIN" Enter
Start-Sleep -Seconds 2

$cap1 = & $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String
$cap2 = & $PSMUX capture-pane -t "${SESSION}:0.2" -p 2>&1 | Out-String
if ($cap1 -match "PANE1_AFTER_3MIN") { Log "Pane 1 still responsive" } else { Log "Pane 1 NOT responsive" }
if ($cap2 -match "PANE2_AFTER_3MIN") { Log "Pane 2 still responsive" } else { Log "Pane 2 NOT responsive" }

# Try fresh attach
Log "Testing fresh attach"
$attachProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 4
if ($attachProc.HasExited) {
    Log "FAIL: fresh attach exited code=$($attachProc.ExitCode)"
} else {
    Log "Fresh attach OK"
    try { Stop-Process -Id $attachProc.Id -Force -EA Stop } catch {}
}

# Kill the node daemon
& $PSMUX send-keys -t "${SESSION}:0.0" "C-c" 2>&1 | Out-Null
Start-Sleep -Seconds 1

Cleanup
Log "DONE"
