#!/usr/bin/env pwsh
# test_issue336_zoom_cursor_origin.ps1
# Issue #336: Cursor origin not reset when zooming non-first pane
# Fix: zooming a NON-first pane resets cursor to pane-local coords,
# not offset by the pane's prior absolute column/row in the layout.

$ErrorActionPreference = 'Continue'
$PSMUX   = (Get-Command psmux -EA Stop).Source
$SESSION = "gap336"
$psmuxDir = "$env:USERPROFILE\.psmux"

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Step($n,$msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Get-DumpJson {
    $portFile = "$psmuxDir\$SESSION.port"
    $keyFile  = "$psmuxDir\$SESSION.key"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $portFile) -and $sw.ElapsedMilliseconds -lt 12000) {
        Start-Sleep -Milliseconds 300
    }
    if (-not (Test-Path $portFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 10000
    $s = $tcp.GetStream()
    $w = [System.IO.StreamWriter]::new($s)
    $r = [System.IO.StreamReader]::new($s)
    $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
    $w.Write("PERSISTENT`n"); $w.Flush()
    $w.Write("dump-state`n"); $w.Flush()
    $best = $null; $tcp.ReceiveTimeout = 3000
    for ($i = 0; $i -lt 80; $i++) {
        try { $line = $r.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line.Length -gt 100) { $best = $line }
        if ($best) { $tcp.ReceiveTimeout = 300 }
    }
    $tcp.Close()
    if ($best) { return $best | ConvertFrom-Json }
    return $null
}

# Walk layout tree iteratively, return all leaf nodes as array
function Get-LayoutLeaves($rootNode) {
    $leaves = [System.Collections.Generic.List[object]]::new()
    $stack  = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push($rootNode)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($n.type -eq "leaf") {
            $leaves.Add($n)
        } elseif ($n.children) {
            foreach ($c in $n.children) { $stack.Push($c) }
        }
    }
    return @($leaves)
}

# === SETUP ===
Cleanup
Write-Host "`n=== Issue #336: Cursor origin reset when zooming non-first pane ===" -ForegroundColor Cyan
Start-Process -FilePath $PSMUX -ArgumentList "new-session","-d","-s",$SESSION -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Session creation failed" -ForegroundColor Red; exit 1 }

# Horizontal split -> pane 0 (left), pane 1 (right)
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$paneCount = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($paneCount -ne "2") { Write-Host "ERROR: Need 2 panes, got $paneCount" -ForegroundColor Red; Cleanup; exit 1 }

$dumpPre   = Get-DumpJson
$leavesPre = Get-LayoutLeaves $dumpPre.layout
# Sort by id to get pane0 and pane1 consistently
$sorted    = $leavesPre | Sort-Object { [int]$_.id }
$cols0Pre  = [int]$sorted[0].cols
$cols1Pre  = [int]$sorted[1].cols
# Pane 1's absolute col offset = pane0.cols + 1 (border)
$pane1Offset = $cols0Pre + 1
Write-Host "  Pre-zoom: pane0.cols=$cols0Pre  pane1.cols=$cols1Pre  pane1-abs-col-offset=$pane1Offset" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Test 1: Zoom FIRST pane (pane 0) -- control: cursor_col stays within pane0 bounds
# ---------------------------------------------------------------------------
Write-Step 1 "Control: zoom FIRST pane (pane 0), cursor_col within original pane0 bounds"
$t0 = $SESSION + ":.0"
& $PSMUX select-pane -t $t0 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX resize-pane -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$dumpZ0   = Get-DumpJson
$leavesZ0 = Get-LayoutLeaves $dumpZ0.layout
# Zoomed pane is the one with most cols
$zL0 = $leavesZ0 | Sort-Object { [int]$_.cols } | Select-Object -Last 1
Write-Host "  Zoomed pane0: cols=$($zL0.cols) cursor_col=$($zL0.cursor_col) cursor_row=$($zL0.cursor_row)" -ForegroundColor DarkGray

if ([int]$zL0.cursor_col -le ($cols0Pre + 5)) {
    Write-Pass "Pane 0 zoomed: cursor_col=$($zL0.cursor_col) within original pane0 width $cols0Pre (control OK)"
} else {
    Write-Fail "Pane 0 zoomed: cursor_col=$($zL0.cursor_col) unexpectedly large (expected <= $($cols0Pre+5))"
}

