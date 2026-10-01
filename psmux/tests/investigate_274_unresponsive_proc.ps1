# Issue #274 - Test: what if a pane has a process that ignores stdin?
# This simulates the user's "claude.exe stops emitting events" scenario.
#
# The user reports a WEDGE. We test: can other panes still work when one
# pane has a totally unresponsive process?

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "wedge_unresp_274"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Log($msg) {
    $stamp = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$stamp] $msg"
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Get-Process node -EA SilentlyContinue | Where-Object { $_.MainWindowTitle -match "wedge_unresp" } | Stop-Process -Force -EA SilentlyContinue
}

Cleanup

# Create an unresponsive node "daemon" that ignores stdin and SIGINT after first emission
$unresponsiveJs = @'
process.stdin.resume();  // hold stdin but don't read
process.on('SIGINT', () => { /* ignore */ });
process.on('SIGTERM', () => { /* ignore */ });
console.log("UNRESPONSIVE_STARTED");
// Then go silent forever - simulates claude.exe wedging on internal poll
setInterval(() => { /* no output */ }, 100000);
'@
$unresponsiveJs | Set-Content "$env:TEMP\wedge_unresponsive.js" -Encoding UTF8

Log "Creating 3-pane session"
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 2
& $PSMUX split-window -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX split-window -t $SESSION
Start-Sleep -Seconds 1

# Pane 0: the wedged-process pane (mimics frozen claude.exe)
Log "Starting unresponsive process in pane 0"
& $PSMUX send-keys -t "${SESSION}:0.0" "node `"$env:TEMP\wedge_unresponsive.js`"" Enter
Start-Sleep -Seconds 3

$cap0 = & $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String
if ($cap0 -match "UNRESPONSIVE_STARTED") {
    Log "Pane 0: unresponsive process is running (and not reading stdin/responding to SIGINT)"
} else {
    Log "Pane 0: unresponsive process may not have started"
}

# === TEST: Send-keys to pane 0 (will be received by node but ignored) ===
Log "Sending random text to pane 0 (should be received but ignored by frozen node)"
& $PSMUX send-keys -t "${SESSION}:0.0" "this_will_be_ignored_$(Get-Random)" Enter
Start-Sleep -Seconds 1

# Capture should still be possible
$cap0_after = & $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String
$lines0 = ($cap0_after -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count
Log "Pane 0 after wedge attempt: $lines0 lines visible"

# === KEY TEST: Are panes 1 and 2 still responsive? ===
Log "Testing other panes while pane 0 is wedged"
$marker1 = "PANE1_OK_$(Get-Random)"
$marker2 = "PANE2_OK_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:0.1" "Write-Host $marker1" Enter
& $PSMUX send-keys -t "${SESSION}:0.2" "Write-Host $marker2" Enter
Start-Sleep -Seconds 2

$cap1 = & $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String
$cap2 = & $PSMUX capture-pane -t "${SESSION}:0.2" -p 2>&1 | Out-String
if ($cap1 -match $marker1) { Log "PASS: Pane 1 responsive while pane 0 wedged" }
else { Log "FAIL: Pane 1 NOT responsive" }
if ($cap2 -match $marker2) { Log "PASS: Pane 2 responsive while pane 0 wedged" }
else { Log "FAIL: Pane 2 NOT responsive" }

# === TEST: CLI commands during wedge ===
Log "CLI commands during wedge"
for ($i = 0; $i -lt 10; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1
    $sw.Stop()
    Log ("  display-message #" + $i + ": " + $sw.ElapsedMilliseconds + "ms got=" + $r.Trim())
}

# === TEST: Spawn an attached client, kill it, attach again ===
Log "Spawning attached TUI client"
$attachProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 4

if ($attachProc.HasExited) {
    Log "FAIL: attach client exited code=$($attachProc.ExitCode)"
} else {
    Log "Attach client running PID=$($attachProc.Id)"

    # Force-kill it (mimics user's psutil kill)
    Log "Force-killing attach client (mimics user's psutil.kill)"
    Stop-Process -Id $attachProc.Id -Force
    Start-Sleep -Seconds 2

    # List sessions still works?
    $ls = & $PSMUX list-sessions 2>&1 | Out-String
    Log "list-sessions after kill: $($ls.Trim())"

    # Fresh attach
    Log "Spawning FRESH attach"
    $attachProc2 = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
    Start-Sleep -Seconds 4

    if ($attachProc2.HasExited) {
        Log "WEDGE CONFIRMED: fresh attach exited code=$($attachProc2.ExitCode)"
    } else {
        Log "PASS: fresh attach running"

        # Send-keys to a NON-wedged pane (pane 1) via fresh attach session
        $marker3 = "AFTER_REATTACH_$(Get-Random)"
        & $PSMUX send-keys -t "${SESSION}:0.1" "Write-Host $marker3" Enter
        Start-Sleep -Seconds 2
        $cap = & $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String
        if ($cap -match $marker3) {
            Log "PASS: send-keys to pane 1 works after fresh attach"
        } else {
            Log "FAIL: send-keys NOT delivered after fresh attach"
        }

        try { Stop-Process -Id $attachProc2.Id -Force -EA Stop } catch {}
    }
}

# === Final memory check ===
$proc = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
if ($proc) {
    Log ("Server: PID=" + $proc.Id + " mem=" + [Math]::Round($proc.WorkingSet64/1MB,1) + "MB threads=" + $proc.Threads.Count + " handles=" + $proc.HandleCount)
}

Cleanup
Remove-Item "$env:TEMP\wedge_unresponsive.js" -Force -EA SilentlyContinue
Log "DONE"
