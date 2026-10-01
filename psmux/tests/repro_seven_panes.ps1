# Hard repro: 7 panes in one window, verify window-dump returns 7 leaves
$ErrorActionPreference = 'Stop'

Get-Process | Where-Object { $_.ProcessName -in @('psmux','pmux','tmux') } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Item "$env:USERPROFILE\.psmux\*.port","$env:USERPROFILE\.psmux\*.key" -Force -ErrorAction SilentlyContinue

function Send-Tcp([string]$sess, [string]$cmd) {
    $port = (Get-Content "$env:USERPROFILE\.psmux\$sess.port" -Raw).Trim()
    $key  = (Get-Content "$env:USERPROFILE\.psmux\$sess.key"  -Raw).Trim()
    $cli = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$port)
    $st = $cli.GetStream()
    $w = New-Object System.IO.StreamWriter($st); $w.AutoFlush = $true
    $w.WriteLine("AUTH $key"); $w.WriteLine($cmd)
    Start-Sleep -Milliseconds 600
    $buf = New-Object byte[] 524288
    $total = 0
    while ($st.DataAvailable -or $total -eq 0) {
        if (-not $st.DataAvailable -and $total -gt 0) { break }
        $n = $st.Read($buf, $total, $buf.Length - $total)
        if ($n -le 0) { break }
        $total += $n
        Start-Sleep -Milliseconds 100
    }
    $cli.Close()
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $total)
}

psmux new-session -d -s seven -x 240 -y 60 | Out-Null
# First split horizontally (left|right)
psmux split-window -h -t 'seven:@1.%1' | Out-Null
# Right column: split vertically 3 times to get 4 panes top to bottom
psmux split-window -v -t 'seven:@1.%2' | Out-Null
psmux split-window -v -t 'seven:@1.%3' | Out-Null
psmux split-window -v -t 'seven:@1.%4' | Out-Null
# Left column: split twice vertically (3 panes top to bottom)
psmux split-window -v -t 'seven:@1.%1' | Out-Null
psmux split-window -v -t 'seven:@1.%6' | Out-Null
Start-Sleep -Milliseconds 800

Write-Host "=== REAL list-panes ===" -ForegroundColor Cyan
psmux list-panes -t 'seven:@1' -F '%#{pane_id} #{pane_width}x#{pane_height} @ (#{pane_left},#{pane_top}) active=#{pane_active}'

Write-Host "`n=== window-dump (preview source) ===" -ForegroundColor Cyan
$resp = Send-Tcp 'seven' 'window-dump 1'
$json = ($resp -split "`n" | Where-Object { $_.StartsWith('{') } | Select-Object -First 1)
if (-not $json) { Write-Host "NO JSON. Raw response:" -ForegroundColor Red; $resp; exit 1 }
$obj = $json | ConvertFrom-Json

$leaves = New-Object System.Collections.ArrayList
function Walk($n) {
    if ($n.type -eq 'leaf') { [void]$leaves.Add($n) }
    else { foreach ($c in $n.children) { Walk $c } }
}
Walk $obj

Write-Host "Leaves found in dump: $($leaves.Count)"
foreach ($l in $leaves) { Write-Host "  %$($l.id) cols=$($l.cols) rows=$($l.rows) active=$($l.active) rows_v2=$($l.rows_v2.Count)" }

if ($leaves.Count -ne 7) {
    Write-Host "`n[FAIL] Expected 7 panes in dump, got $($leaves.Count)" -ForegroundColor Red
    exit 1
}

# Compare: every pane id in list-panes must appear in dump
$realIds = (psmux list-panes -t 'seven:@1' -F '#{pane_id}') -replace '%','' | Sort-Object {[int]$_}
$dumpIds = ($leaves | ForEach-Object { $_.id }) | Sort-Object
Write-Host "`nReal IDs:  $($realIds -join ',')"
Write-Host "Dump IDs:  $($dumpIds -join ',')"
if (("$realIds" -ne "$dumpIds")) {
    Write-Host "[FAIL] IDs do not match" -ForegroundColor Red; exit 1
}
Write-Host "`n[PASS] All 7 panes present in dump with matching IDs" -ForegroundColor Green