& $PSMUX resize-pane -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 600

# ---------------------------------------------------------------------------
# Test 2: Zoom NON-FIRST pane (pane 1) -- cursor_col must NOT carry abs offset
# ---------------------------------------------------------------------------
Write-Step 2 "Zoom NON-FIRST pane (pane 1): cursor_col must be < pane1-abs-offset=$pane1Offset"
$t1 = $SESSION + ":.1"
& $PSMUX select-pane -t $t1 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX resize-pane -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$flagZ1 = (& $PSMUX display-message -t $SESSION -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
if ($flagZ1 -ne "1") {
    Write-Fail "window_zoomed_flag=$flagZ1 (zoom did not activate)"
    Cleanup; exit $script:TestsFailed
}

$dumpZ1   = Get-DumpJson
$leavesZ1 = Get-LayoutLeaves $dumpZ1.layout
$zL1      = $leavesZ1 | Sort-Object { [int]$_.cols } | Select-Object -Last 1
$cursorCol1 = [int]$zL1.cursor_col
$cursorRow1 = [int]$zL1.cursor_row
Write-Host "  Zoomed pane1: cols=$($zL1.cols) cursor_col=$cursorCol1 cursor_row=$cursorRow1" -ForegroundColor DarkGray

# THE KEY ASSERTION:
# BUG: cursor_col was >= pane1Offset (carried absolute X offset ~110)
# FIX: cursor_col is pane-local (< pane1Offset ~110)
if ($cursorCol1 -lt $pane1Offset) {
    Write-Pass "BUG #336 FIXED: cursor_col=$cursorCol1 < abs-offset=$pane1Offset (pane-local origin reset)"
} else {
    Write-Fail "BUG #336 PRESENT: cursor_col=$cursorCol1 >= abs-offset=$pane1Offset (absolute offset carried)"
}

if ($cursorRow1 -ge 0 -and $cursorRow1 -lt [int]$zL1.rows) {
    Write-Pass "cursor_row=$cursorRow1 within zoomed rows=$($zL1.rows)"
} else {
    Write-Fail "cursor_row=$cursorRow1 out of range (zoomed rows=$($zL1.rows))"
}

& $PSMUX resize-pane -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 600

# ---------------------------------------------------------------------------
# Test 3: Vertical split -- zoom bottom pane, cursor_row must not carry row offset
# ---------------------------------------------------------------------------
Write-Step 3 "Vertical split: zoom bottom pane (pane 1), cursor_row must not carry pane0.rows offset"
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$dumpVPre   = Get-DumpJson
$leavesVPre = Get-LayoutLeaves $dumpVPre.layout
$vSorted    = $leavesVPre | Sort-Object { [int]$_.id }
$rows0Pre   = [int]$vSorted[0].rows
$rowOffset  = $rows0Pre + 1
Write-Host "  Vertical pre-zoom: pane0.rows=$rows0Pre  row-offset=$rowOffset" -ForegroundColor DarkGray

$vt1 = $SESSION + ":.1"
& $PSMUX select-pane -t $vt1 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX resize-pane -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$dumpVZ   = Get-DumpJson
$leavesVZ = Get-LayoutLeaves $dumpVZ.layout
$zLV      = $leavesVZ | Sort-Object { [int]$_.rows } | Select-Object -Last 1
$vCursorRow = [int]$zLV.cursor_row
Write-Host "  Vertical zoom: zoomed.rows=$($zLV.rows) cursor_row=$vCursorRow row-offset=$rowOffset" -ForegroundColor DarkGray

if ($vCursorRow -lt $rowOffset) {
    Write-Pass "Vertical zoom BUG #336 FIXED: cursor_row=$vCursorRow < row-offset=$rowOffset (row origin reset)"
} else {
    Write-Fail "Vertical zoom BUG #336 PRESENT: cursor_row=$vCursorRow >= row-offset=$rowOffset (row origin NOT reset)"
}

# === TEARDOWN ===
Cleanup
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
if ($script:TestsFailed -eq 0) {
    Write-Host "`n  VERDICT: Issue #336 FIXED. Cursor origin correctly reset to pane-local coords on zoom." -ForegroundColor Green
} else {
    Write-Host "`n  VERDICT: VERIFIED_BROKEN - cursor origin not reset when zooming non-first pane." -ForegroundColor Red
}
exit $script:TestsFailed
