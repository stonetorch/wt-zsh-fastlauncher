# Issue #274 - investigate attach client kill + re-attach scenario
# Specifically: does killing the attached TUI client leave server in a wedged state?

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "wedge_attach_274"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Log($msg) {
    $stamp = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$stamp] $msg"
}

function Cleanup {
    Get-Process psmux -EA SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*${SESSION}*" } | Stop-Process -Force -EA SilentlyContinue
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Cleanup

# === STEP 1: Create detached session ===
Log "Creating detached session $SESSION"
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Log "FAIL: session not created"; exit 1 }
Log "Session created"

# === STEP 2: Add 2 more panes ===
& $PSMUX split-window -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX split-window -t $SESSION
Start-Sleep -Milliseconds 500
$panes = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim()
Log "Panes: $panes"

# === STEP 3: Spawn an ATTACHED client in a separate visible window ===
Log "Spawning attached client process"
$attachProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 3

if ($attachProc.HasExited) {
    Log "ERROR: attach client exited immediately, exit code = $($attachProc.ExitCode)"
} else {
    Log "Attach client running PID=$($attachProc.Id)"
}

# === STEP 4: Verify session still works via CLI while attached ===
$paneCount = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim()
Log "After attach, pane count via CLI = $paneCount"

# === STEP 5: Start a stdout spammer in pane 0 ===
Log "Starting stdout spammer in pane 0"
$spamCmd = '$i=0; while($true) { Write-Host ("LINE_" + $i); $i++ }'
& $PSMUX send-keys -t "${SESSION}:0.0" $spamCmd Enter

Start-Sleep -Seconds 5

# === STEP 6: Verify CLI commands still work ===
Log "Testing CLI commands during spam"
for ($i = 0; $i -lt 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $PSMUX list-sessions 2>&1 | Out-String
    $sw.Stop()
    Log ("list-sessions #" + $i + ": " + $sw.ElapsedMilliseconds + "ms")
}

# === STEP 7: Force-kill the attach client ===
Log "Force-killing attach client PID=$($attachProc.Id)"
try {
    Stop-Process -Id $attachProc.Id -Force -EA Stop
    Log "Attach client killed"
} catch {
    Log "Failed to kill: $_"
}
Start-Sleep -Seconds 2

# === STEP 8: Verify server still has session ===
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) { Log "Server still has session after client kill" }
else { Log "Server LOST session (unexpected)" }

# === STEP 9: List sessions ===
$ls = & $PSMUX list-sessions 2>&1 | Out-String
Log "list-sessions output: $($ls.Trim())"

# === STEP 10: Try a fresh attach ===
Log "Spawning FRESH attach client"
$attachProc2 = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 4

if ($attachProc2.HasExited) {
    Log "FRESH attach exited immediately, code=$($attachProc2.ExitCode)"
} else {
    Log "FRESH attach running PID=$($attachProc2.Id)"
}

# === STEP 11: CLI still works after fresh attach? ===
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$paneCount2 = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim()
$sw.Stop()
Log ("After fresh attach, pane count = " + $paneCount2 + " (took " + $sw.ElapsedMilliseconds + "ms)")

# === STEP 12: Send-keys to fresh attached session ===
& $PSMUX send-keys -t "${SESSION}:0.1" "echo MARKER_AFTER_FRESH_ATTACH" Enter
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String
if ($cap -match "MARKER_AFTER_FRESH_ATTACH") {
    Log "PASS: send-keys delivered after fresh attach"
} else {
    Log "FAIL: send-keys not delivered after fresh attach"
    Log ("Last lines: " + (($cap -split "`n" | Select-Object -Last 5) -join '|'))
}

# === STEP 13: capture-pane on spamming pane ===
$cap0 = & $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String
$lineCount = ($cap0 -split "`n" | Where-Object { $_ -match "LINE_\d+" }).Count
Log ("Pane 0 capture: " + $lineCount + " LINE_ rows")

# === STEP 14: Kill fresh attach and confirm clean state ===
Log "Killing fresh attach client"
try {
    Stop-Process -Id $attachProc2.Id -Force -EA Stop
} catch {}

Cleanup
Log "DONE"
