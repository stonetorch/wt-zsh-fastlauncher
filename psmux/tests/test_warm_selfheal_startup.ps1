# Regression test: warm self-heal startup.
#
# Bug: when the warm handoff file (<ns>____warm__.port) points at a LIVE but
# NON-warm server (stale pointer from duplicated-warm churn, or OS ephemeral
# port reuse), the CLI used to COMMIT the claim on ANY non-OK response. The
# server replies "ERR: not a warm server (already claimed)", the CLI ignored
# it, waited the full ~5s port-file timeout for a session that never appeared,
# and FAILED the open (exit 1). Every subsequent open in the degraded state hit
# the same ~5.4s cold/failed path.
#
# Fix: on an explicit ERR claim response, do NOT commit; cold-spawn cleanly.
# The stale handoff file is consumed during the attempt, so the bad warm
# pointer self-heals and later opens are fast again.
#
# This test runs ENTIRELY in an isolated -L heal namespace and NEVER touches
# the user's real __warm__ server. It asserts the first open after a forged bad
# pointer completes well under the cold-path time (would FAIL at ~5.4s) and that
# the namespace never ends up with more than one live warm server.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$NS = "healtest"                 # isolated namespace (distinct from manual repro 'heal')
$WARMBASE = "${NS}____warm__"
$script:TestsPassed = 0
$script:TestsFailed = 0
$THRESHOLD_MS = 2500             # would FAIL on the ~5.4s cold/failed path

function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup-NS {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\${NS}_*" -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 200
}

function Time-Open {
    param([string]$Name)
    Remove-Item "$psmuxDir\${NS}__$Name.*" -Force -EA SilentlyContinue
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX -L $NS new-session -d -s $Name 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    $pf = "$psmuxDir\${NS}__$Name.port"
    $ready = $false
    while ($sw.ElapsedMilliseconds -lt 15000) {
        if (Test-Path $pf) {
            $p = (Get-Content $pf -Raw).Trim()
            if ($p -match '^\d+$') {
                try { $t=[System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$p); $t.Close(); $ready=$true; break } catch {}
            }
        }
        Start-Sleep -Milliseconds 5
    }
    $sw.Stop()
    return @{ Ms=$sw.ElapsedMilliseconds; Ready=$ready; Rc=$rc }
}

function Count-LiveWarm {
    $n = 0
    foreach ($pf in (Get-ChildItem "$psmuxDir\${NS}____warm__*.port" -EA SilentlyContinue)) {
        $p = (Get-Content $pf.FullName -Raw).Trim()
        if ($p -match '^\d+$') {
            try { $t=[System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$p); $t.Close(); $n++ } catch {}
        }
    }
    return $n
}

Write-Host "`n=== Warm self-heal startup regression (-L $NS) ===" -ForegroundColor Cyan

