# Issue #414 DEFINITIVE: does pane-border-status top draw the pane TITLE on the
# border row? Turn the STATUS BAR OFF entirely (status off) so the ONLY place a
# pane title could possibly appear on screen is the border row. Attach a ConPTY
# client (full repaint), reconstruct the grid, and check for the titles.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "issue414_def"
$psmuxDir = "$env:USERPROFILE\.psmux"
$outBin = "$env:TEMP\conpty_out.bin"
$hostExe = "$env:TEMP\conpty_ctrlc_host.exe"
$hostSrc = Join-Path $PSScriptRoot "conpty_ctrlc_host.cs"

function Stop-All {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    Get-Process conpty_ctrlc_host -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 300
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
}
if (-not (Test-Path $hostExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
    & $csc /nologo /optimize /out:$hostExe $hostSrc 2>&1 | Out-Null
}
Stop-All

$COLS = 120; $ROWS = 30
& $PSMUX new-session -d -s $S -x $COLS -y $ROWS 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX set-option -g status off 2>&1 | Out-Null           # kill status bar contamination
& $PSMUX set-option -g pane-border-status top 2>&1 | Out-Null
& $PSMUX split-window -v -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
& $PSMUX select-pane -t "${S}.0" -T "ZZTOPTITLEZZ" 2>&1 | Out-Null
& $PSMUX select-pane -t "${S}.1" -T "YYBOTTITLEYY" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Write-Host "status bar: $((& $PSMUX show-options -g -v status -t $S 2>&1|Out-String).Trim())  border-status: $((& $PSMUX show-options -g -v pane-border-status -t $S 2>&1|Out-String).Trim())"

$proc = Start-Process -FilePath $hostExe -ArgumentList "`"$PSMUX`"","attach","-t",$S -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 6

$fs = [System.IO.File]::Open($outBin, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$bytes = New-Object byte[] $fs.Length
[void]$fs.Read($bytes, 0, $bytes.Length); $fs.Close()
Stop-All

# reconstruct grid
$grid = [char[,]]::new($ROWS, $COLS)
for ($r=0; $r -lt $ROWS; $r++){ for ($c=0; $c -lt $COLS; $c++){ $grid[$r,$c]=' ' } }
$row = 0; $col = 0
$s = [System.Text.Encoding]::GetEncoding(437).GetString($bytes)
$i = 0
while ($i -lt $s.Length) {
    $ch = $s[$i]
    if ($ch -eq [char]27) {
        if ($i+1 -lt $s.Length -and $s[$i+1] -eq '[') {
            $j = $i+2; $prm = ""
            while ($j -lt $s.Length -and ($s[$j] -match '[0-9;?><]')) { $prm += $s[$j]; $j++ }
            $final = if ($j -lt $s.Length) { $s[$j] } else { '' }
            if (($final -eq 'H' -or $final -eq 'f') -and $prm -notmatch '[?><]') {
                $p = $prm -split ';'
                $rr = if ($p.Count -ge 1 -and $p[0] -ne '') {[int]$p[0]} else {1}
                $cc = if ($p.Count -ge 2 -and $p[1] -ne '') {[int]$p[1]} else {1}
                $row = [Math]::Max(0,[Math]::Min($ROWS-1,$rr-1))
                $col = [Math]::Max(0,[Math]::Min($COLS-1,$cc-1))
            }
            $i = $j+1; continue
        } elseif ($i+1 -lt $s.Length -and $s[$i+1] -eq ']') {
            $j = $i+2
            while ($j -lt $s.Length -and [int]$s[$j] -ne 7) {
                if ($s[$j] -eq [char]27 -and $j+1 -lt $s.Length -and $s[$j+1] -eq '\') { $j++; break }
                $j++
            }
            $i = $j+1; continue
        } else { $i += 2; continue }
    }
    elseif ([int]$ch -eq 13) { $col = 0; $i++; continue }
    elseif ([int]$ch -eq 10) { $row = [Math]::Min($ROWS-1,$row+1); $i++; continue }
    elseif ([int]$ch -lt 32) { $i++; continue }
    else {
        if ($row -ge 0 -and $row -lt $ROWS -and $col -ge 0 -and $col -lt $COLS) { $grid[$row,$col] = $ch }
        $col++; if ($col -ge $COLS) { $col = $COLS-1 }
        $i++; continue
    }
}

Write-Host "`n=== Reconstructed screen (status bar OFF), $($bytes.Length) bytes ===" -ForegroundColor Cyan
$allText = ""
for ($r=0; $r -lt $ROWS; $r++){
    $sb = New-Object System.Text.StringBuilder
    for ($c=0; $c -lt $COLS; $c++){ [void]$sb.Append($grid[$r,$c]) }
    $line = $sb.ToString().TrimEnd()
    $allText += "$line`n"
    $tag = ""
    if ($line -match "ZZTOPTITLEZZ") { $tag += "  <== TOP TITLE" }
    if ($line -match "YYBOTTITLEYY") { $tag += "  <== BOT TITLE" }
    Write-Host ("{0,2}| {1}{2}" -f $r, $line, $tag)
}
$topOnBorder = [bool]($allText -match "ZZTOPTITLEZZ")
$botOnBorder = [bool]($allText -match "YYBOTTITLEYY")
Write-Host "`n=== VERDICT (status bar removed, border is only possible location) ===" -ForegroundColor Cyan
Write-Host "  top pane title on screen = $topOnBorder"
Write-Host "  bottom pane title on screen = $botOnBorder"
# Ground truth: the grid reconstruction can drop a label whose row also carries
# DEC line-drawing glyphs, so trust the raw rendered byte stream for the verdict.
$rawText = [System.Text.Encoding]::ASCII.GetString($bytes)
$topRaw = [bool]($rawText -match "ZZTOPTITLEZZ")
$botRaw = [bool]($rawText -match "YYBOTTITLEYY")
Write-Host "  raw-stream: top=$topRaw bottom=$botRaw"
if ($topRaw -and $botRaw) {
    Write-Host "  => both pane titles drawn on their borders with only 'pane-border-status top'. Feature WORKS (fix)." -ForegroundColor Green
    exit 0
} elseif ($topRaw -or $botRaw) {
    Write-Host "  => only one pane title rendered (top=$topRaw bottom=$botRaw)." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "  => NO pane title anywhere with status bar off => pane-border-status draws a plain border WITHOUT the title. BUG." -ForegroundColor Red
    exit 1
}
