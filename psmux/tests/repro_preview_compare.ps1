# Empirical REAL vs PREVIEW rendering comparison.
# Builds windows with 7, 15, 20 panes (and an htop/tasklist loop in big panes),
# captures the REAL pane contents, then renders the PREVIEW at multiple sizes
# via 'psmux _render-preview' and writes everything to target\preview_compare\.
# Reports leaves missing from the rendered preview.

$ErrorActionPreference = 'Stop'
Get-Process | Where-Object { $_.ProcessName -in @('psmux','pmux','tmux') } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Item "$env:USERPROFILE\.psmux\*.port","$env:USERPROFILE\.psmux\*.key" -Force -ErrorAction SilentlyContinue
$out = "target\preview_compare"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null

function Send-Tcp([string]$sess, [string]$cmd) {
    $port = (Get-Content "$env:USERPROFILE\.psmux\$sess.port" -Raw).Trim()
    $key  = (Get-Content "$env:USERPROFILE\.psmux\$sess.key"  -Raw).Trim()
    $cli = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$port)
    $st = $cli.GetStream()
    $w = New-Object System.IO.StreamWriter($st); $w.AutoFlush = $true
    $w.WriteLine("AUTH $key"); $w.WriteLine($cmd)
    Start-Sleep -Milliseconds 600
    $buf = New-Object byte[] 1048576
    $total = 0
    while ($true) {
        if ($st.DataAvailable) {
            $n = $st.Read($buf, $total, $buf.Length - $total)
            if ($n -le 0) { break }
            $total += $n
            Start-Sleep -Milliseconds 80
        } elseif ($total -gt 0) { break }
        else { Start-Sleep -Milliseconds 100 }
    }
    $cli.Close()
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $total)
}

function Build-Layout([string]$sess, [int]$nPanes, [int]$winW, [int]$winH) {
    psmux new-session -d -s $sess -x $winW -y $winH | Out-Null
    # Build by repeatedly splitting the last pane in alternating directions.
    for ($i = 1; $i -lt $nPanes; $i++) {
        $dir = if ($i % 3 -eq 0) { '-h' } else { '-v' }
        # Find first pane that's still tall/wide enough to split
        $panes = (psmux list-panes -t "${sess}:@1" -F '#{pane_id} #{pane_width} #{pane_height}') -split "`n"
        $target = $null
        foreach ($p in $panes) {
            if (-not $p) { continue }
            $parts = $p -split ' '
            $pid_p = $parts[0]; $pw = [int]$parts[1]; $ph = [int]$parts[2]
            if ($dir -eq '-v' -and $ph -ge 6) { $target = $pid_p; break }
            if ($dir -eq '-h' -and $pw -ge 10) { $target = $pid_p; break }
        }
        if (-not $target) {
            # Try other direction
            $dir = if ($dir -eq '-v') { '-h' } else { '-v' }
            foreach ($p in $panes) {
                if (-not $p) { continue }
                $parts = $p -split ' '
                $pid_p = $parts[0]; $pw = [int]$parts[1]; $ph = [int]$parts[2]
                if ($dir -eq '-v' -and $ph -ge 6) { $target = $pid_p; break }
                if ($dir -eq '-h' -and $pw -ge 10) { $target = $pid_p; break }
            }
        }
        if (-not $target) { Write-Host "Stopped at $i panes (no splittable pane)" -ForegroundColor Yellow; break }
        psmux split-window $dir -t "${sess}:@1.$target" 2>$null | Out-Null
    }
}

function Compare-Layout([string]$sess, [int]$nPanes, [int]$winW, [int]$winH) {
    Write-Host "`n========== $sess (target $nPanes panes, real ${winW}x${winH}) ==========" -ForegroundColor Cyan
    Build-Layout $sess $nPanes $winW $winH
    Start-Sleep -Milliseconds 600
    # Tag the largest pane with a long-running command
    $panes = (psmux list-panes -t "${sess}:@1" -F '#{pane_id} #{pane_width} #{pane_height}') -split "`n" | Where-Object { $_ }
    $bigPane = $panes | Sort-Object { $parts = $_ -split ' '; -([int]$parts[1] * [int]$parts[2]) } | Select-Object -First 1
    $bigPaneId = ($bigPane -split ' ')[0]
    psmux send-keys -t "${sess}:@1.$bigPaneId" "Get-Process | Sort-Object CPU -desc | Select-Object -First 20 | Format-Table Id,Name,CPU" Enter
    # Tag every pane with its id so we can verify it appears in the preview
    foreach ($p in $panes) {
        $pid_p = ($p -split ' ')[0]
        psmux send-keys -t "${sess}:@1.$pid_p" "echo PANEMARK_${pid_p}_HERE" Enter 2>$null | Out-Null
    }
    Start-Sleep -Milliseconds 1200

    Write-Host "Real pane count: $($panes.Count)"
    psmux list-panes -t "${sess}:@1" -F '  %#{pane_id} #{pane_width}x#{pane_height} @ (#{pane_left},#{pane_top}) active=#{pane_active}'

    # Save real captures (one ANSI file per pane)
    foreach ($p in $panes) {
        $pid_p = ($p -split ' ')[0]
        $cap = psmux capture-pane -e -p -t "${sess}:@1.$pid_p"
        $cap | Out-File -Encoding utf8 "$out\${sess}_real_$($pid_p -replace '%','').ansi"
    }

    # Save the dump JSON
    $dump = Send-Tcp $sess 'window-dump 1'
    $json = ($dump -split "`n" | Where-Object { $_.StartsWith('{') } | Select-Object -First 1)
    $json | Out-File -Encoding utf8 "$out\${sess}_dump.json"

    # Count leaves in dump
    $obj = $json | ConvertFrom-Json
    $leafIds = New-Object System.Collections.ArrayList
    function Walk($n) { if ($n.type -eq 'leaf') { [void]$leafIds.Add($n.id) } else { foreach ($c in $n.children) { Walk $c } } }
    Walk $obj
    Write-Host "Dump leaves: $($leafIds.Count) -> [$($leafIds -join ',')]"

    # Render preview at multiple sizes and check which markers are visible
    foreach ($sz in @(@(120,30), @(80,20), @(60,16), @(40,12))) {
        $pw = $sz[0]; $ph = $sz[1]
        $f = "$out\${sess}_preview_${pw}x${ph}.ansi"
        & psmux _render-preview $sess 1 $pw $ph 2>&1 | Out-File -Encoding utf8 $f
        $content = Get-Content $f -Raw
        # Strip ANSI for counting
        $plain = [System.Text.RegularExpressions.Regex]::Replace($content, '\x1b\[[0-9;]*[a-zA-Z]', '')
        $missing = @()
        foreach ($lid in $leafIds) {
            if ($plain -notmatch "PANEMARK_%${lid}_HERE") { $missing += $lid }
        }
        $sepCount = ([regex]::Matches($plain, '[│─]')).Count
        Write-Host ("  preview {0,3}x{1,2}: {2} separator chars, {3}/{4} leaves rendered missing=[{5}]" -f $pw,$ph,$sepCount,($leafIds.Count - $missing.Count),$leafIds.Count,($missing -join ','))
    }
}

Compare-Layout 's7'  7  240 60
Compare-Layout 's15' 15 240 60
Compare-Layout 's20' 20 240 60

Write-Host "`nFiles in ${out}:" -ForegroundColor Yellow
Get-ChildItem $out | Format-Table Name, Length -AutoSize
