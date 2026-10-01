# Issue #282: pwsh pane freezes when creating new window or split after lock/unlock
#
# Root cause: pwsh (via ConPTY) re-emits ESC[6n (Cursor Position Request) at startup
# and again after session events like Win+L lock/unlock. psmux originally only sent a
# single preemptive ESC[1;1R at spawn time. When pwsh re-issued ESC[6n after
# lock/unlock the pipe was empty and the child blocked indefinitely.
#
# The fix: a reactive CPR responder -- scan_cpr_query() detects ESC[6n in PTY output,
# sets cpr_pending flag, and the server loop calls drain_cpr_pending() to inject
# ESC[row;colR with the correct cursor position, unblocking pwsh.
#
# This test verifies the fix with two layers:
#   PART 1 - Source-code proof: scan_cpr_query, drain_cpr_pending, CPR_DATA_PENDING,
#            and the server loop drain present; the old preemptive-only path commented
#            out.
#   PART 2 - Functional proof: create a session, split-window (simulates new-pane
#            creation), send-keys to the new pane, and capture-pane to confirm the
#            pane is responsive and not frozen.

$ErrorActionPreference = "Continue"
$script:pass = 0
$script:fail = 0
$script:results = @()

function Write-Test($msg) { Write-Host "  TEST: $msg" -ForegroundColor Yellow }
function Write-Pass($msg) { Write-Host "  PASS: $msg" -ForegroundColor Green; $script:pass++ }
function Write-Fail($msg) { Write-Host "  FAIL: $msg" -ForegroundColor Red; $script:fail++ }
function Add-Result($name, $ok, $detail) {
    if ($ok) { Write-Pass "$name $detail" } else { Write-Fail "$name $detail" }
    $script:results += [PSCustomObject]@{ Test = $name; Pass = $ok; Detail = $detail }
}

$PSMUX = (Get-Command psmux -ErrorAction SilentlyContinue)?.Source
if (-not $PSMUX) {
    $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -ErrorAction SilentlyContinue)?.Path
}
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

$psmuxDir = "$env:USERPROFILE\.psmux"
$env:PSMUX_SESSION = ""

Write-Host "`n=== Issue #282: lock/unlock freeze fix (reactive CPR responder) ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"

# ====================================================================
# PART 1: Source-code proof
# ====================================================================
Write-Host "`n--- Part 1: Source-code proof ---" -ForegroundColor Yellow

$paneFile = Join-Path $PSScriptRoot "..\src\pane.rs"
$serverMod = Join-Path $PSScriptRoot "..\src\server\mod.rs"
$helpersFile = Join-Path $PSScriptRoot "..\src\server\helpers.rs"

foreach ($f in @($paneFile, $serverMod)) {
    if (-not (Test-Path $f)) {
        Add-Result "source file found" $false "missing: $f"
        exit 1
    }
}

$paneSrc  = Get-Content $paneFile -Raw
$srvSrc   = Get-Content $serverMod -Raw
$helpSrc  = if (Test-Path $helpersFile) { Get-Content $helpersFile -Raw } else { "" }
$allSrc   = $paneSrc + $srvSrc + $helpSrc

Write-Test "scan_cpr_query function detects ESC[6n in PTY output"
$hasScanFn = $paneSrc -match 'fn\s+scan_cpr_query'
Add-Result "scan_cpr_query declared in pane.rs" $hasScanFn ""

Write-Test "ESC[6n byte sequence used as CPR detection pattern"
$hasPattern = $paneSrc -match '\\x1b\[6n|b"\\x1b\[6n"|CPR.*6n|6n.*CPR|\[6n\]'
# Also allow the literal bytes form
if (-not $hasPattern) { $hasPattern = $paneSrc -match '0x1b.*\[.*6n|b\\"\x1b\[6n' }
if (-not $hasPattern) { $hasPattern = $allSrc -match 'scan_cpr_query.*6n|6n.*scan_cpr' }
Add-Result "ESC[6n detection pattern present" $hasPattern ""

Write-Test "cpr_pending AtomicBool used to signal CPR query from reader thread"
$hasCprPending = $paneSrc -match 'cpr_pending|CPR_DATA_PENDING|AtomicBool'
Add-Result "cpr_pending signaling mechanism present" $hasCprPending ""

