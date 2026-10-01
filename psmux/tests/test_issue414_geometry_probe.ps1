# Issue #414: deterministic geometry probe (NO rendering capture).
# In tmux, `pane-border-status top` reserves the TOP row of each pane for the
# title border, so pane geometry changes: the top pane's content shifts down
# (pane_top increases) and pane_height shrinks by 1. If psmux geometry does NOT
# change when the option flips, the border-status line is not laid out at all.
# Also probe every format variable that would expose a per-pane border title.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "issue414_geo"
$psmuxDir = "$env:USERPROFILE\.psmux"
function Cleanup { & $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 400; Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue }

Cleanup
& $PSMUX new-session -d -s $S -x 120 -y 40 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX split-window -v -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 600

function Dump-Geo($label) {
    Write-Host "`n--- $label ---" -ForegroundColor Yellow
    $g = & $PSMUX list-panes -t $S -F '#{pane_index} top=#{pane_top} height=#{pane_height} title=#{pane_title}' 2>&1
    $g | ForEach-Object { Write-Host "  $_" }
    return $g
}

# Baseline: border-status off (tmux default)
& $PSMUX set-option -g pane-border-status off 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$off = Dump-Geo "pane-border-status OFF"

# Enable top
& $PSMUX set-option -g pane-border-status top 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$top = Dump-Geo "pane-border-status TOP"

# Parse pane0 geometry both ways
function Parse($lines, $idx) {
    $l = $lines | Where-Object { $_ -match "^$idx top=" } | Select-Object -First 1
    if ($l -match "top=(\d+) height=(\d+)") { return @{ top=[int]$Matches[1]; height=[int]$Matches[2] } }
    return $null
}
$o0 = Parse $off 0; $t0 = Parse $top 0
$o1 = Parse $off 1; $t1 = Parse $top 1

Write-Host "`n=== GEOMETRY DELTA ===" -ForegroundColor Cyan
Write-Host ("pane0  OFF top={0} h={1}   TOP top={2} h={3}" -f $o0.top,$o0.height,$t0.top,$t0.height)
Write-Host ("pane1  OFF top={0} h={1}   TOP top={2} h={3}" -f $o1.top,$o1.height,$t1.top,$t1.height)

$changed = ($o0.top -ne $t0.top) -or ($o0.height -ne $t0.height) -or ($o1.top -ne $t1.top) -or ($o1.height -ne $t1.height)
if ($changed) {
    Write-Host "`n[RESULT] geometry CHANGED when enabling border-status => layout reserves a border row (feature at least laid out)" -ForegroundColor Green
} else {
    Write-Host "`n[RESULT] geometry IDENTICAL => border-status top does NOT reserve a border row => title border NOT rendered (BUG)" -ForegroundColor Red
}

# Also: is there any format var exposing the option per-pane / border string?
Write-Host "`n=== format-var probe ===" -ForegroundColor Cyan
foreach ($v in @('#{pane-border-status}','#{pane_border_status}','#{?pane_active,active,inactive}')) {
    $r = (& $PSMUX display-message -t $S -p $v 2>&1 | Out-String).Trim()
    Write-Host ("  {0,-28} => '{1}'" -f $v, $r)
}

Cleanup
