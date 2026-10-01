# Issue #274 - Clean recovery test after sustained heavy load
# Goal: After 2 minutes of 3-pane spam, can we KILL the spammer
# and resume normal operation? This is the precise wedge scenario.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "wedge_clean_274"
$psmuxDir = "$env:USERPROFILE\.psmux"

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

Log "Creating 3-pane session"
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 2
& $PSMUX split-window -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX split-window -t $SESSION
Start-Sleep -Seconds 1

# Spammer in pane 0 only (pane 1 + 2 stay quiet for control)
$spamCmd = '$i=0; while($true) { Write-Host ("LINE_" + $i); $i++ }'
& $PSMUX send-keys -t "${SESSION}:0.0" $spamCmd Enter
Log "Spammer started in pane 0"

# Run for 2 minutes
Log "Sustaining heavy load for 120s..."
$startTime = Get-Date
while (((Get-Date) - $startTime).TotalSeconds -lt 120) {
    Start-Sleep -Seconds 5
    $proc = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
    $mem = if ($proc) { [Math]::Round($proc.WorkingSet64/1MB,1) } else { 0 }
    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
    Log ("t=" + $elapsed + "s mem=" + $mem + "MB")
}

# === CRITICAL TEST: Send Ctrl+C and verify spammer stops ===
Log "Sending Ctrl+C to pane 0 (proper send-keys with C-c)"
& $PSMUX send-keys -t "${SESSION}:0.0" "C-c"
Start-Sleep -Seconds 2

# Send another Ctrl+C in case first didn't take
& $PSMUX send-keys -t "${SESSION}:0.0" "C-c"
Start-Sleep -Seconds 2

# Now send a marker
& $PSMUX send-keys -t "${SESSION}:0.0" "" Enter  # blank line to clear
Start-Sleep -Seconds 1
& $PSMUX send-keys -t "${SESSION}:0.0" "Write-Host CTRL_C_RECOVERED_$(Get-Random)" Enter
Start-Sleep -Seconds 3

# Capture pane 0
$cap0 = & $PSMUX capture-pane -t "${SESSION}:0.0" -p 2>&1 | Out-String
$lastLines = ($cap0 -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 10)
Log "Pane 0 last 10 lines:"
$lastLines | ForEach-Object { Log ("  | " + $_) }

if ($cap0 -match "CTRL_C_RECOVERED_") {
    Log "PASS: Pane 0 recovered after Ctrl+C, marker found"
} else {
    Log "FAIL: marker NOT in pane 0"
    # Try a longer scrollback capture
    $capFull = & $PSMUX capture-pane -t "${SESSION}:0.0" -p -S -100 2>&1 | Out-String
    if ($capFull -match "CTRL_C_RECOVERED_") {
        Log "  But marker found in extended scrollback - send-keys IS working, capture viewport just delayed"
    } else {
        Log "  Marker NOT in scrollback either - real wedge"
    }
}

# Verify pane 1 (which never had spammer) is unaffected
& $PSMUX send-keys -t "${SESSION}:0.1" "Write-Host PANE1_OK_$(Get-Random)" Enter
Start-Sleep -Seconds 2
$cap1 = & $PSMUX capture-pane -t "${SESSION}:0.1" -p 2>&1 | Out-String
if ($cap1 -match "PANE1_OK_") {
    Log "PASS: Pane 1 (never spammed) responds normally"
} else {
    Log "FAIL: Pane 1 not responding"
}

# Server stats
$proc = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
if ($proc) {
    Log ("Final server PID=" + $proc.Id + " mem=" + [Math]::Round($proc.WorkingSet64/1MB,1) + "MB threads=" + $proc.Threads.Count + " handles=" + $proc.HandleCount)
}

Cleanup
Log "DONE"
