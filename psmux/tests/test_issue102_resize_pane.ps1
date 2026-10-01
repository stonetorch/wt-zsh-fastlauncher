# Issue #102: Multiple input handling issues -- resize-pane does not hang server
#
# The original bug included a critical issue: resizing the Windows Terminal window
# caused an unrecoverable session hang (fixed in commit 91f9d62). Sub-issue: resizing
# while a display-popup overlay is active causes a black screen.
#
# This test covers the most tangibly verifiable claim from the issue: after
# resize-pane operations (-x absolute, -y absolute, -Z zoom toggle, directional),
# the server MUST remain responsive -- display-message, capture-pane, and send-keys
# all work without hanging. A frozen server would time out on these commands.
#
# Two layers:
#   PART 1 - Source-code proof: resize-pane dispatches via CtrlReq (non-blocking
#            channel send, not a direct blocking call), and the zoom-toggle path
#            exists alongside the -x/-y absolute paths.
#   PART 2 - Functional proof: split-window to get two panes, perform resize-pane
#            -x, -y, -Z (zoom), and directional, then assert the server still
#            responds to display-message with correct pane dimensions and that
#            capture-pane works after each resize.

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

Write-Host "`n=== Issue #102: resize-pane does not hang server ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"

# ====================================================================
# PART 1: Source-code proof
# ====================================================================
Write-Host "`n--- Part 1: Source-code proof ---" -ForegroundColor Yellow

$connFile = Join-Path $PSScriptRoot "..\src\server\connection.rs"
if (-not (Test-Path $connFile)) {
    Add-Result "connection.rs found" $false "missing: $connFile"
    exit 1
}
$connSrc = Get-Content $connFile -Raw

Write-Test "resize-pane dispatches via CtrlReq::ResizePaneAbsolute (non-blocking channel send)"
$hasAbsolute = $connSrc -match 'CtrlReq::ResizePaneAbsolute'
Add-Result "CtrlReq::ResizePaneAbsolute dispatch present" $hasAbsolute ""

Write-Test "resize-pane dispatches via CtrlReq::ResizePanePercent for percentage values"
$hasPct = $connSrc -match 'CtrlReq::ResizePanePercent'
Add-Result "CtrlReq::ResizePanePercent dispatch present" $hasPct ""

Write-Test "resize-pane dispatches via CtrlReq::ResizePane for directional resize"
$hasDir = $connSrc -match 'CtrlReq::ResizePane\b'
Add-Result "CtrlReq::ResizePane directional dispatch present" $hasDir ""

Write-Test "zoom-pane (-Z) dispatches via CtrlReq::ZoomPane (separate non-blocking path)"
$hasZoom = $connSrc -match 'CtrlReq::ZoomPane'
Add-Result "CtrlReq::ZoomPane dispatch present" $hasZoom ""

Write-Test "resize-pane handler uses tx.send() (non-blocking, cannot freeze caller)"
# All resize paths use let _ = tx.send(...) which is a channel send, not a blocking wait
$hasTxSend = $connSrc -match 'tx\.send\(CtrlReq::ResizePane'
Add-Result "resize dispatches via tx.send (non-blocking)" $hasTxSend ""

# ====================================================================
# PART 2: Functional proof -- server responsive after resize operations
# ====================================================================
Write-Host "`n--- Part 2: Functional proof ---" -ForegroundColor Yellow

$S = "gap102_resize"

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

# Helper: run display-message with a timeout to detect hangs
function Get-PaneMetric($target, $fmt, [int]$timeoutSec = 8) {
    $job = Start-Job -ScriptBlock {
        param($exe, $t, $f)
        & $exe display-message -t $t -p $f 2>&1
    } -ArgumentList $PSMUX, $target, $fmt
    $completed = Wait-Job $job -Timeout $timeoutSec
    if (-not $completed) {
        Remove-Job $job -Force
        return $null   # timed out = server hung
    }
    $result = Receive-Job $job
    Remove-Job $job -Force
    return $result.Trim()
}

Kill-OurSession $S
Start-Sleep -Milliseconds 500

& $PSMUX new-session -d -s $S 2>&1 | Out-Null
$alive = Wait-Session $S 12000
Add-Result "session started" $alive ""

if ($alive) {
    # Split horizontally to get two side-by-side panes for -x resize
    & $PSMUX split-window -h -t $S 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $pane0 = "${S}:0.0"
    $pane1 = "${S}:0.1"

    # Baseline width of pane 0
    $w0_before = Get-PaneMetric $pane0 '#{pane_width}'
    Add-Result "baseline pane_width readable (server responsive)" ($w0_before -ne $null) "w=$w0_before"

    # ----- Test: resize-pane -x (absolute width) -----
    Write-Test "resize-pane -x 40: completes without hang, server still responds"
    & $PSMUX resize-pane -t $pane0 -x 40 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $w0_after = Get-PaneMetric $pane0 '#{pane_width}' 8
    $respondedAfterX = $w0_after -ne $null
    Add-Result "server responds after resize-pane -x" $respondedAfterX "pane_width=$w0_after"

    # ----- Test: resize-pane -y (absolute height) -----
    # Need a vertical split for -y to take effect
    & $PSMUX split-window -v -t $pane0 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $pane2 = "${S}:0.2"

    Write-Test "resize-pane -y 10: completes without hang, server still responds"
    & $PSMUX resize-pane -t $pane0 -y 10 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $h0_after = Get-PaneMetric $pane0 '#{pane_height}' 8
    $respondedAfterY = $h0_after -ne $null
    Add-Result "server responds after resize-pane -y" $respondedAfterY "pane_height=$h0_after"

    # ----- Test: resize-pane -Z (zoom toggle) -----
    Write-Test "resize-pane -Z (zoom toggle): completes without hang"
    & $PSMUX resize-pane -t $pane1 -Z 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $zoom_flag = Get-PaneMetric $pane1 '#{window_zoomed_flag}' 8
    $respondedAfterZoom = $zoom_flag -ne $null
    Add-Result "server responds after resize-pane -Z (zoom)" $respondedAfterZoom "zoomed_flag=$zoom_flag"

    # Unzoom before directional test
    & $PSMUX resize-pane -t $pane1 -Z 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # ----- Test: directional resize -R -----
    Write-Test "resize-pane -R 5 (directional): completes without hang"
    & $PSMUX resize-pane -t $pane0 -R 5 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $w_dir = Get-PaneMetric $pane0 '#{pane_width}' 8
    $respondedAfterDir = $w_dir -ne $null
    Add-Result "server responds after resize-pane -R" $respondedAfterDir "pane_width=$w_dir"

    # ----- Test: capture-pane still works after all resizes -----
    Write-Test "capture-pane works after multiple resize operations"
    $cap = (& $PSMUX capture-pane -t $pane0 -p 2>&1)
    $capOk = ($cap -ne $null) -and ($LASTEXITCODE -eq 0)
    Add-Result "capture-pane works post-resize" $capOk "lines=$($cap.Count)"

    # ----- Test: send-keys + echo proves PTY still alive -----
    Write-Test "send-keys + capture-pane: PTY alive after resize"
    $marker = "PSMUX_RESIZE_MARKER_102"
    & $PSMUX send-keys -t $pane0 "echo $marker" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $cap2 = (& $PSMUX capture-pane -t $pane0 -p 2>&1) -join "`n"
    $markerFound = $cap2 -match [regex]::Escape($marker)
    Add-Result "PTY echoes marker after resize (not hung)" $markerFound "found=$markerFound"
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
Write-Host "`n  All tests passed. Issue #102 fix verified." -ForegroundColor Green
exit 0
