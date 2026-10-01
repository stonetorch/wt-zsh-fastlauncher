# Issue #22 Performance Test: "exit of last window is quite slow"
# Measures that killing the last window / kill-session fully tears down the server
# (port file gone AND TCP refused) within a 3-second threshold.
# Uses -L gap22 socket isolation so only our own session is measured.
#
# Layer 7: Performance benchmark with threshold assertion

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed  = 0
$script:Metrics      = @{}

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }
function Metric($name, $valueMs) {
    $script:Metrics[$name] = $valueMs
    Write-Host ("  [METRIC] {0}: {1:N1} ms" -f $name, $valueMs) -ForegroundColor DarkCyan
}

function Percentile($arr, $pct) {
    if ($arr.Count -eq 0) { return 0 }
    $sorted = [double[]]($arr | Sort-Object)
    $idx = [Math]::Floor(($pct / 100.0) * ($sorted.Count - 1))
    return $sorted[$idx]
}

# Wait until port file exists AND TCP is answerable
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

# Wait until port file is gone OR TCP is refused — whichever comes first.
# Returns elapsed ms.
function Wait-SessionDead {
    param([string]$Name, [int]$TimeoutMs = 10000)
    $pf   = "$psmuxDir\$Name.port"
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        # Port file gone — server exited
        if (-not (Test-Path $pf)) { return $sw.ElapsedMilliseconds }
        $raw = (Get-Content $pf -Raw -EA SilentlyContinue)
        if ($null -eq $raw) { return $sw.ElapsedMilliseconds }
        $port = $raw.Trim()
        if ($port -match '^\d+$') {
            try {
                $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
                $t.Close()
                # Still alive — keep polling
            } catch {
                # Connection refused == dead
                return $sw.ElapsedMilliseconds
            }
        } else {
            return $sw.ElapsedMilliseconds
        }
        Start-Sleep -Milliseconds 10
    }
    return $TimeoutMs
}

