# Issue #400: swap-pane -U / -D must swap by pane INDEX order (tmux parity), not geometry.
# Backbone E2E proof: real panes, CLI path + TCP server path + edge cases.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function New-Row {
    param([string]$Session, [int]$Extra = 3, [string]$SplitFlag = "-h")
    & $PSMUX kill-session -t $Session 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$Session.*" -Force -EA SilentlyContinue
    & $PSMUX new-session -d -s $Session
    Start-Sleep -Seconds 3
    for ($i = 0; $i -lt $Extra; $i++) {
        & $PSMUX split-window $SplitFlag -t $Session 2>&1 | Out-Null
        Start-Sleep -Milliseconds 400
    }
}
function Map($Session) { (& $PSMUX list-panes -t $Session -F '#{pane_index}=#{pane_id}' 2>&1) -join ' ' }
function ActiveIdx($Session) {
    foreach ($l in (& $PSMUX list-panes -t $Session -F '#{pane_index}:#{pane_active}' 2>&1)) {
        if ($l -match '^(\d+):1$') { return [int]$Matches[1] }
    }
    return -1
}
function IdAt($Session, $idx) {
    foreach ($l in (& $PSMUX list-panes -t $Session -F '#{pane_index}=#{pane_id}' 2>&1)) {
        if ($l -match "^$idx=(.+)$") { return $Matches[1] }
    }
    return ""
}
function Send-Tcp {
    param([string]$Session, [string]$Command)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    if ($reader.ReadLine() -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 10000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

Write-Host "`n=== Issue #400: swap-pane index-order Tests ===" -ForegroundColor Cyan

# === TEST 1: The exact reported scenario - horizontal row, swap-pane -U (CLI path) ===
Write-Host "`n[Test 1] Horizontal row 0|1|2|3, pane 1 active, swap-pane -U (CLI)" -ForegroundColor Yellow
$S = "test_issue400_a"
New-Row -Session $S -Extra 3 -SplitFlag "-h"
& $PSMUX select-pane -t "${S}.1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$id0 = IdAt $S 0; $id1 = IdAt $S 1
& $PSMUX swap-pane -U -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
if ((IdAt $S 0) -eq $id1 -and (IdAt $S 1) -eq $id0) { Write-Pass "idx0<->idx1 swapped by index (prev), not a no-op" }
else { Write-Fail "expected idx0=$id1 idx1=$id0, got idx0=$(IdAt $S 0) idx1=$(IdAt $S 1)" }
if ((ActiveIdx $S) -eq 0) { Write-Pass "focus followed the moved pane to idx0" }
else { Write-Fail "focus expected idx0, got idx$(ActiveIdx $S)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 2: Horizontal row, swap-pane -D swaps with next by index (CLI) ===
Write-Host "`n[Test 2] Horizontal row, pane 1 active, swap-pane -D (CLI)" -ForegroundColor Yellow
$S = "test_issue400_b"
New-Row -Session $S -Extra 3 -SplitFlag "-h"
& $PSMUX select-pane -t "${S}.1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$id1 = IdAt $S 1; $id2 = IdAt $S 2
& $PSMUX swap-pane -D -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
if ((IdAt $S 1) -eq $id2 -and (IdAt $S 2) -eq $id1) { Write-Pass "idx1<->idx2 swapped by index (next)" }
else { Write-Fail "expected idx1=$id2 idx2=$id1, got idx1=$(IdAt $S 1) idx2=$(IdAt $S 2)" }
if ((ActiveIdx $S) -eq 2) { Write-Pass "focus followed to idx2" }
else { Write-Fail "focus expected idx2, got idx$(ActiveIdx $S)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 3: Wrap -U at first pane goes to last (CLI) ===
Write-Host "`n[Test 3] Wrap: pane 0 active, swap-pane -U wraps to last (CLI)" -ForegroundColor Yellow
$S = "test_issue400_c"
New-Row -Session $S -Extra 3 -SplitFlag "-h"
& $PSMUX select-pane -t "${S}.0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$id0 = IdAt $S 0; $id3 = IdAt $S 3
& $PSMUX swap-pane -U -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
if ((IdAt $S 0) -eq $id3 -and (IdAt $S 3) -eq $id0) { Write-Pass "idx0<->idx3 wrapped (prev of first = last)" }
else { Write-Fail "expected idx0=$id3 idx3=$id0, got idx0=$(IdAt $S 0) idx3=$(IdAt $S 3)" }
if ((ActiveIdx $S) -eq 3) { Write-Pass "focus followed to idx3 (wrapped)" }
else { Write-Fail "focus expected idx3, got idx$(ActiveIdx $S)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 4: Wrap -D at last pane goes to first (CLI) ===
Write-Host "`n[Test 4] Wrap: last pane active, swap-pane -D wraps to first (CLI)" -ForegroundColor Yellow
$S = "test_issue400_d"
New-Row -Session $S -Extra 3 -SplitFlag "-h"
& $PSMUX select-pane -t "${S}.3" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$id0 = IdAt $S 0; $id3 = IdAt $S 3
& $PSMUX swap-pane -D -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
if ((IdAt $S 3) -eq $id0 -and (IdAt $S 0) -eq $id3) { Write-Pass "idx3<->idx0 wrapped (next of last = first)" }
else { Write-Fail "expected idx3=$id0 idx0=$id3, got idx3=$(IdAt $S 3) idx0=$(IdAt $S 0)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 5: TCP server path swap-pane -U ===
Write-Host "`n[Test 5] TCP server path: swap-pane -U" -ForegroundColor Yellow
$S = "test_issue400_tcp"
New-Row -Session $S -Extra 3 -SplitFlag "-h"
& $PSMUX select-pane -t "${S}.2" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$id1 = IdAt $S 1; $id2 = IdAt $S 2
$resp = Send-Tcp -Session $S -Command "swap-pane -U"
Start-Sleep -Milliseconds 400
if ((IdAt $S 1) -eq $id2 -and (IdAt $S 2) -eq $id1) { Write-Pass "TCP swap-pane -U swapped idx1<->idx2 (resp: $resp)" }
else { Write-Fail "TCP path did not swap: idx1=$(IdAt $S 1) idx2=$(IdAt $S 2) resp=$resp" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 6: Vertical stack still correct (regression: aligned layout keeps working) ===
Write-Host "`n[Test 6] Vertical stack, pane 1 active, swap-pane -U" -ForegroundColor Yellow
$S = "test_issue400_v"
New-Row -Session $S -Extra 2 -SplitFlag "-v"
& $PSMUX select-pane -t "${S}.1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$id0 = IdAt $S 0; $id1 = IdAt $S 1
& $PSMUX swap-pane -U -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
if ((IdAt $S 0) -eq $id1 -and (IdAt $S 1) -eq $id0) { Write-Pass "vertical idx0<->idx1 swapped" }
else { Write-Fail "vertical expected idx0=$id1 idx1=$id0, got idx0=$(IdAt $S 0) idx1=$(IdAt $S 1)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 7: Explicit -t swap (active <-> target) unaffected by the -U/-D change ===
# This path is swap_pane_with_path(), which the #400 fix does NOT touch.
# NOTE: `swap-pane -s X -t Y` currently ignores -s and swaps Y with the active
# pane; that is a SEPARATE pre-existing quirk, out of scope for #400 (-U/-D).
# Here we verify the supported `swap-pane -t <target>` form (swap active with
# target) still works, as a regression guard for the fix.
Write-Host "`n[Test 7] Explicit swap-pane -t <target> (active <-> target) intact" -ForegroundColor Yellow
$S = "test_issue400_e"
New-Row -Session $S -Extra 3 -SplitFlag "-h"
& $PSMUX select-pane -t "${S}.0" 2>&1 | Out-Null   # active = idx0
Start-Sleep -Milliseconds 300
$id0 = IdAt $S 0; $id2 = IdAt $S 2
& $PSMUX swap-pane -t "${S}.2" 2>&1 | Out-Null       # swap active(idx0) with idx2
Start-Sleep -Milliseconds 400
if ((IdAt $S 0) -eq $id2 -and (IdAt $S 2) -eq $id0) { Write-Pass "explicit -t swap (active<->target) intact" }
else { Write-Fail "explicit swap broke: idx0=$(IdAt $S 0) idx2=$(IdAt $S 2) (expected idx0=$id2 idx2=$id0)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === Win32 TUI VISUAL VERIFICATION (Layer 2) ===
Write-Host ("`n" + ("=" * 60)) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
$STUI = "test_issue400_tui"
& $PSMUX kill-session -t $STUI 2>&1 | Out-Null
Remove-Item "$psmuxDir\$STUI.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$STUI -PassThru
Start-Sleep -Seconds 4
& $PSMUX split-window -h -t $STUI 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX split-window -h -t $STUI 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX select-pane -t "${STUI}.1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
$panes = (& $PSMUX display-message -t $STUI -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "3") { Write-Pass "TUI: 3 panes present" } else { Write-Fail "TUI: expected 3 panes, got $panes" }
$id0 = IdAt $STUI 0; $id1 = IdAt $STUI 1
& $PSMUX swap-pane -U -t $STUI 2>&1 | Out-Null; Start-Sleep -Milliseconds 500
if ((IdAt $STUI 0) -eq $id1 -and (IdAt $STUI 1) -eq $id0) { Write-Pass "TUI: swap-pane -U swapped on a live visible window" }
else { Write-Fail "TUI: swap did not take on live window" }
& $PSMUX kill-session -t $STUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
