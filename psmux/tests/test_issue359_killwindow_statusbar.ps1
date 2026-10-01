# Issue #359: kill-window must update the attached client's status bar (window
# list) immediately, without requiring prefix+n/p to force a redraw.
#
# This is a CLIENT-RENDER bug: server state always updates, but before the fix
# the attached TUI did not repaint the status line. The deterministic signal is
# a pixel diff of the status-bar ROW captured from a real attached psmux window:
#   - BUG present  -> baseline and after-kill captures are identical (stale)
#   - FIXED        -> after-kill differs from baseline (window list updated)
#
# Layer 1 (CLI) confirms the server state updated. Layer 2 (Win32) launches a
# real attached window and proves the rendered status bar changed on its own.
$ErrorActionPreference="Continue"
$PSMUX=(Get-Command psmux -EA Stop).Source
$INJ="$env:LOCALAPPDATA\Temp\psmux_injector.exe"
$OUT="$env:LOCALAPPDATA\Temp\issue359_test"; New-Item -ItemType Directory -Force -Path $OUT | Out-Null
$S="t359"
$psmuxDir="$env:USERPROFILE\.psmux"
$script:Pass=0; $script:Fail=0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;using System.Runtime.InteropServices;
public class W359{
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int cx,int cy,uint f);
 [StructLayout(LayoutKind.Sequential)] public struct RECT{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p,IntPtr l);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 public delegate bool EnumProc(IntPtr h,IntPtr l);
 public static IntPtr Find(uint w){IntPtr r=IntPtr.Zero;EnumWindows((h,l)=>{uint pid;GetWindowThreadProcessId(h,out pid);if(pid==w&&IsWindowVisible(h)){r=h;return false;}return true;},IntPtr.Zero);return r;}
}
'@

