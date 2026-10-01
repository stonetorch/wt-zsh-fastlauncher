#!/usr/bin/env pwsh
# Empirical test: pstop running in a split pane, compare REAL vs PREVIEW rendering.
$ErrorActionPreference = 'Continue'
$psmux = "$env:USERPROFILE\.cargo\bin\psmux.exe"
$home_dir = $env:USERPROFILE
$out = "target\preview_compare\pstop"
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Send-Tcp([string]$sess, [string]$cmd) {
    $portFile = Join-Path $home_dir ".psmux\$sess.port"
    $keyFile  = Join-Path $home_dir ".psmux\$sess.key"
    if (-not (Test-Path $portFile)) { return $null }
    $port = (Get-Content $portFile).Trim()
    $key  = (Get-Content $keyFile).Trim()
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$port)
        $tcp.ReceiveTimeout = 5000
        $stream = $tcp.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream); $writer.NewLine = "`n"; $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($stream)
        $writer.WriteLine("AUTH $key") | Out-Null
        $reader.ReadLine() | Out-Null
        $writer.WriteLine($cmd)
        $sb = New-Object System.Text.StringBuilder
        $start = Get-Date
        while (((Get-Date) - $start).TotalMilliseconds -lt 3000) {
            if ($stream.DataAvailable) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                [void]$sb.AppendLine($line)
                if ($line.StartsWith('OK') -or $line.StartsWith('ERR') -or $line -eq 'END') { break }
            } else { Start-Sleep -Milliseconds 50 }
        }
        $tcp.Close()
        return $sb.ToString()
    } catch { return $null }
}

# Kill any existing
Get-Process psmux,pmux,tmux -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$sess = 'pstop'
Write-Host "Starting session $sess (240x60)..." -ForegroundColor Cyan
& $psmux new-session -d -s $sess -x 240 -y 60 | Out-Null
Start-Sleep -Milliseconds 800

# Build a 4-pane layout: vertical split at top (large), then horizontal split below for two small panes
# Pane 1: the big top pane where pstop will run
# Then split-window -v for pane 2 (medium below)
# Then split-window -h on pane 2 for pane 3
& $psmux split-window -t "${sess}:0" -v | Out-Null
Start-Sleep -Milliseconds 300
& $psmux split-window -t "${sess}:0" -h | Out-Null
Start-Sleep -Milliseconds 300
& $psmux select-pane -t "${sess}:0.0" | Out-Null
Start-Sleep -Milliseconds 300

# List panes
Write-Host "`nPanes:" -ForegroundColor Yellow
$panes = & $psmux list-panes -t "${sess}:0" -F '#{pane_id} #{pane_width}x#{pane_height} @(#{pane_left},#{pane_top}) active=#{pane_active}'
$panes | ForEach-Object { Write-Host "  $_" }

# Send pstop into pane 0 (the big one)
Write-Host "`nSending pstop into pane 0..." -ForegroundColor Cyan
& $psmux send-keys -t "${sess}:0.0" "pstop" Enter | Out-Null
# Send some marker text to other panes
& $psmux send-keys -t "${sess}:0.1" "echo PANE_1_HERE" Enter | Out-Null
& $psmux send-keys -t "${sess}:0.2" "echo PANE_2_HERE" Enter | Out-Null

# Let pstop initialize and render a frame
Start-Sleep -Seconds 4

# Capture REAL rendering of each pane
Write-Host "`nCapturing real pane content..." -ForegroundColor Cyan
foreach ($p in @(0,1,2)) {
    $r = Send-Tcp $sess "capture-pane -t ${sess}:0.$p -p -e"
    if ($r) {
        $r | Out-File -Encoding utf8 (Join-Path $out "real_pane${p}.ansi")
        $lines = ($r -split "`r?`n").Count
        Write-Host "  pane ${p}: captured ($lines lines)"
    }
}

# Get the layout dump
Write-Host "`nFetching window-dump..." -ForegroundColor Cyan
$dump = Send-Tcp $sess "window-dump 1"
if ($dump) {
    # Strip OK/END envelope
    $jsonOnly = ($dump -split "`r?`n" | Where-Object { $_ -ne 'OK' -and $_ -ne 'END' -and $_ -ne '' }) -join "`n"
    $jsonOnly | Out-File -Encoding utf8 (Join-Path $out "dump.json")
    Write-Host "  dump saved ($(([System.IO.FileInfo](Join-Path $out 'dump.json')).Length) bytes)"
}

# Render preview at multiple sizes
Write-Host "`nRendering previews..." -ForegroundColor Cyan
foreach ($sz in @(@{w=240;h=60}, @{w=120;h=30}, @{w=80;h=20}, @{w=60;h=16})) {
    $w = $sz.w; $h = $sz.h
    $rendered = & $psmux _render-preview $sess 1 $w $h 2>&1
    $rendered | Out-File -Encoding utf8 (Join-Path $out "preview_${w}x${h}.ansi")
    Write-Host "  preview ${w}x${h}: $(([System.IO.FileInfo](Join-Path $out "preview_${w}x${h}.ansi")).Length) bytes"
}

# Summary diff: the big pane region of preview vs real pane 0
Write-Host "`n=== Visual sample of REAL pane 0 (pstop) ===" -ForegroundColor Magenta
$realBytes = [System.IO.File]::ReadAllBytes((Join-Path $out 'real_pane0.ansi'))
$real = [System.Text.Encoding]::UTF8.GetString($realBytes)
$realRows = $real -split "`r?`n"
for ($i=0; $i -lt [Math]::Min(15, $realRows.Count); $i++) {
    $plain = [regex]::Replace($realRows[$i], '\x1b\[[0-9;]*[a-zA-Z]', '')
    if ($plain.Length -gt 120) { $plain = $plain.Substring(0,120) }
    "  $plain"
}

Write-Host "`n=== Visual sample of PREVIEW 240x60 (top region = pane 0 = pstop) ===" -ForegroundColor Magenta
$prevBytes = [System.IO.File]::ReadAllBytes((Join-Path $out 'preview_240x60.ansi'))
$prev = [System.Text.Encoding]::UTF8.GetString($prevBytes)
$prevRows = $prev -split "`r?`n"
for ($i=0; $i -lt [Math]::Min(20, $prevRows.Count); $i++) {
    $plain = [regex]::Replace($prevRows[$i], '\x1b\[[0-9;]*[a-zA-Z]', '')
    if ($plain.Length -gt 240) { $plain = $plain.Substring(0,240) }
    "  $plain"
}

Write-Host "`nDone. Files in $out" -ForegroundColor Green
Get-ChildItem $out | Format-Table Name, Length

# Cleanup
& $psmux kill-server 2>$null | Out-Null
