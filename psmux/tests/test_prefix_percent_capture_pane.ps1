# Capture via capture-pane (renders status bar) to see the flash error text.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"

& $PSMUX kill-session -t rA 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\rA.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","rA" -PassThru
Start-Sleep -Seconds 4

# Build up to 4 panes
for ($i = 1; $i -le 3; $i++) {
    & $injector $proc.Id "^b{SLEEP:250}%" 2>&1 | Out-Null
    Start-Sleep -Seconds 1
}
Write-Host "Setup panes:"
& $PSMUX list-panes -t rA -F '#{pane_index} active=#{pane_active} W=#{pane_width} H=#{pane_height}' 2>&1

# Send the failing prefix+% then POLL capture-pane fast
& $injector $proc.Id "^b{SLEEP:250}%" 2>&1 | Out-Null

$captures = @()
for ($k=0; $k -lt 30; $k++) {
    Start-Sleep -Milliseconds 25
    $cap = & $PSMUX capture-pane -t rA -p 2>&1 | Out-String
    # last 3 lines (status bar area)
    $lines = $cap -split "`n"
    $tail = ($lines | Select-Object -Last 3) -join "|"
    if ($tail.Trim()) { $captures += "{0}ms: $tail" -f ($k*25) }
}
Write-Host "panes after: $((& $PSMUX list-panes -t rA 2>&1 | Measure-Object -Line).Lines)"
Write-Host "Captured tails (uniq):"
$captures | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }

# Try full screen capture once for context
Write-Host "`nFull pane (last 5 lines):"
(& $PSMUX capture-pane -t rA -p 2>&1 | Out-String) -split "`n" | Select-Object -Last 5

& $PSMUX kill-session -t rA 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