# --- Layer 1: server state updates immediately (sanity) ---
& $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $S 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX rename-window -t "${S}:0" w0 2>&1 | Out-Null
& $PSMUX new-window -t $S -n w1 2>&1 | Out-Null
& $PSMUX new-window -t $S -n w2 2>&1 | Out-Null
$before = (& $PSMUX list-windows -t $S -F '#{window_name}' 2>&1 | Out-String)
& $PSMUX kill-window -t "${S}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$after = (& $PSMUX list-windows -t $S -F '#{window_name}' 2>&1 | Out-String)
if ($before -match 'w1' -and $after -notmatch 'w1') { Write-Pass "Layer1: server removed w1 from window list ($($before -replace '\s+',' ') -> $($after -replace '\s+',' '))" }
else { Write-Fail "Layer1: server state wrong (before=$before after=$after)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# --- Layer 2: attached client status bar repaints on its own ---
# classic console host for reliable capture
$sk="HKCU:\Console\%%Startup"; if(-not(Test-Path $sk)){New-Item -Path $sk -Force|Out-Null}
$oDC=(Get-ItemProperty $sk -EA SilentlyContinue).DelegationConsole; $oDT=(Get-ItemProperty $sk -EA SilentlyContinue).DelegationTerminal
$classic="{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}"
Set-ItemProperty $sk -Name DelegationConsole -Value $classic; Set-ItemProperty $sk -Name DelegationTerminal -Value $classic
$ck="HKCU:\Console"; $oFace=(Get-ItemProperty $ck).FaceName; $oSz=(Get-ItemProperty $ck).FontSize
Set-ItemProperty $ck -Name FaceName -Value "Consolas"; Set-ItemProperty $ck -Name FontFamily -Value 54; Set-ItemProperty $ck -Name FontSize -Value 0x00120000

& $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 500
$conhost="$env:WINDIR\System32\conhost.exe"
$proc=Start-Process -FilePath $conhost -ArgumentList $PSMUX,"new-session","-s",$S -PassThru
Start-Sleep -Seconds 6
$child=Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" | Where-Object {$_.Name -eq 'psmux.exe'} | Select-Object -First 1
$cpid=if($child){[int]$child.ProcessId}else{$proc.Id}
$h=[IntPtr]::Zero; for($i=0;$i -lt 25;$i++){$h=[W359]::Find([uint32]$cpid);if($h -ne [IntPtr]::Zero){break};Start-Sleep -Milliseconds 200}

& $PSMUX set-option -g status-position top -t $S 2>&1 | Out-Null
& $PSMUX rename-window -t "${S}:0" w0 2>&1 | Out-Null
& $PSMUX new-window -t $S -n w1 2>&1 | Out-Null
& $PSMUX new-window -t $S -n w2 2>&1 | Out-Null
& $PSMUX select-window -t "${S}:0" 2>&1 | Out-Null
Start-Sleep -Seconds 1

# capture ONLY the top status row (thin strip) to avoid pane-cursor noise
function CaptureRow($file){
  [W359]::ShowWindow($h,3)|Out-Null;[W359]::BringWindowToTop($h)|Out-Null;[W359]::SetForegroundWindow($h)|Out-Null
  [W359]::SetWindowPos($h,[IntPtr](-1),0,0,0,0,3)|Out-Null; Start-Sleep -Milliseconds 700
  $r=New-Object W359+RECT;[W359]::GetWindowRect($h,[ref]$r)|Out-Null
  $w=$r.Right-$r.Left
  [W359]::SetWindowPos($h,[IntPtr](-2),0,0,0,0,3)|Out-Null
  $b=New-Object System.Drawing.Bitmap $w,30
  $g=[System.Drawing.Graphics]::FromImage($b)
  $g.CopyFromScreen($r.Left,$r.Top+44,0,0,(New-Object System.Drawing.Size($w,30)),[System.Drawing.CopyPixelOperation]::SourceCopy)
  $g.Dispose();$b.Save($file,[System.Drawing.Imaging.ImageFormat]::Png);$b.Dispose()
}
function DiffFraction($f1,$f2){
  $a=[System.Drawing.Bitmap]::FromFile($f1); $b=[System.Drawing.Bitmap]::FromFile($f2)
  $w=[Math]::Min($a.Width,$b.Width); $hh=[Math]::Min($a.Height,$b.Height)
  $diff=0; $tot=$w*$hh
  for($y=0;$y -lt $hh;$y+=2){ for($x=0;$x -lt $w;$x+=2){
    $pa=$a.GetPixel($x,$y); $pb=$b.GetPixel($x,$y)
    if([Math]::Abs($pa.R-$pb.R)+[Math]::Abs($pa.G-$pb.G)+[Math]::Abs($pa.B-$pb.B) -gt 60){ $diff++ }
  }}
  $a.Dispose(); $b.Dispose()
  return [double]$diff / ($tot/4.0)
}

# settle paint, baseline
& $INJ $cpid "^b{SLEEP:250}{ESC}" 2>&1 | Out-Null
Start-Sleep -Milliseconds 1200
CaptureRow "$OUT\base.png"
# kill middle window from separate process; NO input to the attached client
& $PSMUX kill-window -t "${S}:1" 2>&1 | Out-Null
Start-Sleep -Seconds 2
CaptureRow "$OUT\afterkill.png"

# With the bug present the status bar does not repaint at all -> the captured row
# is pixel-frozen (diff ~0%). With the fix the bar repaints (window list text
# changes, plus the clock ticks), giving a clear non-zero diff. 0.2% cleanly
# separates "frozen" (bug) from "repainted" (fixed).
$frac = DiffFraction "$OUT\base.png" "$OUT\afterkill.png"
Write-Host ("  status-row pixel diff after kill (no input): {0:P2}" -f $frac)
if ($frac -gt 0.002) {
    Write-Pass "Layer2: status bar repainted on its own after kill-window (diff $([math]::Round($frac*100,2))%)"
} else {
    Write-Fail "Layer2: status bar STALE after kill-window (diff $([math]::Round($frac*100,2))%) -- bug #359 present"
}

& $PSMUX kill-session -t $S 2>&1 | Out-Null
try{Stop-Process -Id $proc.Id -Force -EA SilentlyContinue}catch{}
Set-ItemProperty $ck -Name FaceName -Value $oFace; Set-ItemProperty $ck -Name FontSize -Value $oSz
if($oDC){Set-ItemProperty $sk -Name DelegationConsole -Value $oDC}else{Remove-ItemProperty $sk -Name DelegationConsole -EA SilentlyContinue}
if($oDT){Set-ItemProperty $sk -Name DelegationTerminal -Value $oDT}else{Remove-ItemProperty $sk -Name DelegationTerminal -EA SilentlyContinue}

Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
