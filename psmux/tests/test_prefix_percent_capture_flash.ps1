# Capture the prefix+% flash error with high-frequency polling
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"

& $PSMUX kill-session -t rA 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\rA.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","rA" -PassThru
Start-Sleep -Seconds 4

$port = (Get-Content "$psmuxDir\rA.port" -Raw).Trim()
$key = (Get-Content "$psmuxDir\rA.key" -Raw).Trim()
$tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
$tcp.NoDelay=$true
$s = $tcp.GetStream()
$w = [System.IO.StreamWriter]::new($s)
$r = [System.IO.StreamReader]::new($s)
$w.Write("AUTH $key`n"); $w.Flush(); $null=$r.ReadLine()
$w.Write("PERSISTENT`n"); $w.Flush()

function FastDump {
    $script:w.Write("dump-state`n"); $script:w.Flush()
    $best=$null
    $script:tcp.ReceiveTimeout = 200
    for ($j=0; $j -lt 30; $j++) {
        try { $line=$script:r.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best=$line }
        if ($best) { $script:tcp.ReceiveTimeout = 20 }
    }
    return $best
}
function PaneCount { (& $PSMUX list-panes -t rA 2>&1 | Measure-Object -Line).Lines }

# Build up to 4 panes via prefix+%
for ($i = 1; $i -le 3; $i++) {
    & $injector $proc.Id "^b{SLEEP:250}%" 2>&1 | Out-Null
    Start-Sleep -Seconds 1
}
Write-Host "panes built: $(PaneCount)"
& $PSMUX list-panes -t rA -F '#{pane_index} W=#{pane_width} H=#{pane_height}' 2>&1

# Now try the failing split and POLL fast for status_message
& $injector $proc.Id "^b{SLEEP:250}%" 2>&1 | Out-Null
$messages = @()
for ($k=0; $k -lt 25; $k++) {
    Start-Sleep -Milliseconds 30
    $d = FastDump
    if ($d) {
        try {
            $j = $d | ConvertFrom-Json
            $msg = $j.status_message
            if ($msg) { $messages += "$($k*30)ms: $msg" }
        } catch {}
    }
}
Write-Host "after-final-pane count: $(PaneCount)"
Write-Host "captured messages:"
$messages | ForEach-Object { Write-Host "  $_" }

$tcp.Close()
& $PSMUX kill-session -t rA 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
