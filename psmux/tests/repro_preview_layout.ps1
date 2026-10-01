# Repro for "preview does not replicate the real window"
# Creates two sessions with multiple windows + splits, runs a long-lived
# program (Get-Process loop simulating pstop) in one pane, then dumps
# both the REAL layout (list-panes) and the PREVIEW layout (window-dump)
# side-by-side so we can see EXACTLY which sizes/positions differ.

$ErrorActionPreference = 'Stop'
function Send-Tcp([string]$sess, [string]$cmd) {
    $port = (Get-Content "$env:USERPROFILE\.psmux\$sess.port" -Raw).Trim()
    $key  = (Get-Content "$env:USERPROFILE\.psmux\$sess.key"  -Raw).Trim()
    $cli = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$port)
    $st = $cli.GetStream()
    $w = New-Object System.IO.StreamWriter($st); $w.AutoFlush = $true
    $w.WriteLine("AUTH $key"); $w.WriteLine($cmd)
    Start-Sleep -Milliseconds 400
    $buf = New-Object byte[] 131072
    $n = $st.Read($buf, 0, $buf.Length)
    $cli.Close()
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
}

# ---------- SESSION ALPHA: 2 windows ----------
psmux new-session -d -s alpha -x 200 -y 50 | Out-Null
# Window 1: 3 panes - left full, right split top/bottom
psmux split-window -h -t 'alpha:@1' | Out-Null
psmux split-window -v -t 'alpha:@1.%2' | Out-Null
psmux send-keys -t 'alpha:@1.%1' "echo ALPHA_W1_LEFT_AAA" Enter
psmux send-keys -t 'alpha:@1.%2' "echo ALPHA_W1_TOPRIGHT_BBB" Enter
psmux send-keys -t 'alpha:@1.%3' "while(`$true){Get-Process | Sort-Object CPU -desc | Select -First 8 | Format-Table Id,Name,CPU; Start-Sleep 1; Clear-Host}" Enter

# Window 2: 4 panes in 2x2 grid
psmux new-window -t alpha | Out-Null
psmux split-window -h -t 'alpha:@2' | Out-Null
psmux split-window -v -t 'alpha:@2.%4' | Out-Null
psmux split-window -v -t 'alpha:@2.%5' | Out-Null
psmux send-keys -t 'alpha:@2.%4' "echo W2_TL" Enter
psmux send-keys -t 'alpha:@2.%5' "echo W2_TR" Enter
psmux send-keys -t 'alpha:@2.%6' "echo W2_BL" Enter
psmux send-keys -t 'alpha:@2.%7' "echo W2_BR" Enter

# ---------- SESSION BETA ----------
psmux new-session -d -s beta -x 180 -y 45 | Out-Null
psmux split-window -v -t 'beta:@3' | Out-Null
psmux send-keys -t 'beta:@3.%8' "echo BETA_TOP" Enter
psmux send-keys -t 'beta:@3.%9' "echo BETA_BOT" Enter

Start-Sleep -Seconds 2

Write-Host "==== SESSION alpha WINDOW @1 (3 panes: left full, right top/bottom) ====" -ForegroundColor Cyan
Write-Host "REAL list-panes:"
psmux list-panes -t 'alpha:@1' -F '  %#{pane_id} #{pane_width}x#{pane_height} @ (#{pane_left},#{pane_top})  active=#{pane_active}'
Write-Host "PREVIEW window-dump (from TCP, sizes only):"
$dump1 = Send-Tcp 'alpha' 'window-dump 1'
$dump1 | Out-File -Encoding utf8 target\repro_alpha_w1.json
$json1 = ($dump1 -split "`n" | Where-Object { $_.StartsWith('{') } | Select-Object -First 1)
if ($json1) {
    $obj = $json1 | ConvertFrom-Json
    function Show-Tree($n, $depth) {
        $ind = '  ' * $depth
        if ($n.type -eq 'split') {
            Write-Host "$ind split kind=$($n.kind) sizes=[$($n.sizes -join ',')] children=$($n.children.Count)"
            foreach ($c in $n.children) { Show-Tree $c ($depth+1) }
        } else {
            Write-Host "$ind leaf %$($n.id) cols=$($n.cols) rows=$($n.rows) active=$($n.active) rows_v2_count=$($n.rows_v2.Count)"
        }
    }
    Show-Tree $obj 1
}

Write-Host ""
Write-Host "==== SESSION alpha WINDOW @2 (4 panes 2x2) ====" -ForegroundColor Cyan
Write-Host "REAL list-panes:"
psmux list-panes -t 'alpha:@2' -F '  %#{pane_id} #{pane_width}x#{pane_height} @ (#{pane_left},#{pane_top})  active=#{pane_active}'
Write-Host "PREVIEW window-dump:"
$dump2 = Send-Tcp 'alpha' 'window-dump 2'
$dump2 | Out-File -Encoding utf8 target\repro_alpha_w2.json
$json2 = ($dump2 -split "`n" | Where-Object { $_.StartsWith('{') } | Select-Object -First 1)
if ($json2) { Show-Tree ($json2 | ConvertFrom-Json) 1 }

Write-Host ""
Write-Host "==== SESSION beta WINDOW @3 (2 panes top/bottom) ====" -ForegroundColor Cyan
Write-Host "REAL list-panes:"
psmux list-panes -t 'beta:@3' -F '  %#{pane_id} #{pane_width}x#{pane_height} @ (#{pane_left},#{pane_top})  active=#{pane_active}'
Write-Host "PREVIEW window-dump:"
$dump3 = Send-Tcp 'beta' 'window-dump 3'
$dump3 | Out-File -Encoding utf8 target\repro_beta_w3.json
$json3 = ($dump3 -split "`n" | Where-Object { $_.StartsWith('{') } | Select-Object -First 1)
if ($json3) { Show-Tree ($json3 | ConvertFrom-Json) 1 }
