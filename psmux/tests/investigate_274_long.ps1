# Issue #274 - long-duration test (5 minutes)
# Watch for memory growth, latency degradation, pipe wedge under continuous stdout

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "wedge_long_274"
$psmuxDir = "$env:USERPROFILE\.psmux"
$DURATION_SEC = 300  # 5 minutes (user reports 9.5 min repro; should see trend by 5)

function Log($msg) {
    $stamp = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$stamp] $msg"
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Cleanup

# Create 3-pane session like user's setup
Log "Creating session"
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 2
& $PSMUX split-window -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX split-window -t $SESSION
Start-Sleep -Seconds 1

# Start spammers in all 3 panes (mimicking 3 daemons)
$spamCmd = '$i=0; while($true) { Write-Host ("LINE_" + $i + "_" + (Get-Date -Format HHmmssfff) + "_" + (Get-Random)); $i++ }'
& $PSMUX send-keys -t "${SESSION}:0.0" $spamCmd Enter
& $PSMUX send-keys -t "${SESSION}:0.1" $spamCmd Enter
& $PSMUX send-keys -t "${SESSION}:0.2" $spamCmd Enter

Start-Sleep -Seconds 3

# Open a PERSISTENT TCP connection (mimicking what attached TUI does)
$port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
$key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
Log "Server port=$port"

$tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
$tcp.NoDelay = $true; $tcp.ReceiveTimeout = 30000
$stream = $tcp.GetStream()
$writer = [System.IO.StreamWriter]::new($stream)
$reader = [System.IO.StreamReader]::new($stream)
$writer.Write("AUTH $key`n"); $writer.Flush()
$null = $reader.ReadLine()
$writer.Write("PERSISTENT`n"); $writer.Flush()
Log "PERSISTENT connection established"

$startTime = Get-Date
$samples = [System.Collections.ArrayList]::new()
$dumpStateLatencies = [System.Collections.ArrayList]::new()
$lastReport = Get-Date

while (((Get-Date) - $startTime).TotalSeconds -lt $DURATION_SEC) {
    # Sample CLI command latency (separate connection per call)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1
    $sw.Stop()
    [void]$samples.Add($sw.ElapsedMilliseconds)

    # Sample dump-state latency on persistent connection (mimics TUI frame request)
    try {
        $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
        $writer.Write("dump-state`n"); $writer.Flush()
        $tcp.ReceiveTimeout = 5000
        $best = $null
        for ($k = 0; $k -lt 50; $k++) {
            try { $line = $reader.ReadLine() } catch { break }
            if ($null -eq $line) { break }
            if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line; break }
        }
        $sw2.Stop()
        if ($best) { [void]$dumpStateLatencies.Add($sw2.ElapsedMilliseconds) }
    } catch {
        Log "dump-state EXCEPTION: $_"
        break
    }

    # Report every 30 seconds
    if (((Get-Date) - $lastReport).TotalSeconds -ge 30) {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        $proc = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
        $mem = if ($proc) { [Math]::Round($proc.WorkingSet64 / 1MB, 1) } else { 0 }
        $cliAvg = if ($samples.Count -gt 0) { [Math]::Round(($samples | Select-Object -Last 50 | Measure-Object -Average).Average, 1) } else { 0 }
        $cliMax = if ($samples.Count -gt 0) { ($samples | Select-Object -Last 50 | Measure-Object -Maximum).Maximum } else { 0 }
        $dsAvg = if ($dumpStateLatencies.Count -gt 0) { [Math]::Round(($dumpStateLatencies | Select-Object -Last 50 | Measure-Object -Average).Average, 1) } else { 0 }
        $dsMax = if ($dumpStateLatencies.Count -gt 0) { ($dumpStateLatencies | Select-Object -Last 50 | Measure-Object -Maximum).Maximum } else { 0 }
        Log ("t=" + $elapsed + "s mem=" + $mem + "MB cli avg=" + $cliAvg + "ms max=" + $cliMax + "ms dump-state avg=" + $dsAvg + "ms max=" + $dsMax + "ms")
        $lastReport = Get-Date
    }

    Start-Sleep -Milliseconds 500
}

$tcp.Close()

# Final stats
Log "=== FINAL STATS ==="
$cliAvg = ($samples | Measure-Object -Average).Average
$cliMax = ($samples | Measure-Object -Maximum).Maximum
$dsAvg = ($dumpStateLatencies | Measure-Object -Average).Average
$dsMax = ($dumpStateLatencies | Measure-Object -Maximum).Maximum
Log ("Total samples=" + $samples.Count + " dump-state samples=" + $dumpStateLatencies.Count)
Log ("CLI display-message: avg=" + [Math]::Round($cliAvg,1) + "ms max=" + $cliMax + "ms")
Log ("dump-state: avg=" + [Math]::Round($dsAvg,1) + "ms max=" + $dsMax + "ms")

$proc = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
if ($proc) { Log ("Server final mem=" + [Math]::Round($proc.WorkingSet64/1MB,1) + "MB") }

# Test fresh attach AFTER long load
Log "Testing fresh attach after long load"
$attachProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 4
if ($attachProc.HasExited) {
    Log ("FAIL: fresh attach exited code=" + $attachProc.ExitCode)
} else {
    Log "Fresh attach running"
    & $PSMUX send-keys -t "${SESSION}:0.0" "C-c" 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    & $PSMUX send-keys -t "${SESSION}:0.0" "echo MARKER_AFTER_LONG" Enter
    Start-Sleep -Seconds 2
    $cap = & $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String
    if ($cap -match "MARKER_AFTER_LONG") { Log "PASS: send-keys still works after long load" }
    else { Log "FAIL: send-keys not delivered" }
    try { Stop-Process -Id $attachProc.Id -Force -EA Stop } catch {}
}

Cleanup
Log "DONE"