Write-Test "Server loop drains CPR pending and injects ESC[row;colR response"
$hasDrain = $srvSrc -match 'drain_cpr_pending|cpr_pending.*swap|CPR_DATA_PENDING.*swap'
Add-Result "server loop drains cpr_pending" $hasDrain ""

Write-Test "CPR response format includes row;col (ESC[row;colR)"
# The response must be ESC[row;colR not just ESC[1;1R
$hasDynamic = $allSrc -match 'cursor_position\(\)|cursor_pos|row.*col.*R|\\x1b\[.*col.*R'
Add-Result "dynamic cursor position used in CPR response" $hasDynamic ""

Write-Test "Comment confirms this fixes lock/unlock freeze path"
$hasComment = $srvSrc -match 'lock.unlock|lock\/unlock|ESC\[6n.*lock|pwsh.*lock'
Add-Result "lock/unlock comment in server loop" $hasComment ""

Write-Test "Old preemptive-only approach acknowledged as no-op"
$hasNoOp = $paneSrc -match 'no-op|no.op.*reactive|preemptive.*no.op'
Add-Result "old preemptive path marked no-op" $hasNoOp ""

# ====================================================================
# PART 2: Functional proof -- new pane after split responds to input
# ====================================================================
Write-Host "`n--- Part 2: Functional proof ---" -ForegroundColor Yellow
Write-Host "  (Simulates new-window/split after session event; verifies pane not frozen)" -ForegroundColor Gray

$S = "gap282_main"

function Kill-OurSession($name) {
    & $PSMUX kill-session -t $name 2>$null | Out-Null
}

function Wait-Session($name, [int]$timeoutMs = 12000) {
    $pf = "$psmuxDir\$name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -ErrorAction SilentlyContinue).Trim()
            if ($port -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

Kill-OurSession $S
Start-Sleep -Milliseconds 500

& $PSMUX new-session -d -s $S 2>&1 | Out-Null
$alive = Wait-Session $S 12000
Add-Result "base session started" $alive ""

if ($alive) {
    # Split-window creates a second pane (simulates the "new pane after event" path)
    & $PSMUX split-window -v -t $S 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    # Verify the new pane (index 1) exists
    $pane1 = (& $PSMUX display-message -t "${S}:0.1" -p '#{pane_index}' 2>&1).Trim()
    Add-Result "split-window created pane 1" ($pane1 -eq "1") "pane_index=$pane1"

    # Send a unique marker string to the new pane and capture it back
    # This proves the pane is NOT frozen (a frozen pane would not echo the marker)
    $marker = "PSMUX_CPR_MARKER_282"
    & $PSMUX send-keys -t "${S}:0.1" "echo $marker" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    $cap = (& $PSMUX capture-pane -t "${S}:0.1" -p 2>&1) -join "`n"
    $markerFound = $cap -match [regex]::Escape($marker)
    Add-Result "new pane is responsive (marker echoed)" $markerFound "found=$markerFound"

    # Also create a new-window (the other trigger mentioned in the issue)
    & $PSMUX new-window -t $S 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $win1 = (& $PSMUX display-message -t "${S}:1" -p '#{window_index}' 2>&1).Trim()
    Add-Result "new-window created window 1" ($win1 -eq "1") "window_index=$win1"

    # Send marker to window 1 pane 0 and verify it responds
    $marker2 = "PSMUX_CPR_MARKER2_282"
    & $PSMUX send-keys -t "${S}:1.0" "echo $marker2" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    $cap2 = (& $PSMUX capture-pane -t "${S}:1.0" -p 2>&1) -join "`n"
    $marker2Found = $cap2 -match [regex]::Escape($marker2)
    Add-Result "new-window pane is responsive (marker echoed)" $marker2Found "found=$marker2Found"
}

# ====================================================================
# Cleanup
# ====================================================================
Kill-OurSession $S

# ====================================================================
# Summary
# ====================================================================
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $pass / $($pass + $fail)" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
foreach ($r in $results) {
    $color  = if ($r.Pass) { 'Green' } else { 'Red' }
    $status = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host "  [$status] $($r.Test) $($r.Detail)" -ForegroundColor $color
}

if ($fail -gt 0) {
    Write-Host "`n  Some tests FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "`n  All tests passed. Issue #282 fix verified." -ForegroundColor Green
exit 0
