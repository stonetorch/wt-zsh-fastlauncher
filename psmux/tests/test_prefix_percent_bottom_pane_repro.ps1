# Repro: in a vertically-split window, focus the bottom pane and send prefix+%
# (split-window -h via keybinding). The user reports a brief error flash and no
# split. We capture status_message via dump-state to read the flash.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "repro_pct"
$pass = 0; $fail = 0
function P($m) { Write-Host "[PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; $script:fail++ }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$injector = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injector)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injector tests\injector.cs 2>&1 | Out-Null
}

Write-Host "=== Repro prefix+% in bottom pane ===" -ForegroundColor Cyan
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4

# Wait for session ready
$portFile = "$psmuxDir\$SESSION.port"
for ($i = 0; $i -lt 40; $i++) {
    if (Test-Path $portFile) { break }
    Start-Sleep -Milliseconds 250
}
if (-not (Test-Path $portFile)) { F "session never ready"; exit 1 }
$port = (Get-Content $portFile -Raw).Trim()
$key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
P "session ready on port $port"

# Persistent TCP for dump-state polling
function Connect-P {
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $w = [System.IO.StreamWriter]::new($stream)
    $r = [System.IO.StreamReader]::new($stream)
    $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
    $w.Write("PERSISTENT`n"); $w.Flush()
    return @{tcp=$tcp; w=$w; r=$r}
}
function Dump($c) {
    $c.w.Write("dump-state`n"); $c.w.Flush()
    $best = $null
    $c.tcp.ReceiveTimeout = 800
    for ($j = 0; $j -lt 50; $j++) {
        try { $line = $c.r.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line }
        if ($best) { $c.tcp.ReceiveTimeout = 30 }
    }
    $c.tcp.ReceiveTimeout = 5000
    return $best
}

# Step 1: Setup — split vertically (prefix+") so we have top + bottom panes,
# then focus the bottom pane (prefix + Down).
& $injector $proc.Id "^b{SLEEP:300}`"" 2>&1 | Out-Null
Start-Sleep -Seconds 1
$panes = (& $PSMUX list-panes -t $SESSION 2>&1 | Measure-Object -Line).Lines
if ($panes -ge 2) { P "setup: got $panes panes after prefix+`"" } else { F "setup: only $panes panes" }

# Active pane should be the bottom (index 1) by default in psmux after split
$active = (& $PSMUX display-message -t $SESSION -p '#{pane_index}' 2>&1).Trim()
Write-Host "active pane index after split: $active"

# Step 2: Capture state BEFORE % keystroke
$conn = Connect-P
$before = Dump $conn
$bjson = $before | ConvertFrom-Json
$panesBefore = $bjson.layout.panes.Count
Write-Host "panes before %: $panesBefore"

# Step 3: Send prefix + % to the bottom pane (active)
& $injector $proc.Id "^b{SLEEP:300}%" 2>&1 | Out-Null
# Capture state quickly while flash is still visible
Start-Sleep -Milliseconds 100
$flash1 = Dump $conn
Start-Sleep -Milliseconds 200
$flash2 = Dump $conn
$flash1json = $flash1 | ConvertFrom-Json
$flash2json = $flash2 | ConvertFrom-Json

Write-Host "status_message t+100ms: $($flash1json.status_message)"
Write-Host "status_message t+300ms: $($flash2json.status_message)"
Write-Host "panes t+300ms: $($flash2json.layout.panes.Count)"

# Final pane check
Start-Sleep -Seconds 1
$panesAfter = (& $PSMUX list-panes -t $SESSION 2>&1 | Measure-Object -Line).Lines
Write-Host "panes after settle: $panesAfter"

if ($panesAfter -gt $panesBefore) {
    P "split-window via prefix+% added a pane"
} else {
    F "BUG REPRODUCED: prefix+% did not split. panes before=$panesBefore after=$panesAfter"
    Write-Host "  Flash error: $($flash1json.status_message)" -ForegroundColor Yellow
    Write-Host "  Flash error (later): $($flash2json.status_message)" -ForegroundColor Yellow
}

$conn.tcp.Close()

# Cleanup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`nPassed=$pass Failed=$fail"
exit $fail
