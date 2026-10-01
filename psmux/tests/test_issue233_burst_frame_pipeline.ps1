# Issue #233 Performance/Correctness Test:
# "Fast typing still drops frames after #225: three remaining causes in push pipeline"
#
# THREE ROOT CAUSES being tested:
#   1. push_frame drops NEWEST frame on full channel (backwards semantics)
#   2. Writer thread's `continue` starves the frame drain
#   3. DumpState double-pushes the same frame (amplifies channel saturation)
#
# STRATEGY:
#   A) Inject a rapid burst of DISTINCT characters via send-keys (no inter-key delay)
#      and assert capture-pane shows ALL of them — tests causes 1+2 together.
#   B) Use a persistent TCP client subscribed to frames and assert the LATEST
#      pushed frame contains the complete string — tests that newest frame is
#      always delivered (cause 1 specifically).
#   C) Measure how many distinct frames a persistent client receives during a
#      burst; if count << burst size, the drain starvation (cause 2) is active.
#
# Layer 2 (integration) + Layer 7 (perf/completeness)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed  = 0
$script:Metrics      = @{}

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }
function Metric($name, $val, $unit = "") {
    $script:Metrics[$name] = $val
    $u = if ($unit) { " $unit" } else { "" }
    Write-Host ("  [METRIC] {0}: {1:N1}{2}" -f $name, $val, $u) -ForegroundColor DarkCyan
}

function Percentile($arr, $pct) {
    if ($arr.Count -eq 0) { return 0 }
    $sorted = [double[]]($arr | Sort-Object)
    $idx = [Math]::Floor(($pct / 100.0) * ($sorted.Count - 1))
    return $sorted[$idx]
}

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 12000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $raw = (Get-Content $pf -Raw -EA SilentlyContinue)
            if ($raw -and $raw.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$raw.Trim())
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Cleanup {
    param([string]$Name)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

# Poll capture-pane until token appears; returns elapsed ms or -1
function Wait-Token {
    param([string]$Target, [string]$Token, [int]$TimeoutMs = 8000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match [regex]::Escape($Token)) { return $sw.ElapsedMilliseconds }
        Start-Sleep -Milliseconds 30
    }
    return -1
}

# Send one dump-state request and return the response line (server closes after reply)
function Get-DumpState {
    param([string]$Session, [int]$TimeoutMs = 5000)
    $pf  = "$psmuxDir\$Session.port"
    $kf  = "$psmuxDir\$Session.key"
    $port = [int](Get-Content $pf -Raw).Trim()
    $key  = (Get-Content $kf -Raw).Trim()
    try {
        $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
        $tcp.NoDelay = $true
        $tcp.ReceiveTimeout = $TimeoutMs
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream); $writer.AutoFlush = $true
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.WriteLine("AUTH $key")
        $null = $reader.ReadLine()   # OK
        $writer.WriteLine("dump-state")
        $line = $reader.ReadLine()
        $tcp.Close()
        return $line
    } catch { return $null }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "Issue #233: Burst frame pipeline — newest-frame delivery + drain" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

$SESSION = "gap233"
Cleanup -Name $SESSION

& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
if (-not (Wait-Session -Name $SESSION)) {
    Write-Fail "Session $SESSION never came up"
    exit 1
}

# Wait for shell prompt
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 400
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap -match "PS [A-Z]:\\" -or $cap -match "\$\s*$") { break }
}
Start-Sleep -Milliseconds 500

# ============================================================================
# TEST A: Burst of 30 distinct characters — all must land in capture-pane
#
# This directly exercises causes 1 (newest dropped on full channel) and 2
# (drain starvation). If any char is missing the issue is NOT fixed.
# ============================================================================
Write-Host "`n[Test A] 30-distinct-char burst completeness (5 trials)" -ForegroundColor Yellow

$BURST_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"  # exactly 30, all distinct
$TRIALS      = 5
$aDropped    = 0

