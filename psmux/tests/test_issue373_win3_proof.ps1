$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "i373w3"
$injectorExe = "$env:TEMP\psmux_injector.exe"
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W3 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
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
& $PSMUX select-window -t "${SESSION}:3" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$h = $proc.MainWindowHandle
# SWP_NOSIZE=0x0001, SWP_NOZORDER=0x0004 -> move to 0,0 keeping size
[W3]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x0005) | Out-Null
[W3]::ShowWindow($h, 9) | Out-Null
[W3]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 800
& $injectorExe $proc.Id "^b{SLEEP:500}w" 2>&1 | Out-Null
Start-Sleep -Seconds 2
[W3]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 400
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$bmp.Save("$env:TEMP\i373_fix_active3_clean.png", [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
& $injectorExe $proc.Id "{ESC}" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
"saved i373_fix_active3_clean.png"
