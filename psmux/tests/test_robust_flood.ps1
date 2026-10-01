# test_robust_flood.ps1
# EXTREME robustness campaign: HIGH-THROUGHPUT OUTPUT FLOOD + RENDER CORRECTNESS
# Thesis: psmux stays responsive and renders correctly under heavy/fast/awkward output.
# Namespace: rbFlood (EVERY psmux call passes -L rbFlood FIRST).
# Cleanup ONLY via `& psmux -L rbFlood kill-server` in finally. NEVER global kill.
#
# NOTE: panes are driven by sending PowerShell commands and polling capture-pane
# for a UNIQUE marker token (bounded timeout) to PROVE output rendered through the
# flood and the pane is still consuming input AFTER the flood.

$ErrorActionPreference = "Continue"

# ---- Test harness counters / helpers ----
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass {
    param([string]$Message)
    $script:TestsPassed++
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    $script:TestsFailed++
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

$L = "rbFlood"
$Session = "rbFlood_main"

# Send a command (shell is PowerShell inside the pane) to a target.
function Send-Pane {
    param([string]$Target, [string]$Command)
    & psmux -L $L send-keys -t $Target $Command Enter | Out-Null
}

# Poll capture-pane on a target until $Marker appears or timeout (seconds) elapses.
# Returns $true if the marker rendered, $false otherwise.
function Wait-ForMarker {
    param(
        [string]$Target,
        [string]$Marker,
        [int]$TimeoutSec = 20,
        [switch]$Escapes
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($Escapes) {
            $out = (& psmux -L $L capture-pane -t $Target -e -p 2>$null) | Out-String
        } else {
            $out = (& psmux -L $L capture-pane -t $Target -p 2>$null) | Out-String
        }
        if ($out -and $out.Contains($Marker)) {
            return $true
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# Capture-pane returning text without throwing (best-effort liveness probe).
function Get-PaneText {
    param([string]$Target, [switch]$Escapes)
    if ($Escapes) {
        return (& psmux -L $L capture-pane -t $Target -e -p 2>$null) | Out-String
    }
    return (& psmux -L $L capture-pane -t $Target -p 2>$null) | Out-String
}

# ============================================================================
Write-Host "=== psmux ROBUSTNESS: OUTPUT FLOOD + RENDER CORRECTNESS (-L rbFlood) ===" -ForegroundColor Magenta

try {
    # Clean slate for this namespace only (ignore failure if no server yet).
    & psmux -L $L kill-server 2>$null | Out-Null

    # ---- Setup: create detached session, prove alive ----
    Write-Info "Creating detached session $Session"
    & psmux -L $L new-session -d -s $Session -x 200 -y 50 | Out-Null
    Start-Sleep -Seconds 3

    $sessList = (& psmux -L $L list-sessions 2>$null) | Out-String
    if ($LASTEXITCODE -eq 0 -and $sessList.Contains($Session)) {
        Write-Pass "Session $Session created and listed (server alive)"
    } else {
        Write-Fail "Session $Session not created/listed -- aborting scenarios"
        throw "setup-failed"
    }

    # Settle the prompt with a sentinel before flooding.
    Send-Pane -Target "$Session.0" -Command "echo SETUP_READY"
    if (Wait-ForMarker -Target "$Session.0" -Marker "SETUP_READY" -TimeoutSec 20) {
        Write-Pass "Pane .0 prompt responsive before flood (SETUP_READY)"
    } else {
        Write-Fail "Pane .0 did not echo SETUP_READY -- prompt not ready"
    }

    # ------------------------------------------------------------------
    # SCENARIO 1: BIG SCROLL FLOOD (20000 lines), then FLOOD_DONE_1
    # ------------------------------------------------------------------
    Write-Info "SCENARIO 1: BIG SCROLL FLOOD (20000 lines)"
    Send-Pane -Target "$Session.0" -Command '1..20000 | ForEach-Object { "LINE_$_" }; echo FLOOD_DONE_1'
    if (Wait-ForMarker -Target "$Session.0" -Marker "FLOOD_DONE_1" -TimeoutSec 20) {
        Write-Pass "BIG SCROLL FLOOD: FLOOD_DONE_1 rendered (no deadlock under 20k lines)"
    } else {
        Write-Fail "BIG SCROLL FLOOD: FLOOD_DONE_1 never appeared"
    }

    # ------------------------------------------------------------------
    # SCENARIO 2: FAST TIGHT LOOP (CPU-busy pane stays controllable)
    # ------------------------------------------------------------------
    Write-Info "SCENARIO 2: FAST TIGHT LOOP (50000 iterations)"
    Send-Pane -Target "$Session.0" -Command 'for($i=0;$i -lt 50000;$i++){[void]$i}; echo FLOOD_DONE_2'
    if (Wait-ForMarker -Target "$Session.0" -Marker "FLOOD_DONE_2" -TimeoutSec 20) {
        Write-Pass "FAST TIGHT LOOP: FLOOD_DONE_2 rendered (busy pane stayed controllable)"
    } else {
        Write-Fail "FAST TIGHT LOOP: FLOOD_DONE_2 never appeared"
    }

    # ------------------------------------------------------------------
    # SCENARIO 3: VERY LONG SINGLE LINE (20000 chars), then FLOOD_DONE_3
    # ------------------------------------------------------------------
    Write-Info "SCENARIO 3: VERY LONG SINGLE LINE (20000 chars)"
    Send-Pane -Target "$Session.0" -Command "Write-Output ('X'*20000); echo FLOOD_DONE_3"
    if (Wait-ForMarker -Target "$Session.0" -Marker "FLOOD_DONE_3" -TimeoutSec 20) {
        Write-Pass "VERY LONG SINGLE LINE: FLOOD_DONE_3 rendered after 20k-char line"
    } else {
        Write-Fail "VERY LONG SINGLE LINE: FLOOD_DONE_3 never appeared"
    }
    # Best-effort: capture-pane returns text without error after the long line.
    $longCap = Get-PaneText -Target "$Session.0"
    if ($longCap -and $longCap.Length -gt 0) {
        Write-Pass "VERY LONG SINGLE LINE: capture-pane returned text without error"
    } else {
        Write-Fail "VERY LONG SINGLE LINE: capture-pane returned empty/failed"
    }

    # ------------------------------------------------------------------
    # SCENARIO 4: ANSI / SGR STORM (2000 colored lines), then FLOOD_DONE_5
    # ------------------------------------------------------------------
    Write-Info "SCENARIO 4: ANSI / SGR STORM (2000 colored lines)"
    # Build the colored-line emitter in the pane's PowerShell:
    # ESC[31m ... ESC[0m wrapping each line, 2000 lines.
    $ansiCmd = '$e=[char]27; 1..2000 | ForEach-Object { "$e[31mCOLOR_$_$e[0m" }; echo FLOOD_DONE_5'
    Send-Pane -Target "$Session.0" -Command $ansiCmd
    if (Wait-ForMarker -Target "$Session.0" -Marker "FLOOD_DONE_5" -TimeoutSec 20) {
        Write-Pass "ANSI / SGR STORM: FLOOD_DONE_5 rendered after 2000 colored lines"
    } else {
        Write-Fail "ANSI / SGR STORM: FLOOD_DONE_5 never appeared"
    }
    # capture-pane -e (escapes preserved path) must return text and not crash.
    $ansiCap = Get-PaneText -Target "$Session.0" -Escapes
    if ($ansiCap -and $ansiCap.Length -gt 0) {
        Write-Pass "ANSI / SGR STORM: capture-pane -e returned text (escape path OK)"
    } else {
        Write-Fail "ANSI / SGR STORM: capture-pane -e returned empty/failed"
    }

    # ------------------------------------------------------------------
    # SCENARIO 5: RAPID CLEAR/REDRAW (50 cls + echo TICK), then FLOOD_DONE_4
    # ------------------------------------------------------------------
    Write-Info "SCENARIO 5: RAPID CLEAR/REDRAW (50 iterations)"
    # Do the whole clear/redraw loop in one pane command so it is a tight burst.
    $clearCmd = 'for($i=0;$i -lt 50;$i++){ Clear-Host; Write-Output "TICK_$i" }; echo FLOOD_DONE_4'
    Send-Pane -Target "$Session.0" -Command $clearCmd
    if (Wait-ForMarker -Target "$Session.0" -Marker "FLOOD_DONE_4" -TimeoutSec 20) {
        Write-Pass "RAPID CLEAR/REDRAW: FLOOD_DONE_4 rendered (repeated clears did not wedge)"
    } else {
        Write-Fail "RAPID CLEAR/REDRAW: FLOOD_DONE_4 never appeared"
    }

    # ------------------------------------------------------------------
    # SCENARIO 6: CONCURRENT MULTI-PANE FLOOD (3 panes; .0 and .1 flood, .2 marker)
    # ------------------------------------------------------------------
    Write-Info "SCENARIO 6: CONCURRENT MULTI-PANE FLOOD (split to 3 panes)"
    & psmux -L $L split-window -h -t "$Session.0" | Out-Null
    Start-Sleep -Milliseconds 800
    & psmux -L $L split-window -v -t "$Session.1" | Out-Null
    Start-Sleep -Milliseconds 800

    $paneCount = (& psmux -L $L display-message -p -t $Session '#{window_panes}' 2>$null) | Out-String
    $paneCount = $paneCount.Trim()
    if ($paneCount -eq "3") {
        Write-Pass "CONCURRENT MULTI-PANE: window_panes == 3"
    } else {
        Write-Fail "CONCURRENT MULTI-PANE: window_panes == '$paneCount' (expected 3)"
    }

    # Start a moderate flood in .0 and .1 'simultaneously' (no wait between sends).
    Send-Pane -Target "$Session.0" -Command '1..5000 | ForEach-Object { "P0_$_" }'
    Send-Pane -Target "$Session.1" -Command '1..5000 | ForEach-Object { "P1_$_" }'
    # While .0 and .1 are busy, .2 must promptly echo its marker.
    Send-Pane -Target "$Session.2" -Command "echo PANE2_ALIVE"
    if (Wait-ForMarker -Target "$Session.2" -Marker "PANE2_ALIVE" -TimeoutSec 20) {
        Write-Pass "CONCURRENT MULTI-PANE: pane .2 echoed PANE2_ALIVE (no starvation)"
    } else {
        Write-Fail "CONCURRENT MULTI-PANE: pane .2 starved (PANE2_ALIVE missing)"
    }

    # Pane count must still be 3 after the concurrent flood.
    $paneCount2 = (& psmux -L $L display-message -p -t $Session '#{window_panes}' 2>$null) | Out-String
    $paneCount2 = $paneCount2.Trim()
    if ($paneCount2 -eq "3") {
        Write-Pass "CONCURRENT MULTI-PANE: window_panes still == 3 after flood"
    } else {
        Write-Fail "CONCURRENT MULTI-PANE: window_panes == '$paneCount2' after flood (expected 3)"
    }

    # ------------------------------------------------------------------
    # SCENARIO 7: RESPONSIVENESS DURING FLOOD (control plane not blocked)
    # ------------------------------------------------------------------
    Write-Info "SCENARIO 7: RESPONSIVENESS DURING FLOOD (30000-line flood in .0)"
    # Kick off a long flood in .0 and do NOT wait.
    Send-Pane -Target "$Session.0" -Command '1..30000 | ForEach-Object { "RESP_$_" }'
    # Immediately query the control plane; it should answer within a couple seconds.
    $ctrlStart = Get-Date
    $sessName = (& psmux -L $L display-message -p '#{session_name}' 2>$null) | Out-String
    $sessName = $sessName.Trim()
    $ctrlElapsed = ((Get-Date) - $ctrlStart).TotalSeconds
    if ($sessName -eq $Session -and $ctrlElapsed -lt 5) {
        Write-Pass "RESPONSIVENESS: control plane returned '$Session' in $([math]::Round($ctrlElapsed,2))s during flood"
    } elseif ($sessName -eq $Session) {
        Write-Fail "RESPONSIVENESS: control plane returned correct name but slow ($([math]::Round($ctrlElapsed,2))s)"
    } else {
        Write-Fail "RESPONSIVENESS: control plane returned '$sessName' (expected $Session)"
    }

    # ------------------------------------------------------------------
    # SCENARIO 8: BINARY-ISH / CONTROL BYTES (tab, bell, BS, CR, FF) + marker
    # ------------------------------------------------------------------
    Write-Info "SCENARIO 8: BINARY-ISH / CONTROL BYTES"
    # Build a string mixing TAB(9), BELL(7), BACKSPACE(8), CR(13), FORMFEED(12) with text,
    # then a unique marker. Done inside the pane shell.
    $ctlCmd = '$t=[char]9;$b=[char]7;$bs=[char]8;$cr=[char]13;$ff=[char]12; Write-Output ("A"+$t+"B"+$b+"C"+$bs+"D"+$cr+"E"+$ff+"F"); echo FLOOD_DONE_6'
    Send-Pane -Target "$Session.0" -Command $ctlCmd
    if (Wait-ForMarker -Target "$Session.0" -Marker "FLOOD_DONE_6" -TimeoutSec 20) {
        Write-Pass "BINARY-ISH / CONTROL BYTES: FLOOD_DONE_6 rendered (control bytes did not break pane)"
    } else {
        Write-Fail "BINARY-ISH / CONTROL BYTES: FLOOD_DONE_6 never appeared"
    }

    # ------------------------------------------------------------------
    # FINAL: server alive + session prompt still works
    # ------------------------------------------------------------------
    Write-Info "FINAL: verifying server alive and prompt working"
    & psmux -L $L list-sessions 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "FINAL: list-sessions exit 0 (server still alive)"
    } else {
        Write-Fail "FINAL: list-sessions non-zero exit (server unhealthy)"
    }

    Send-Pane -Target "$Session.2" -Command "echo FINAL_OK"
    if (Wait-ForMarker -Target "$Session.2" -Marker "FINAL_OK" -TimeoutSec 20) {
        Write-Pass "FINAL: session prompt still works (FINAL_OK echoed)"
    } else {
        Write-Fail "FINAL: session prompt did not echo FINAL_OK"
    }
}
catch {
    Write-Fail "Unexpected exception: $($_.Exception.Message)"
}
finally {
    Write-Info "Cleanup: killing rbFlood server only"
    & psmux -L $L kill-server 2>$null | Out-Null
}

# ---- Results footer ----
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Magenta
Write-Host "Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "Failed: $script:TestsFailed" -ForegroundColor Red

exit $script:TestsFailed
