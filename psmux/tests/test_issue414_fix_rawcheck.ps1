# Issue #414 fix raw-stream check: reporter's EXACT minimal config.
# Only `set -g pane-border-status top` (NO explicit pane-border-format).
# Check the raw rendered byte stream for BOTH pane titles.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "issue414_raw"
$psmuxDir = "$env:USERPROFILE\.psmux"
$outBin = "$env:TEMP\conpty_out.bin"
$hostExe = "$env:TEMP\conpty_ctrlc_host.exe"
$hostSrc = Join-Path $PSScriptRoot "conpty_ctrlc_host.cs"
function Stop-All {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 300
    Get-Process conpty_ctrlc_host -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 300; Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
}
if (-not (Test-Path $hostExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
    & $csc /nologo /optimize /out:$hostExe $hostSrc 2>&1 | Out-Null
}
Stop-All

& $PSMUX new-session -d -s $S -x 120 -y 30 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX set-option -g status off 2>&1 | Out-Null
& $PSMUX set-option -g pane-border-status top 2>&1 | Out-Null   # ONLY this - reporter's config
& $PSMUX split-window -v -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
& $PSMUX select-pane -t "${S}.0" -T "ZZTOPTITLEZZ" 2>&1 | Out-Null
& $PSMUX select-pane -t "${S}.1" -T "YYBOTTITLEYY" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

$proc = Start-Process -FilePath $hostExe -ArgumentList "`"$PSMUX`"","attach","-t",$S -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 6
$fs = [System.IO.File]::Open($outBin, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$bytes = New-Object byte[] $fs.Length
[void]$fs.Read($bytes, 0, $bytes.Length); $fs.Close()
Stop-All

$text = [System.Text.Encoding]::ASCII.GetString($bytes)
$top = $text -match "ZZTOPTITLEZZ"
$bot = $text -match "YYBOTTITLEYY"
Write-Host "captured $($bytes.Length) bytes (status off, only pane-border-status top set)"
Write-Host "TOP title in stream = $top"
Write-Host "BOT title in stream = $bot"
if ($top -and $bot) { Write-Host "PASS: both pane titles render with default format (fix works, reporter config)" -ForegroundColor Green; exit 0 }
elseif ($top -or $bot) { Write-Host "PARTIAL: only one title (top=$top bot=$bot)" -ForegroundColor Yellow; exit 1 }
else { Write-Host "FAIL: no titles" -ForegroundColor Red; exit 1 }
