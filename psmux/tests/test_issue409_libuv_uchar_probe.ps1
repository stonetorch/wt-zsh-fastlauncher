# Decisive mechanism probe for issue #409 fix:
# Does Node/libuv, reading a real console in raw mode, emit the KEY_EVENT's
# UnicodeChar payload, or does it re-derive CR from VK_RETURN?
#
# We launch a standalone Node raw-stdin receiver in its OWN console (no psmux),
# then inject VK_RETURN + LEFT_CTRL twice: once with u_char=0x0D (current psmux
# behavior) and once with u_char=0x0A (the proposed fix). If node reports 0x0A
# for the second case, the fix's mechanism is valid.

$ErrorActionPreference = "Continue"
$recvJs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "ctrl_enter_recv.js"
$log = "$env:TEMP\psmux_409_probe.log"
Remove-Item $log -Force -EA SilentlyContinue

$injector = "$env:TEMP\psmux_injector.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$injSrc = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "injector.cs"
& $csc /nologo /optimize /out:$injector $injSrc 2>&1 | Out-Null

# Launch node in its OWN console window (fresh console => stdin is a TTY)
$proc = Start-Process -FilePath "node" -ArgumentList "`"$recvJs`"","`"$log`"" -PassThru
Start-Sleep -Seconds 2
$ready = $false
for ($i=0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 200; if ((Test-Path $log) -and ((Get-Content $log -Raw) -match "READY")) { $ready=$true; break } }
Write-Host "node PID=$($proc.Id) ready=$ready" -ForegroundColor Cyan

function ProbeCount { @(Get-Content $log | Where-Object { $_ -like "BYTES:*" }).Count }
function Probe($keys, $label) {
    $before = ProbeCount
    & $injector $proc.Id $keys 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    $lines = @(Get-Content $log | Where-Object { $_ -like "BYTES:*" })
    $new = if ($lines.Count -gt $before) { $lines[$before..($lines.Count-1)] -join " " } else { "(none)" }
    Write-Host ("  {0,-28} => {1}" -f $label, $new) -ForegroundColor Yellow
    return $new
}

Write-Host "`n--- Probe (standalone node, no psmux) ---" -ForegroundColor Cyan
$a = Probe "{RAW:0D:0D:0008}" "VK_RETURN+CTRL u_char=0x0D"
$b = Probe "{RAW:0D:0A:0008}" "VK_RETURN+CTRL u_char=0x0A"

Write-Host "`n--- Verdict ---" -ForegroundColor Cyan
if ($a -match "0d") { Write-Host "  u_char=0x0D -> node sees CR (matches current psmux bug)" -ForegroundColor Green }
else { Write-Host "  u_char=0x0D -> node saw: $a (unexpected)" -ForegroundColor Red }
if ($b -match "0a" -and $b -notmatch "0d") { Write-Host "  u_char=0x0A -> node sees LF: FIX MECHANISM VALID" -ForegroundColor Green }
elseif ($b -match "0d") { Write-Host "  u_char=0x0A -> node still sees CR: libuv re-derives, PR approach WOULD FAIL" -ForegroundColor Red }
else { Write-Host "  u_char=0x0A -> node saw: $b" -ForegroundColor Red }

try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Write-Host "`nFull probe log:" -ForegroundColor DarkGray
Get-Content $log | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
