# Investigation script for issue #274
# Claim: A long-running daemon producing continuous stdout in one pane
#        wedges the server-to-client I/O pipe, locking the entire session.
#        Killing the client + re-attach does NOT recover. Only reboot recovers.
#
# Strategy:
#   1. Create multi-pane session
#   2. Spawn a high-volume stdout-spammer in pane 1
#   3. Verify CLI commands still respond on the server while spam is running
#   4. Verify other panes can still receive send-keys + show output
#   5. After sustained load, attempt client kill + re-attach simulation
#   6. Test with several stdout volumes / durations

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "wedge_repro_274"
$psmuxDir = "$env:USERPROFILE\.psmux"
$LogFile = "$env:TEMP\investigate_274.log"

function Log($msg) {
    $stamp = Get-Date -Format "HH:mm:ss.fff"
    "$stamp $msg" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Remove-Item $LogFile -Force -EA SilentlyContinue
Cleanup

Log "psmux version: $(& $PSMUX -V)"
Log "psmux path: $PSMUX"

# === SETUP ===
Log "Creating session $SESSION with 3 panes"
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 2
& $PSMUX split-window -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX split-window -t $SESSION
Start-Sleep -Milliseconds 500

$panes = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim()
Log "Pane count: $panes"
if ($panes -ne "3") { Log "FAIL: expected 3 panes, got $panes"; Cleanup; exit 1 }

# Find pane indices
$paneList = (& $PSMUX list-panes -t $SESSION -F '#{pane_index}' 2>&1) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
Log "Pane indices: $($paneList -join ', ')"

$P0 = $paneList[0]; $P1 = $paneList[1]; $P2 = $paneList[2]

# === TEST 1: Baseline - all panes responsive ===
Log "=== Test 1: Baseline responsiveness ==="
& $PSMUX send-keys -t "${SESSION}:.${P0}" "echo PANE0_BASELINE" Enter
& $PSMUX send-keys -t "${SESSION}:.${P1}" "echo PANE1_BASELINE" Enter
& $PSMUX send-keys -t "${SESSION}:.${P2}" "echo PANE2_BASELINE" Enter
Start-Sleep -Seconds 2

$cap0 = & $PSMUX capture-pane -t "${SESSION}:.${P0}" -p 2>&1 | Out-String
$cap1 = & $PSMUX capture-pane -t "${SESSION}:.${P1}" -p 2>&1 | Out-String
$cap2 = & $PSMUX capture-pane -t "${SESSION}:.${P2}" -p 2>&1 | Out-String

if ($cap0 -match "PANE0_BASELINE") { Log "Baseline pane 0 OK" } else { Log "Baseline pane 0 FAIL" }
if ($cap1 -match "PANE1_BASELINE") { Log "Baseline pane 1 OK" } else { Log "Baseline pane 1 FAIL" }
if ($cap2 -match "PANE2_BASELINE") { Log "Baseline pane 2 OK" } else { Log "Baseline pane 2 FAIL" }

# === TEST 2: Start a high-volume stdout spammer in pane 0 ===
Log "=== Test 2: Start high-volume spammer in pane 0 ==="
# Use a tight loop that emits ~10K lines per second of pseudo-random output
$spamCmd = '$i=0; while($true) { Write-Host ("LINE_" + $i + "_" + (Get-Random -Minimum 1000000 -Maximum 9999999)); $i++ }'
& $PSMUX send-keys -t "${SESSION}:.${P0}" $spamCmd Enter
Log "Spammer started in pane 0"

# Let it ramp up
Start-Sleep -Seconds 5

# === TEST 3: Verify other panes still respond while pane 0 spams ===
Log "=== Test 3: Other panes still respond during spam ==="

$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $PSMUX send-keys -t "${SESSION}:.${P1}" "echo PANE1_DURING_SPAM_$(Get-Random)" Enter
$sw.Stop()
Log "send-keys to pane 1 took $($sw.ElapsedMilliseconds)ms"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $PSMUX send-keys -t "${SESSION}:.${P2}" "echo PANE2_DURING_SPAM_$(Get-Random)" Enter
$sw.Stop()
Log "send-keys to pane 2 took $($sw.ElapsedMilliseconds)ms"

Start-Sleep -Seconds 2

# === TEST 4: CLI commands still respond ===
Log "=== Test 4: CLI commands still respond during spam ==="
for ($i = 0; $i -lt 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $name = (& $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1).Trim()
    $sw.Stop()
    Log ("display-message #" + $i + ": " + $sw.ElapsedMilliseconds + "ms got=" + $name)
}

# === TEST 5: capture-pane on the spamming pane ===
Log "=== Test 5: capture-pane on spamming pane ==="
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cap0_during = & $PSMUX capture-pane -t "${SESSION}:.${P0}" -p 2>&1 | Out-String
$sw.Stop()
$lineCount = ($cap0_during -split "`n" | Where-Object { $_ -match "LINE_" }).Count
Log "capture-pane pane 0 took $($sw.ElapsedMilliseconds)ms, captured $lineCount LINE_ rows"

# === TEST 6: capture-pane on other panes ===
Log "=== Test 6: capture-pane on quiet panes ==="
$cap1 = & $PSMUX capture-pane -t "${SESSION}:.${P1}" -p 2>&1 | Out-String
$cap2 = & $PSMUX capture-pane -t "${SESSION}:.${P2}" -p 2>&1 | Out-String
if ($cap1 -match "PANE1_DURING_SPAM") { Log "Pane 1 captured DURING_SPAM marker" } else { Log "Pane 1 missing DURING_SPAM marker" }
if ($cap2 -match "PANE2_DURING_SPAM") { Log "Pane 2 captured DURING_SPAM marker" } else { Log "Pane 2 missing DURING_SPAM marker" }

# === TEST 7: Sustained load test - 60 seconds ===
Log "=== Test 7: Sustained load (60s) - server should remain responsive ==="
$startTime = Get-Date
$samples = [System.Collections.ArrayList]::new()
while (((Get-Date) - $startTime).TotalSeconds -lt 60) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1
    $sw.Stop()
    [void]$samples.Add($sw.ElapsedMilliseconds)
    Start-Sleep -Milliseconds 500
}
$avg = ($samples | Measure-Object -Average).Average
$max = ($samples | Measure-Object -Maximum).Maximum
Log "60s load test: avg=${avg}ms max=${max}ms samples=$($samples.Count)"

# === TEST 8: Memory leak / stuck process check ===
Log "=== Test 8: Memory check ==="
$serverProc = Get-Process psmux -EA SilentlyContinue | Select-Object -First 1
if ($serverProc) {
    $mem = [Math]::Round($serverProc.WorkingSet64 / 1MB, 1)
    Log "psmux server PID=$($serverProc.Id) WorkingSet=${mem}MB"
}

# === TEST 9: Kill server and verify recovery ===
Log "=== Test 9: Stop spammer and verify recovery ==="
# Send Ctrl+C to pane 0
& $PSMUX send-keys -t "${SESSION}:.${P0}" "C-c" 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX send-keys -t "${SESSION}:.${P0}" "echo PANE0_RECOVERED" Enter
Start-Sleep -Seconds 2

$cap0_recovered = & $PSMUX capture-pane -t "${SESSION}:.${P0}" -p 2>&1 | Out-String
if ($cap0_recovered -match "PANE0_RECOVERED") { Log "Pane 0 recovered after Ctrl+C" }
else { Log "Pane 0 NOT recovered - last lines: $(($cap0_recovered -split "`n" | Select-Object -Last 5) -join '|')" }

# === CLEANUP ===
Cleanup

Log "=== Investigation complete - log at $LogFile ==="