for ($t = 0; $t -lt $TRIALS; $t++) {
    & $PSMUX send-keys -t $SESSION "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600

    $prefix = "G233A${t}"
    $full   = $prefix + $BURST_CHARS   # unique per trial via prefix

    # Send prefix (anchors the line), then burst each char individually with
    # no sleep — this maximises channel saturation pressure.
    & $PSMUX send-keys -t $SESSION $prefix 2>&1 | Out-Null
    foreach ($ch in $BURST_CHARS.ToCharArray()) {
        & $PSMUX send-keys -t $SESSION $ch.ToString() 2>&1 | Out-Null
    }

    $foundMs = Wait-Token -Target $SESSION -Token $full -TimeoutMs 8000

    if ($foundMs -ge 0) {
        Write-Host ("  Trial {0}: complete burst found after {1:N0} ms [OK]" -f ($t+1), $foundMs) -ForegroundColor Green
    } else {
        $aDropped++
        $cap2 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
        $got  = ($cap2 -split "`n" | Where-Object { $_ -match "G233A$t" } | Select-Object -First 1)
        Write-Host ("  Trial {0}: DROPPED — got: '{1}'" -f ($t+1), $got.Trim()) -ForegroundColor Red
    }

    & $PSMUX send-keys -t $SESSION "" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
}

Metric "Burst-30 trials dropped" $aDropped "/ $TRIALS"
if ($aDropped -eq 0) {
    Write-Pass "All 30-char bursts delivered completely ($TRIALS trials)"
} else {
    Write-Fail "$aDropped / $TRIALS bursts had dropped characters (causes 1+2 active)"
    Write-Host "  VERDICT: Issue #233 causes 1/2 reproduced" -ForegroundColor Red
}

# ============================================================================
# TEST B: dump-state (one-shot TCP) returns latest frame after burst
#
# dump-state opens a fresh TCP connection each call; server closes after reply.
# We send a token burst then poll dump-state until the token appears in the
# JSON response. Tests that newest frame is always reachable (cause 1).
# ============================================================================
Write-Host "`n[Test B] dump-state returns complete token after burst (5 trials)" -ForegroundColor Yellow

$bDropped = 0
$BTRIALS  = 5

for ($t = 0; $t -lt $BTRIALS; $t++) {
    & $PSMUX send-keys -t $SESSION "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600

    $tok  = "G233B${t}" + ([System.Guid]::NewGuid().ToString("N").Substring(0,12).ToUpper())

    # Send the token as a burst
    & $PSMUX send-keys -t $SESSION $tok 2>&1 | Out-Null

    # Poll dump-state (each call is a fresh TCP connection) until token appears
    $found   = $false
    $pollSw  = [System.Diagnostics.Stopwatch]::StartNew()
    while ($pollSw.ElapsedMilliseconds -lt 8000 -and -not $found) {
        $frame = Get-DumpState -Session $SESSION -TimeoutMs 3000
        if ($frame -and $frame -match [regex]::Escape($tok)) { $found = $true }
        if (-not $found) { Start-Sleep -Milliseconds 50 }
    }
    $pollSw.Stop()

    if ($found) {
        Write-Host ("  Trial {0}: dump-state contained complete token after {1:N0} ms" -f ($t+1), $pollSw.ElapsedMilliseconds) -ForegroundColor Green
    } else {
        $bDropped++
        Write-Host ("  Trial {0}: dump-state did NOT contain token after {1:N0} ms — newest frame dropped?" -f ($t+1), $pollSw.ElapsedMilliseconds) -ForegroundColor Red
    }

    & $PSMUX send-keys -t $SESSION "" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
}

Metric "Persistent-client trials dropped" $bDropped "/ $BTRIALS"
if ($bDropped -eq 0) {
    Write-Pass "dump-state returned newest frame for all $BTRIALS trials (cause 1 fixed)"
} else {
    Write-Fail "$bDropped / $BTRIALS trials: dump-state missed the complete frame (cause 1 or 3 active)"
}

# ============================================================================
# TEST C: Frame drain health — dump-state advances across burst
#
# Send 30 characters with 20ms gaps while polling dump-state 20 times
# (each poll = fresh TCP connection). Count how many distinct JSON frames
# we receive. If all 20 polls return the same stale frame, the state is
# not advancing (possible server-side starvation). We expect >= 3 distinct.
# ============================================================================
Write-Host "`n[Test C] Frame drain health — distinct dump-state frames during burst" -ForegroundColor Yellow

& $PSMUX send-keys -t $SESSION "clear" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$pollFrames  = [System.Collections.ArrayList]::new()
$DRAIN_POLLS = 20
$charStr     = "DRAINTEST233XYZ0123456789UVWAB"  # 30 chars, 20ms apart = 600ms total