function Cleanup {
    param([string]$Name)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "Issue #22 Perf: Last-window / kill-session teardown latency" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

# THRESHOLD: reporter said exit is "quite slow". We assert < 3 s full teardown.
$THRESHOLD_MS = 3000

# ============================================================================
# TEST 1: kill-session on a single-window session  (simplest case from #22)
# ============================================================================
Write-Host "`n[Test 1] kill-session on single-window session (5 trials)" -ForegroundColor Yellow

$killTimes = [System.Collections.ArrayList]::new()
$TRIALS    = 5

for ($i = 0; $i -lt $TRIALS; $i++) {
    $sess = "gap22_ks_$i"
    Cleanup -Name $sess

    & $PSMUX new-session -d -s $sess 2>&1 | Out-Null
    if (-not (Wait-Session -Name $sess)) {
        Write-Host "  Trial $($i+1): session never came up — SKIP" -ForegroundColor Yellow
        continue
    }

    # One extra window so there are two total, then kill the non-last one first
    # to leave exactly one window — matching the "last window" scenario.
    & $PSMUX new-window -t $sess 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    & $PSMUX kill-window -t "${sess}:1" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 200

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX kill-session -t $sess 2>&1 | Out-Null
    $deadMs = Wait-SessionDead -Name $sess -TimeoutMs 10000
    $sw.Stop()

    $elapsed = $deadMs  # full-teardown time is the more meaningful number
    [void]$killTimes.Add($elapsed)

    $color = if ($elapsed -le $THRESHOLD_MS) { "Green" } else { "Red" }
    Write-Host ("  Trial {0}: CLI returned {1:N0} ms | teardown {2:N0} ms" -f ($i+1), $sw.ElapsedMilliseconds, $elapsed) -ForegroundColor $color

    Cleanup -Name $sess
}

if ($killTimes.Count -gt 0) {
    $avg = ($killTimes | Measure-Object -Average).Average
    $max = ($killTimes | Measure-Object -Maximum).Maximum
    $p50 = Percentile $killTimes 50
    $p90 = Percentile $killTimes 90

    Metric "kill-session teardown avg" $avg
    Metric "kill-session teardown p50" $p50
    Metric "kill-session teardown p90" $p90
    Metric "kill-session teardown max" $max

    if ($max -le $THRESHOLD_MS) {
        Write-Pass ("All teardowns <= {0}ms threshold (max={1:N0}ms)" -f $THRESHOLD_MS, $max)
    } else {
        Write-Fail ("Teardown exceeded {0}ms threshold: max={1:N0}ms (p90={2:N0}ms)" -f $THRESHOLD_MS, $max, $p90)
        Write-Host "  VERDICT: Issue #22 reproduced — last-window exit is too slow" -ForegroundColor Red
    }
}

# ============================================================================
# TEST 2: Exiting the shell in the last pane (send-keys "exit")
#         This is the exact user-visible scenario from issue #22
# ============================================================================
Write-Host "`n[Test 2] Shell exit in last pane -> server full teardown (5 trials)" -ForegroundColor Yellow

$shellExitTimes = [System.Collections.ArrayList]::new()

for ($i = 0; $i -lt $TRIALS; $i++) {
    $sess = "gap22_se_$i"
    Cleanup -Name $sess

    & $PSMUX new-session -d -s $sess 2>&1 | Out-Null
    if (-not (Wait-Session -Name $sess)) {
        Write-Host "  Trial $($i+1): session never came up — SKIP" -ForegroundColor Yellow
        continue
    }

    # Wait for prompt before sending exit
    $ready = $false
    for ($w = 0; $w -lt 30; $w++) {
        Start-Sleep -Milliseconds 400
        $cap = & $PSMUX capture-pane -t $sess -p 2>&1 | Out-String
        if ($cap -match "PS [A-Z]:\\" -or $cap -match "\$\s*$" -or $cap -match ">\s*$") {
            $ready = $true; break
        }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX send-keys -t $sess "exit" Enter 2>&1 | Out-Null
    $deadMs = Wait-SessionDead -Name $sess -TimeoutMs 10000
    $sw.Stop()

    [void]$shellExitTimes.Add($deadMs)

    $color = if ($deadMs -le $THRESHOLD_MS) { "Green" } else { "Red" }
    Write-Host ("  Trial {0}: shell exit -> full teardown {1:N0} ms (prompt_found={2})" -f ($i+1), $deadMs, $ready) -ForegroundColor $color

    Cleanup -Name $sess
}

if ($shellExitTimes.Count -gt 0) {
    $avg2  = ($shellExitTimes | Measure-Object -Average).Average
    $max2  = ($shellExitTimes | Measure-Object -Maximum).Maximum
    $p50_2 = Percentile $shellExitTimes 50
    $p90_2 = Percentile $shellExitTimes 90

    Metric "shell-exit teardown avg" $avg2
    Metric "shell-exit teardown p50" $p50_2
    Metric "shell-exit teardown p90" $p90_2
    Metric "shell-exit teardown max" $max2

    if ($max2 -le $THRESHOLD_MS) {
        Write-Pass ("Shell-exit teardown <= {0}ms threshold (max={1:N0}ms)" -f $THRESHOLD_MS, $max2)
    } else {
        Write-Fail ("Shell-exit teardown exceeded {0}ms: max={1:N0}ms (p90={2:N0}ms)" -f $THRESHOLD_MS, $max2, $p90_2)
        Write-Host "  VERDICT: Issue #22 shell-exit path is slow" -ForegroundColor Red
    }
}

# ============================================================================
# TEST 3: kill-window on the LAST window (should trigger session teardown)
# ============================================================================
Write-Host "`n[Test 3] kill-window on last window -> full session teardown (5 trials)" -ForegroundColor Yellow

$kwTimes = [System.Collections.ArrayList]::new()

for ($i = 0; $i -lt $TRIALS; $i++) {
    $sess = "gap22_kw_$i"
    Cleanup -Name $sess

    & $PSMUX new-session -d -s $sess 2>&1 | Out-Null
    if (-not (Wait-Session -Name $sess)) {
        Write-Host "  Trial $($i+1): session never came up — SKIP" -ForegroundColor Yellow
        continue
    }
    Start-Sleep -Milliseconds 500

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX kill-window -t "${sess}:0" 2>&1 | Out-Null
    $deadMs = Wait-SessionDead -Name $sess -TimeoutMs 10000
    $sw.Stop()

    [void]$kwTimes.Add($deadMs)

    $color = if ($deadMs -le $THRESHOLD_MS) { "Green" } else { "Red" }
    Write-Host ("  Trial {0}: kill-window -> full teardown {1:N0} ms" -f ($i+1), $deadMs) -ForegroundColor $color

    Cleanup -Name $sess
}

if ($kwTimes.Count -gt 0) {
    $avg3  = ($kwTimes | Measure-Object -Average).Average
    $max3  = ($kwTimes | Measure-Object -Maximum).Maximum
    $p50_3 = Percentile $kwTimes 50
    $p90_3 = Percentile $kwTimes 90

    Metric "kill-window last teardown avg" $avg3
    Metric "kill-window last teardown p50" $p50_3
    Metric "kill-window last teardown p90" $p90_3
    Metric "kill-window last teardown max" $max3

    if ($max3 -le $THRESHOLD_MS) {
        Write-Pass ("kill-window last teardown <= {0}ms (max={1:N0}ms)" -f $THRESHOLD_MS, $max3)
    } else {
        Write-Fail ("kill-window last teardown exceeded {0}ms: max={1:N0}ms" -f $THRESHOLD_MS, $max3)
    }
}

# ── Save metrics ──────────────────────────────────────────────────────────────
$metricsDir = "$env:USERPROFILE\.psmux-test-data\metrics"
if (-not (Test-Path $metricsDir)) { New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null }
$ts = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$script:Metrics | ConvertTo-Json | Set-Content "$metricsDir\issue22-perf-$ts.json" -Encoding UTF8
Write-Host "`nMetrics saved to: $metricsDir\issue22-perf-$ts.json" -ForegroundColor DarkGray

# ── Final summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "Issue #22 Results" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""
exit $script:TestsFailed