try {
    Cleanup-NS

    # --- Build the degraded state: a live decoy server + a forged warm pointer
    #     that points at the decoy (a real, already-claimed, NON-warm session). ---
    & $PSMUX -L $NS new-session -d -s decoy 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    if (-not (Test-Path "$psmuxDir\${NS}__decoy.port")) {
        Write-Fail "setup: decoy session did not start"
        Cleanup-NS
        Write-Host "`nPassed: $script:TestsPassed  Failed: $script:TestsFailed"
        exit 1
    }
    $decoyPort = (Get-Content "$psmuxDir\${NS}__decoy.port" -Raw).Trim()
    $decoyKey  = (Get-Content "$psmuxDir\${NS}__decoy.key"  -Raw).Trim()

    Remove-Item "$psmuxDir\$WARMBASE.port" -Force -EA SilentlyContinue
    Set-Content "$psmuxDir\$WARMBASE.port" $decoyPort -NoNewline -Encoding ascii
    Set-Content "$psmuxDir\$WARMBASE.key"  $decoyKey  -NoNewline -Encoding ascii
    Set-Content "$psmuxDir\$WARMBASE.sid"  "77" -NoNewline -Encoding ascii

    # --- Test 1: open #1 after the forged bad pointer must SUCCEED, not fail. ---
    Write-Host "[Test 1] open after forged live-wrong warm pointer" -ForegroundColor Yellow
    $r1 = Time-Open -Name "h1"
    Write-Host ("  open#1: {0}ms ready={1} exit={2}" -f $r1.Ms,$r1.Ready,$r1.Rc)
    if ($r1.Ready -and $r1.Rc -eq 0) { Write-Pass "open#1 succeeded (no exit-1 failure)" }
    else { Write-Fail "open#1 FAILED (ready=$($r1.Ready) exit=$($r1.Rc)) - the bug regressed" }
    if ($r1.Ms -lt 5000) { Write-Pass "open#1 under cold-path time ($($r1.Ms)ms < 5000ms)" }
    else { Write-Fail "open#1 too slow: $($r1.Ms)ms (>= cold path)" }

    # --- Test 2: after recovery, a later open must be FAST (warm self-healed). ---
    Write-Host "[Test 2] subsequent opens are fast (warm self-healed)" -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    $r2 = Time-Open -Name "h2"
    Start-Sleep -Seconds 2
    $r3 = Time-Open -Name "h3"
    Write-Host ("  open#2: {0}ms ready={1}  open#3: {2}ms ready={3}" -f $r2.Ms,$r2.Ready,$r3.Ms,$r3.Ready)
    if ($r2.Ready -and $r2.Rc -eq 0 -and $r3.Ready -and $r3.Rc -eq 0) { Write-Pass "open#2 and open#3 both succeeded" }
    else { Write-Fail "a later open failed (#2 ready=$($r2.Ready) exit=$($r2.Rc); #3 ready=$($r3.Ready) exit=$($r3.Rc))" }
    $fast = ($r2.Ms -lt $THRESHOLD_MS) -or ($r3.Ms -lt $THRESHOLD_MS)
    if ($fast) { Write-Pass "a post-recovery open is FAST (< ${THRESHOLD_MS}ms) -> warm path restored" }
    else { Write-Fail "no post-recovery open under ${THRESHOLD_MS}ms (#2=$($r2.Ms) #3=$($r3.Ms))" }

    # --- Test 3: never more than one live warm server in the namespace. ---
    Write-Host "[Test 3] at most one live warm server" -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    $warm = Count-LiveWarm
    if ($warm -le 1) { Write-Pass "<=1 live warm server (got $warm)" }
    else { Write-Fail "$warm live warm servers in namespace (>1)" }

    # --- Test 4: warm RESPAWNS after stale live-wrong pointer (respawn-side fix).
    #     Before the respawn fix: spawn_warm_server checked TCP only -> returned
    #     early on the live decoy -> warm never re-established -> open#2 stayed
    #     cold (~1200ms).  After fix: server AUTHs and checks session_name ==
    #     "__warm__"; on mismatch it prunes the stale pointer and spawns a genuine
    #     warm, so open#2 is a real warm claim (< 800ms, well under cold ~1200ms).
    Write-Host "[Test 4] warm re-establishes after stale live-wrong pointer (respawn fix)" -ForegroundColor Yellow
    Cleanup-NS

    & $PSMUX -L $NS new-session -d -s decoy2 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    if (-not (Test-Path "$psmuxDir\${NS}__decoy2.port")) {
        Write-Fail "Test 4 setup: decoy2 session did not start"
    } else {
        $dp2 = (Get-Content "$psmuxDir\${NS}__decoy2.port" -Raw).Trim()
        $dk2 = (Get-Content "$psmuxDir\${NS}__decoy2.key"  -Raw).Trim()

        Remove-Item "$psmuxDir\$WARMBASE.port" -Force -EA SilentlyContinue
        Set-Content "$psmuxDir\$WARMBASE.port" $dp2 -NoNewline -Encoding ascii
        Set-Content "$psmuxDir\$WARMBASE.key"  $dk2 -NoNewline -Encoding ascii
        Set-Content "$psmuxDir\$WARMBASE.sid"  "77"  -NoNewline -Encoding ascii

        # open#1 recovers via claim-side fix (cold-spawns cleanly).
        # The cold-spawned server calls spawn_warm_server: with respawn fix it
        # AUTHs the decoy, gets wrong name, prunes pointer, spawns genuine warm.
        $t4r1 = Time-Open -Name "t4s1"
        Write-Host ("  T4 open#1: {0}ms ready={1} exit={2}" -f $t4r1.Ms,$t4r1.Ready,$t4r1.Rc)
        if ($t4r1.Ready -and $t4r1.Rc -eq 0) { Write-Pass "T4 open#1 succeeded" }
        else { Write-Fail "T4 open#1 FAILED (ready=$($t4r1.Ready) exit=$($t4r1.Rc))" }

        # Wait for warm server to finish loading its shell.
        Start-Sleep -Seconds 5
        $t4wc = Count-LiveWarm
        if ($t4wc -ge 1) { Write-Pass "T4 warm re-established after open#1 (count=$t4wc)" }
        else { Write-Fail "T4 warm NOT re-established after open#1 (count=$t4wc)" }

        # open#2: must claim the new genuine warm — port equality proves it.
        $warmPortBefore = (Get-Content "$psmuxDir\$WARMBASE.port" -Raw -EA SilentlyContinue).Trim()
        $t4r2 = Time-Open -Name "t4s2"
        $t4s2Port = (Get-Content "$psmuxDir\${NS}__t4s2.port" -Raw -EA SilentlyContinue).Trim()
        $claimed = ($t4s2Port -ne "" -and $t4s2Port -eq $warmPortBefore)
        Write-Host ("  T4 open#2: {0}ms ready={1} claimed={2}" -f $t4r2.Ms,$t4r2.Ready,$claimed)

        if ($t4r2.Ready -and $t4r2.Rc -eq 0) { Write-Pass "T4 open#2 succeeded" }
        else { Write-Fail "T4 open#2 FAILED (ready=$($t4r2.Ready) exit=$($t4r2.Rc))" }

        # 800ms threshold: warm claim is ~400-600ms here; cold is ~1200ms+
        if ($t4r2.Ms -lt 800) { Write-Pass "T4 open#2 warm-fast ($($t4r2.Ms)ms < 800ms) -> warm respawned" }
        else { Write-Fail "T4 open#2 still cold: $($t4r2.Ms)ms >= 800ms (warm did NOT respawn)" }

        if ($claimed) { Write-Pass "T4 open#2 claimed the respawned warm (port match)" }
        else { Write-Fail "T4 open#2 did NOT claim warm (port mismatch: got '$t4s2Port' want '$warmPortBefore')" }
    }
}
finally {
    Cleanup-NS
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host ("  Passed: {0}" -f $script:TestsPassed) -ForegroundColor Green
Write-Host ("  Failed: {0}" -f $script:TestsFailed) -ForegroundColor $(if($script:TestsFailed -gt 0){"Red"}else{"Green"})
exit $script:TestsFailed
