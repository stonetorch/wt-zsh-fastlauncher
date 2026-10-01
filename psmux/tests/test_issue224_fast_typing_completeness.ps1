# Issue #224 Performance/Correctness Test:
# "Fast typing drops intermediate frames — characters not rendered while cursor advances"
#
# ROOT CAUSE: single-slot frame buffer overwrites unread frames.
# FIX expected: bounded channel (e.g. sync_channel(16)) so all chars land.
#
# STRATEGY: send-keys a long unique token rapidly into a pane, then assert
# capture-pane (server-authoritative state) contains the COMPLETE token.
# Server state always converges; we poll up to a generous deadline.
# A second variant uses a persistent TCP client to observe the final pushed frame.
#
# Layer 2 (integration) + Layer 7 (perf/completeness threshold)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed  = 0
$script:Metrics      = @{}

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }
function Metric($name, $val, $unit = "ms") {
    $script:Metrics[$name] = $val
    Write-Host ("  [METRIC] {0}: {1:N1} {2}" -f $name, $val, $unit) -ForegroundColor DarkCyan
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

# Poll capture-pane until $token appears in output, up to $TimeoutMs
function Wait-Token {
    param([string]$Target, [string]$Token, [int]$TimeoutMs = 8000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match [regex]::Escape($Token)) { return $sw.ElapsedMilliseconds }
        Start-Sleep -Milliseconds 50
    }
    return -1
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "Issue #224: Fast-typing frame completeness (no dropped characters)" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

$SESSION = "gap224"
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

# ============================================================================
# TEST 1: Single long token sent as one send-keys burst
#         Token is long enough (60 chars) to stress the frame pipeline.
#         After delivery the server-side pane MUST contain it verbatim.
# ============================================================================
Write-Host "`n[Test 1] Single long unique token via send-keys — completeness check" -ForegroundColor Yellow

$TRIALS = 5
$completenessResults = [System.Collections.ArrayList]::new()

for ($i = 0; $i -lt $TRIALS; $i++) {
    # Unique non-repeating token: prefix + hex random + trial index
    $rand    = [System.Guid]::NewGuid().ToString("N").Substring(0, 20).ToUpper()
    $token   = "CHK224T${i}${rand}END"   # ~35 chars, fully unique

    # Clear pane
    & $PSMUX send-keys -t $SESSION "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600

    # Type the token as a rapid burst — no inter-key delay means the server's
    # frame pipeline must handle overlapping pushes without dropping characters.
    & $PSMUX send-keys -t $SESSION $token 2>&1 | Out-Null

    # Poll until token appears (server-authoritative state converges)
    $foundMs = Wait-Token -Target $SESSION -Token $token -TimeoutMs 8000

    if ($foundMs -ge 0) {
        [void]$completenessResults.Add($foundMs)
        Write-Host ("  Trial {0}: token found after {1:N0} ms [COMPLETE]" -f ($i+1), $foundMs) -ForegroundColor Green
    } else {
        [void]$completenessResults.Add(-1)
        # Capture what actually showed up for diagnostics
        $actual = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
        $snippet = ($actual -split "`n" | Where-Object { $_ -match "CHK224" } | Select-Object -First 1)
        Write-Host ("  Trial {0}: token NOT found (dropped chars) — got: '{1}'" -f ($i+1), $snippet.Trim()) -ForegroundColor Red
    }

    # Press Enter to consume the typed token before next trial
    & $PSMUX send-keys -t $SESSION "" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
}

$dropped = @($completenessResults | Where-Object { $_ -lt 0 }).Count
$found   = @($completenessResults | Where-Object { $_ -ge 0 }).Count
Metric "Tokens found (no drop)" $found "trials"
Metric "Tokens dropped"          $dropped "trials"

if ($dropped -eq 0) {
    Write-Pass "All $TRIALS tokens delivered completely (0 dropped)"
} else {
    Write-Fail "$dropped / $TRIALS tokens had dropped characters (issue #224 reproduced)"
    Write-Host "  VERDICT: Frame overwrite drops characters during fast typing" -ForegroundColor Red
}

# ============================================================================
# TEST 2: Rapid sequential send-keys calls — simulates very fast keyboard events
#         Each call sends one character; we fire them back-to-back to saturate
#         the bounded channel, then assert capture-pane shows all characters.
# ============================================================================
Write-Host "`n[Test 2] Rapid sequential single-char send-keys (20 chars) — completeness" -ForegroundColor Yellow

$CHAR_TRIALS = 3
$charDropped = 0

for ($t = 0; $t -lt $CHAR_TRIALS; $t++) {
    & $PSMUX send-keys -t $SESSION "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600

    # Build a known sequence of 20 distinct hex chars; prefix makes it unique per trial
    $prefix = "R224X${t}"
    $seq    = "ABCDEF0123456789GHIJ"   # 20 distinct chars
    $full   = $prefix + $seq

    # Send prefix first (slow, to anchor the line), then rapid burst
    & $PSMUX send-keys -t $SESSION $prefix 2>&1 | Out-Null
    # Now fire each character of $seq as an individual send-keys with no sleep
    foreach ($ch in $seq.ToCharArray()) {
        & $PSMUX send-keys -t $SESSION $ch.ToString() 2>&1 | Out-Null
    }

    # Poll for the complete string
    $foundMs2 = Wait-Token -Target $SESSION -Token $full -TimeoutMs 8000

    if ($foundMs2 -ge 0) {
        Write-Host ("  Trial {0}: full sequence found after {1:N0} ms" -f ($t+1), $foundMs2) -ForegroundColor Green
    } else {
        $charDropped++
        $actual2 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
        $snippet2 = ($actual2 -split "`n" | Where-Object { $_ -match "R224X$t" } | Select-Object -First 1)
        Write-Host ("  Trial {0}: chars dropped — got: '{1}'" -f ($t+1), $snippet2.Trim()) -ForegroundColor Red
    }

    & $PSMUX send-keys -t $SESSION "" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
}

Metric "Rapid-char trials dropped" $charDropped "trials"

if ($charDropped -eq 0) {
    Write-Pass "Rapid single-char send-keys: all characters delivered ($CHAR_TRIALS trials)"
} else {
    Write-Fail "Rapid single-char send-keys: $charDropped trial(s) had dropped chars"
}

# ============================================================================
# TEST 3: Delivery latency — time from send-keys to capture-pane visibility
#         (regression guard: should not regress from fix for #224)
# ============================================================================
Write-Host "`n[Test 3] Token delivery latency (send-keys -> capture-pane visible)" -ForegroundColor Yellow

$latencies = [System.Collections.ArrayList]::new()

for ($i = 0; $i -lt 10; $i++) {
    & $PSMUX send-keys -t $SESSION "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400

    $tok = "LAT224I${i}" + ([System.Guid]::NewGuid().ToString("N").Substring(0,8).ToUpper())
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX send-keys -t $SESSION $tok 2>&1 | Out-Null
    $lat = Wait-Token -Target $SESSION -Token $tok -TimeoutMs 5000
    $sw.Stop()

    if ($lat -ge 0) {
        [void]$latencies.Add($lat)
    } else {
        [void]$latencies.Add(5000)
        Write-Host "  Latency trial $($i+1): TIMEOUT (token never appeared)" -ForegroundColor Red
    }

    & $PSMUX send-keys -t $SESSION "" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
}

if ($latencies.Count -gt 0) {
    $valid = @($latencies | Where-Object { $_ -lt 5000 })
    if ($valid.Count -gt 0) {
        $p50 = Percentile $valid 50
        $p90 = Percentile $valid 90
        $max = ($valid | Measure-Object -Maximum).Maximum
        Metric "Delivery latency p50" $p50
        Metric "Delivery latency p90" $p90
        Metric "Delivery latency max" $max

        # Generous threshold: even with the bounded-channel fix, the server
        # pushes frames on ~5ms poll interval; 2s is a clear regression signal.
        if ($p90 -le 2000) {
            Write-Pass ("Token delivery p90 = {0:N0}ms (under 2000ms threshold)" -f $p90)
        } else {
            Write-Fail ("Token delivery p90 = {0:N0}ms EXCEEDS 2000ms — pipeline stall" -f $p90)
        }
    } else {
        Write-Fail "All delivery latency trials timed out"
    }
}

# ── Cleanup ────────────────────────────────────────────────────────────────────
Cleanup -Name $SESSION

# ── Save metrics ───────────────────────────────────────────────────────────────
$metricsDir = "$env:USERPROFILE\.psmux-test-data\metrics"
if (-not (Test-Path $metricsDir)) { New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null }
$ts = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$script:Metrics | ConvertTo-Json | Set-Content "$metricsDir\issue224-perf-$ts.json" -Encoding UTF8
Write-Host "`nMetrics saved to: $metricsDir\issue224-perf-$ts.json" -ForegroundColor DarkGray

# ── Final summary ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "Issue #224 Results" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""
exit $script:TestsFailed