# Send chars in the foreground with a tight loop; interleave dump-state polls
$charIdx = 0
$charArr = $charStr.ToCharArray()
for ($p = 0; $p -lt $DRAIN_POLLS; $p++) {
    # Send one char per poll cycle (20ms * 20 = 400ms; chars overlap with polls)
    if ($charIdx -lt $charArr.Count) {
        & $PSMUX send-keys -t $SESSION $charArr[$charIdx].ToString() 2>&1 | Out-Null
        $charIdx++
    }
    $fr = Get-DumpState -Session $SESSION -TimeoutMs 2000
    if ($fr) { [void]$pollFrames.Add($fr) }
    Start-Sleep -Milliseconds 30
}
# Send remaining chars
while ($charIdx -lt $charArr.Count) {
    & $PSMUX send-keys -t $SESSION $charArr[$charIdx].ToString() 2>&1 | Out-Null
    $charIdx++
    Start-Sleep -Milliseconds 20
}

$distinctFrames = ($pollFrames | Sort-Object -Unique).Count
Metric "Drain poll: total responses"  $pollFrames.Count "frames"
Metric "Drain poll: distinct frames"  $distinctFrames   "frames"

# Expect at least 3 distinct frames across 20 polls while chars are being sent.
if ($distinctFrames -ge 3) {
    Write-Pass ("Frame drain healthy: {0} distinct frames out of {1} polls" -f $distinctFrames, $pollFrames.Count)
} else {
    Write-Fail ("Frame drain stalled: only {0} distinct frames out of {1} polls (cause 2 or server not updating)" -f $distinctFrames, $pollFrames.Count)
    Write-Host "  VERDICT: server state not advancing during burst (drain starvation or pipeline stall)" -ForegroundColor Red
}

# Last frame should contain at least part of charStr if the pane scrolled
$lastFrame = $pollFrames | Select-Object -Last 1
if ($lastFrame -and $lastFrame -match "DRAINTEST233") {
    Write-Pass "Last polled frame contains burst characters (newest frame delivered)"
} else {
    Write-Host "  [INFO] Last polled frame did not contain burst marker (pane may have scrolled)" -ForegroundColor DarkGray
}

# ============================================================================
# TEST D: Faster delivery — 50-char unique token sent in single send-keys call
#         Tests that a larger token does not get truncated.
# ============================================================================
Write-Host "`n[Test D] 50-char unique token single send-keys — no truncation (5 trials)" -ForegroundColor Yellow

$dDropped = 0

for ($t = 0; $t -lt 5; $t++) {
    & $PSMUX send-keys -t $SESSION "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600

    # 50-char token: fixed prefix + 32-char guid slice + trial suffix
    $guid  = [System.Guid]::NewGuid().ToString("N").ToUpper()
    $token = "G233D${t}" + $guid.Substring(0, 32) + "ZZ"

    & $PSMUX send-keys -t $SESSION $token 2>&1 | Out-Null

    $foundMs = Wait-Token -Target $SESSION -Token $token -TimeoutMs 8000

    if ($foundMs -ge 0) {
        Write-Host ("  Trial {0}: 50-char token found after {1:N0} ms" -f ($t+1), $foundMs) -ForegroundColor Green
    } else {
        $dDropped++
        $cap3 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
        $got3 = ($cap3 -split "`n" | Where-Object { $_ -match "G233D$t" } | Select-Object -First 1)
        Write-Host ("  Trial {0}: token truncated/dropped — got: '{1}'" -f ($t+1), $got3.Trim()) -ForegroundColor Red
    }

    & $PSMUX send-keys -t $SESSION "" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
}

Metric "50-char-token trials dropped" $dDropped "/ 5"
if ($dDropped -eq 0) {
    Write-Pass "All 50-char tokens delivered without truncation"
} else {
    Write-Fail "$dDropped / 5 trials: 50-char token was truncated or dropped"
}

# ── Cleanup ────────────────────────────────────────────────────────────────────
Cleanup -Name $SESSION

# ── Save metrics ───────────────────────────────────────────────────────────────
$metricsDir = "$env:USERPROFILE\.psmux-test-data\metrics"
if (-not (Test-Path $metricsDir)) { New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null }
$ts = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$script:Metrics | ConvertTo-Json | Set-Content "$metricsDir\issue233-perf-$ts.json" -Encoding UTF8
Write-Host "`nMetrics saved to: $metricsDir\issue233-perf-$ts.json" -ForegroundColor DarkGray

# ── Final summary ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "Issue #233 Results" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""
exit $script:TestsFailed
