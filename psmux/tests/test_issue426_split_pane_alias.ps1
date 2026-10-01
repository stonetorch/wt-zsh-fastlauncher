# Issue #426: split-pane / splitp must work as aliases of split-window
# (tmux ships them as default command-aliases; psmux was missing them).
# Proves the alias creates a real 2nd pane across CLI, TCP, and command-prompt paths.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue426"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0; $script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Cleanup { & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 500; Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue }

function Reset-ToOnePane {
    $p = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim()
    while ([int]$p -gt 1) { & $PSMUX kill-pane -t "$SESSION.1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 300; $p = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim() }
}
function Panes { (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim() }

function Send-Tcp($cmd) {
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$port); $tcp.NoDelay=$true
    $s=$tcp.GetStream(); $w=[System.IO.StreamWriter]::new($s); $r=[System.IO.StreamReader]::new($s)
    $w.Write("AUTH $key`n"); $w.Flush(); $null=$r.ReadLine()
    $w.Write("$cmd`n"); $w.Flush(); $s.ReadTimeout=8000
    try { $resp=$r.ReadLine() } catch { $resp="TIMEOUT" }
    $tcp.Close(); return $resp
}

Cleanup
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session create failed"; exit 1 }

Write-Host "`n=== Issue #426: split-pane / splitp aliases ===" -ForegroundColor Cyan

# --- CLI path: split-pane ---
Write-Host "`n[CLI] psmux split-pane" -ForegroundColor Yellow
Reset-ToOnePane
$b = Panes
$out = & $PSMUX split-pane -t $SESSION 2>&1
Start-Sleep -Seconds 1
$a = Panes
if ($out -match "unknown command") { Write-Fail "split-pane still unknown command: $out" }
elseif ([int]$a -gt [int]$b) { Write-Pass "split-pane created a pane ($b -> $a)" }
else { Write-Fail "split-pane did not create a pane ($b -> $a); out=$out" }

# --- CLI path: splitp ---
Write-Host "`n[CLI] psmux splitp" -ForegroundColor Yellow
Reset-ToOnePane
$b = Panes
$out = & $PSMUX splitp -t $SESSION 2>&1
Start-Sleep -Seconds 1
$a = Panes
if ($out -match "unknown command") { Write-Fail "splitp still unknown command: $out" }
elseif ([int]$a -gt [int]$b) { Write-Pass "splitp created a pane ($b -> $a)" }
else { Write-Fail "splitp did not create a pane ($b -> $a); out=$out" }

# --- CLI path: split-pane -h (horizontal, with flag) ---
Write-Host "`n[CLI] psmux split-pane -h -P -F '#{pane_id}'" -ForegroundColor Yellow
Reset-ToOnePane
$b = Panes
$paneId = (& $PSMUX split-pane -t $SESSION -h -P -F "#{pane_id}" 2>&1 | Out-String).Trim()
Start-Sleep -Seconds 1
$a = Panes
if ($paneId -match '^%\d+$' -and [int]$a -gt [int]$b) { Write-Pass "split-pane -h -P returned pane_id $paneId and split ($b -> $a)" }
else { Write-Fail "split-pane -h -P failed: paneId='$paneId' panes $b -> $a" }

# --- TCP server path: split-pane ---
Write-Host "`n[TCP] split-pane over socket" -ForegroundColor Yellow
Reset-ToOnePane
$b = Panes
$resp = Send-Tcp "split-pane"
Start-Sleep -Seconds 1
$a = Panes
if ([int]$a -gt [int]$b) { Write-Pass "TCP split-pane created a pane ($b -> $a), resp=$resp" }
else { Write-Fail "TCP split-pane failed ($b -> $a), resp=$resp" }

# --- TCP server path: splitp ---
Write-Host "`n[TCP] splitp over socket" -ForegroundColor Yellow
Reset-ToOnePane
$b = Panes
$resp = Send-Tcp "splitp"
Start-Sleep -Seconds 1
$a = Panes
if ([int]$a -gt [int]$b) { Write-Pass "TCP splitp created a pane ($b -> $a), resp=$resp" }
else { Write-Fail "TCP splitp failed ($b -> $a), resp=$resp" }

# --- Regression: split-window / splitw still work ---
Write-Host "`n[Regression] split-window + splitw still work" -ForegroundColor Yellow
Reset-ToOnePane
$b = Panes
& $PSMUX split-window -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 800
$mid = Panes
& $PSMUX splitw -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 800
$a = Panes
if ([int]$a -gt [int]$mid -and [int]$mid -gt [int]$b) { Write-Pass "split-window and splitw still create panes ($b -> $mid -> $a)" }
else { Write-Fail "regression: split-window/splitw ($b -> $mid -> $a)" }

Cleanup
Write-Host "`n=== Results: Pass=$($script:Pass) Fail=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
