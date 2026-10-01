# Regression proof: prefix+% (split-window -h) must surface a status_message
# when the active pane is too narrow to split. Previously the error from
# split_active_with_command was sent only as the TCP response and was
# silently dropped by the client (briefly visible as a 1/5-second flash that
# the user could not read). Fix: server/mod.rs SplitWindow handler now sets
# app.status_message so the next dump-state delivers it to the status bar.
#
# Reproduction: keep splitting horizontally until pane width drops below
# MIN_SPLIT_COLS * 2 + 1 = 21. The next prefix+% must:
#   1. NOT increase pane count (split is rejected)
#   2. Populate status_message with text containing "pane too small"

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injector)) { Write-Host "[SKIP] injector missing at $injector"; exit 0 }
$pass = 0; $fail = 0
function P($m) { Write-Host "[PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; $script:fail++ }

$name = "rProof"
& $PSMUX kill-session -t $name 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$name -PassThru
Start-Sleep -Seconds 4

$port = (Get-Content "$psmuxDir\$name.port" -Raw).Trim()
$key  = (Get-Content "$psmuxDir\$name.key" -Raw).Trim()
$tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
$tcp.NoDelay = $true; $tcp.ReceiveTimeout = 3000
$s = $tcp.GetStream()
$w = [System.IO.StreamWriter]::new($s)
$r = [System.IO.StreamReader]::new($s)
$w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
$w.Write("PERSISTENT`n"); $w.Flush()

function Dump {
    $w.Write("dump-state`n"); $w.Flush()
    $best = $null
    $tcp.ReceiveTimeout = 600
    for ($j = 0; $j -lt 50; $j++) {
        try { $line = $r.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line }
        if ($best) { $tcp.ReceiveTimeout = 30 }
    }
    $tcp.ReceiveTimeout = 3000
    return $best
}
function PaneCount { (& $PSMUX list-panes -t $name 2>&1 | Measure-Object -Line).Lines }

# Squeeze panes until the last split is rejected.
$failed_iter = -1
$failed_msg = ""
$failed_before = -1
$failed_after = -1
for ($i = 1; $i -le 8; $i++) {
    $before = PaneCount
    & $injector $proc.Id "^b{SLEEP:250}%" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 250
    $dump = Dump
    $msg = ""
    if ($dump) { try { $msg = ($dump | ConvertFrom-Json).status_message } catch { $msg = "" } }
    Start-Sleep -Milliseconds 500
    $after = PaneCount
    Write-Host ("  iter {0}: before={1} after={2} msg='{3}'" -f $i, $before, $after, $msg)
    if ($after -le $before) {
        $failed_iter = $i
        $failed_msg = $msg
        $failed_before = $before
        $failed_after = $after
        break
    }
}

if ($failed_iter -lt 0) {
    F "expected a rejected split within 8 iterations, none observed"
} else {
    P "split was rejected at iter $failed_iter (panes stayed at $failed_after, was $failed_before)"
    if ($failed_msg -and $failed_msg -match "pane too small") {
        P "status_message surfaced to client: $failed_msg"
    } else {
        F "status_message not populated (got '$failed_msg') -- regression of silent prefix+% bug"
    }
}

$tcp.Close()
& $PSMUX kill-session -t $name 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`nPassed=$pass Failed=$fail"
if ($fail -gt 0) { exit 1 }
