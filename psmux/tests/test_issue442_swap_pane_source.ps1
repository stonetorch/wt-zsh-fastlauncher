# Issue #442: swap-pane -s X -t Y must swap the two named panes (honor -s), not
# swap the active pane with -t. E2E over CLI + TCP paths, plus live TUI window.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function New-Row {
    param([string]$Session, [int]$Extra = 3)
    & $PSMUX kill-session -t $Session 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$Session.*" -Force -EA SilentlyContinue
    & $PSMUX new-session -d -s $Session
    Start-Sleep -Seconds 3
    for ($i = 0; $i -lt $Extra; $i++) { & $PSMUX split-window -h -t $Session 2>&1 | Out-Null; Start-Sleep -Milliseconds 400 }
}
function IdAt($S, $i) { foreach($l in (& $PSMUX list-panes -t $S -F '#{pane_index}=#{pane_id}')){ if($l -match "^$i=(.+)$"){return $Matches[1]} } ; return "" }
function ActiveIdx($S) { foreach($l in (& $PSMUX list-panes -t $S -F '#{pane_index}:#{pane_active}')){ if($l -match '^(\d+):1$'){return [int]$Matches[1]} } ; return -1 }
function ActiveId($S) { foreach($l in (& $PSMUX list-panes -t $S -F '#{pane_id}:#{pane_active}')){ if($l -match '^(.+):1$'){return $Matches[1]} } ; return "" }
function Send-Tcp { param([string]$S, [string]$Cmd)
    $port = (Get-Content "$psmuxDir\$S.port" -Raw).Trim(); $key = (Get-Content "$psmuxDir\$S.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $tcp.NoDelay = $true
    $st = $tcp.GetStream(); $w = [System.IO.StreamWriter]::new($st); $r = [System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n"); $w.Flush(); if ($r.ReadLine() -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $w.Write("$Cmd`n"); $w.Flush(); $st.ReadTimeout = 10000
    try { $resp = $r.ReadLine() } catch { $resp = "TIMEOUT" }; $tcp.Close(); return $resp
}

Write-Host "`n=== Issue #442: swap-pane -s (source) Tests ===" -ForegroundColor Cyan

# === TEST 1: The exact bug - swap -s idx0 -t idx3, active is idx1 (CLI, by pane id) ===
Write-Host "`n[Test 1] swap-pane -s <id0> -t <id3>, active=idx1 (CLI, pane ids)" -ForegroundColor Yellow
$S = "test_issue442_a"; New-Row -Session $S -Extra 3
& $PSMUX select-pane -t "${S}.1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
$id0 = IdAt $S 0; $id1 = IdAt $S 1; $id3 = IdAt $S 3
& $PSMUX swap-pane -s $id0 -t $id3 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
if ((IdAt $S 0) -eq $id3 -and (IdAt $S 3) -eq $id0) { Write-Pass "the two NAMED panes (idx0,idx3) swapped" }
else { Write-Fail "named panes did not swap: idx0=$(IdAt $S 0) idx3=$(IdAt $S 3) (wanted idx0=$id3 idx3=$id0)" }
if ((IdAt $S 1) -eq $id1) { Write-Pass "idx1 (the previously active pane) is untouched" }
else { Write-Fail "BUG: active pane got swapped, idx1=$(IdAt $S 1) expected $id1" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 2: index targets (.0 / .3) via CLI ===
Write-Host "`n[Test 2] swap-pane -s .0 -t .3 (CLI, indices)" -ForegroundColor Yellow
$S = "test_issue442_b"; New-Row -Session $S -Extra 3
& $PSMUX select-pane -t "${S}.1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
$id0 = IdAt $S 0; $id3 = IdAt $S 3
& $PSMUX swap-pane -s "${S}.0" -t "${S}.3" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
if ((IdAt $S 0) -eq $id3 -and (IdAt $S 3) -eq $id0) { Write-Pass "index targets swapped idx0<->idx3" }
else { Write-Fail "index swap failed: idx0=$(IdAt $S 0) idx3=$(IdAt $S 3)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 3: without -d, the -t pane becomes active (tmux parity) ===
Write-Host "`n[Test 3] without -d, active follows the -t pane" -ForegroundColor Yellow
$S = "test_issue442_c"; New-Row -Session $S -Extra 3
& $PSMUX select-pane -t "${S}.1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
$id3 = IdAt $S 3
& $PSMUX swap-pane -s "${S}.0" -t "${S}.3" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
if ((ActiveId $S) -eq $id3) { Write-Pass "active is the -t pane ($id3)" }
else { Write-Fail "active expected -t pane $id3, got $(ActiveId $S)" }
if ((ActiveIdx $S) -eq 0) { Write-Pass "-t pane now sits in the src slot (idx0) and is active" }
else { Write-Fail "active index expected 0, got $(ActiveIdx $S)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 4: with -d, the active pane is unchanged ===
Write-Host "`n[Test 4] with -d, active pane unchanged" -ForegroundColor Yellow
$S = "test_issue442_d"; New-Row -Session $S -Extra 3
& $PSMUX select-pane -t "${S}.1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
$id1 = IdAt $S 1; $id0 = IdAt $S 0; $id3 = IdAt $S 3
& $PSMUX swap-pane -d -s "${S}.0" -t "${S}.3" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
if ((IdAt $S 0) -eq $id3 -and (IdAt $S 3) -eq $id0) { Write-Pass "-d still swaps the named panes" }
else { Write-Fail "-d did not swap: idx0=$(IdAt $S 0) idx3=$(IdAt $S 3)" }
if ((ActiveId $S) -eq $id1 -and (ActiveIdx $S) -eq 1) { Write-Pass "-d kept focus on the original active pane ($id1 at idx1)" }
else { Write-Fail "-d changed active: got id=$(ActiveId $S) idx=$(ActiveIdx $S), expected $id1 at idx1" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 5: TCP server path ===
Write-Host "`n[Test 5] TCP server path: swap-pane -s .0 -t .3" -ForegroundColor Yellow
$S = "test_issue442_tcp"; New-Row -Session $S -Extra 3
& $PSMUX select-pane -t "${S}.1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
$id0 = IdAt $S 0; $id1 = IdAt $S 1; $id3 = IdAt $S 3
$resp = Send-Tcp -S $S -Cmd "swap-pane -s ${S}.0 -t ${S}.3"
Start-Sleep -Milliseconds 400
if ((IdAt $S 0) -eq $id3 -and (IdAt $S 3) -eq $id0 -and (IdAt $S 1) -eq $id1) { Write-Pass "TCP path swapped named panes, active pane untouched (resp: '$resp')" }
else { Write-Fail "TCP path wrong: idx0=$(IdAt $S 0) idx1=$(IdAt $S 1) idx3=$(IdAt $S 3)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 6: -t only (no -s) still swaps active with target (unchanged path) ===
Write-Host "`n[Test 6] regression: swap-pane -t .2 (no -s) swaps active<->target" -ForegroundColor Yellow
$S = "test_issue442_e"; New-Row -Session $S -Extra 3
& $PSMUX select-pane -t "${S}.0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
$id0 = IdAt $S 0; $id2 = IdAt $S 2
& $PSMUX swap-pane -t "${S}.2" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
if ((IdAt $S 0) -eq $id2 -and (IdAt $S 2) -eq $id0) { Write-Pass "-t only still swaps active(idx0)<->target(idx2)" }
else { Write-Fail "-t only regressed: idx0=$(IdAt $S 0) idx2=$(IdAt $S 2)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === TEST 7: directional -U (no -s/-t) still index-ordered (regression w/ #400) ===
Write-Host "`n[Test 7] regression: swap-pane -U still works" -ForegroundColor Yellow
$S = "test_issue442_f"; New-Row -Session $S -Extra 3
& $PSMUX select-pane -t "${S}.1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
$id0 = IdAt $S 0; $id1 = IdAt $S 1
& $PSMUX swap-pane -U -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
if ((IdAt $S 0) -eq $id1 -and (IdAt $S 1) -eq $id0) { Write-Pass "-U still swaps prev-by-index" }
else { Write-Fail "-U regressed: idx0=$(IdAt $S 0) idx1=$(IdAt $S 1)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# === Win32 TUI VISUAL VERIFICATION ===
Write-Host ("`n" + ("=" * 60)) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
$STUI = "test_issue442_tui"
& $PSMUX kill-session -t $STUI 2>&1 | Out-Null
Remove-Item "$psmuxDir\$STUI.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$STUI -PassThru
Start-Sleep -Seconds 4
& $PSMUX split-window -h -t $STUI 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX split-window -h -t $STUI 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX split-window -h -t $STUI 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX select-pane -t "${STUI}.1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
$panes = (& $PSMUX display-message -t $STUI -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "4") { Write-Pass "TUI: 4 panes present" } else { Write-Fail "TUI: expected 4 panes, got $panes" }
$id0 = IdAt $STUI 0; $id1 = IdAt $STUI 1; $id3 = IdAt $STUI 3
& $PSMUX swap-pane -s "${STUI}.0" -t "${STUI}.3" 2>&1 | Out-Null; Start-Sleep -Milliseconds 500
if ((IdAt $STUI 0) -eq $id3 -and (IdAt $STUI 3) -eq $id0 -and (IdAt $STUI 1) -eq $id1) { Write-Pass "TUI: -s/-t swapped named panes on a live window, active untouched" }
else { Write-Fail "TUI: swap wrong on live window" }
& $PSMUX kill-session -t $STUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
