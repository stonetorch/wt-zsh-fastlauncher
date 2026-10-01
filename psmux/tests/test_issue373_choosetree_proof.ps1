# Issue #373: capture a REAL screenshot of the choose-window overlay.
# Ground truth for (a) '*' marker on active window and (b) which row is highlighted.
param([int]$ActiveIdx = 2)
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "i373shot"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$outPng = "$env:TEMP\issue373_chooser_active${ActiveIdx}.png"

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
& $PSMUX rename-window -t "${SESSION}:0" win0 2>&1 | Out-Null
& $PSMUX rename-window -t "${SESSION}:1" win1 2>&1 | Out-Null
& $PSMUX rename-window -t "${SESSION}:2" win2 2>&1 | Out-Null
& $PSMUX rename-window -t "${SESSION}:3" win3 2>&1 | Out-Null
& $PSMUX select-window -t "${SESSION}:$ActiveIdx" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$active = (& $PSMUX display-message -t $SESSION -p '#{window_index}:#{window_name}' 2>&1).Trim()
Write-Host "Active window = $active" -ForegroundColor Cyan

# Bring psmux to foreground
$h = $proc.MainWindowHandle
Write-Host "MainWindowHandle = $h"
if ($h -ne 0) { [Win]::ShowWindow($h, 9) | Out-Null; [Win]::SetForegroundWindow($h) | Out-Null }
Start-Sleep -Milliseconds 800

# Open chooser (WriteConsoleInput - no focus needed, but window is now foreground for capture)
& $injectorExe $proc.Id "^b{SLEEP:500}w" 2>&1 | Out-Null
Start-Sleep -Seconds 2

# Re-assert foreground and capture full primary screen
if ($h -ne 0) { [Win]::SetForegroundWindow($h) | Out-Null }
Start-Sleep -Milliseconds 500

$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen 2>$null
if (-not $bounds) {
    Add-Type -AssemblyName System.Windows.Forms
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
}
$bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size)
$bmp.Save($outPng, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Host "Screenshot saved: $outPng" -ForegroundColor Green

# also try window-rect crop if handle valid
if ($h -ne 0) {
    $r = New-Object Win+RECT
    [Win]::GetWindowRect($h, [ref]$r) | Out-Null
    Write-Host "Window rect: L=$($r.Left) T=$($r.Top) R=$($r.Right) B=$($r.Bottom)"
}

& $injectorExe $proc.Id "{ESC}" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Write-Host "DONE -> $outPng"
