# Issue #365: `psmux popup <command>` opens an empty popup window
#
# TANGIBLE PROOF via the popup PTY state exposed by dump-state.
#
# The user runs `psmux popup lazygit` / `psmux popup cmd` from inside a pane and
# the popup border opens but its content area stays completely blank.
#
# This script launches a REAL visible session with the binary under test, sends
# the user's EXACT command into the pane, then polls the popup state for 8s:
#
#   popup_active  = True   -> the popup overlay opened
#   popup_has_pty = True   -> the command's PTY was actually spawned (cmd is running)
#   content rows  = N      -> how many NON-BLANK rows the popup actually renders
#
# Verdict:
#   has_pty == True AND content rows > 0  => FIXED  (command output renders)
#   has_pty == True AND content rows == 0 => BUG    (PTY spawned but nothing pumped
#                                                    into the popup = empty popup)
#
# Proven result:
#   v3.3.5 (released)        -> active=True has_pty=True rows=0  (BUG, matches report)
#   HEAD   (commit 27b4778)  -> active=True has_pty=True rows=3  (FIXED, cmd banner shows)
#
# Run against any binary:
#   pwsh -File verify_issue365_popup.ps1 -PsmuxExe <path-to-psmux.exe> -Label head

param(
    [Parameter(Mandatory=$true)][string]$PsmuxExe,
    [string]$Label = "psmux"
)

$ErrorActionPreference = "Continue"
$psmuxDir = "$env:USERPROFILE\.psmux"
$S = "iss365" + ($Label -replace '[^a-zA-Z0-9]','')

function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info($m){ Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

function Dump($Session){
    $port=(Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key =(Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp=[System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$port); $tcp.NoDelay=$true; $tcp.ReceiveTimeout=8000
    $st=$tcp.GetStream(); $w=[System.IO.StreamWriter]::new($st); $r=[System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n");$w.Flush();$null=$r.ReadLine();$w.Write("PERSISTENT`n");$w.Flush()
    $w.Write("dump-state`n");$w.Flush()
    $best=$null
    for($j=0;$j -lt 300;$j++){ try{$l=$r.ReadLine()}catch{break}; if($null -eq $l){break}
        if($l -ne "NC" -and $l.Length -gt 100){$best=$l}; if($best){$tcp.ReceiveTimeout=50} }
    $tcp.Close(); return $best
}

Write-Host ""
Write-Host ("="*64) -ForegroundColor Cyan
Write-Host "Issue #365 popup proof   binary=$Label" -ForegroundColor Cyan
Write-Host "  $PsmuxExe" -ForegroundColor DarkGray
Write-Host ("="*64) -ForegroundColor Cyan

# Clean: kill EVERY psmux build + wipe session state so the target binary cannot
# inherit a warm server of a different build (a version mismatch would void the run).
Get-Process psmux,tmux,pmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 1000
Get-ChildItem $psmuxDir -File -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue

# Launch a REAL visible attached window with the TARGET binary only
$proc = Start-Process -FilePath $PsmuxExe -ArgumentList "new-session","-s",$S -PassThru
$up=$false
for ($i=0;$i -lt 60;$i++){ Start-Sleep -Milliseconds 300; if (Test-Path "$psmuxDir\$S.port"){ $up=$true; break } }
if (-not $up) { Write-Fail "session never wrote port file"; exit 2 }
Start-Sleep -Seconds 2
Write-Info "session live (pid=$($proc.Id))"

# The user's EXACT command, typed from inside the pane (no -t, no -E)
& $PsmuxExe send-keys -t $S "& '$PsmuxExe' popup cmd" Enter

$maxRows = 0; $active=$false; $hasPty=$false
for ($t=1; $t -le 8; $t++){
    Start-Sleep -Seconds 1
    $d = Dump $S | ConvertFrom-Json
    $ne = @($d.popup_rows | Where-Object { ($_.runs.text -join '').Trim().Length -gt 0 })
    if ($d.popup_active){ $active=$true }
    if ($d.popup_has_pty){ $hasPty=$true }
    if ($ne.Count -gt $maxRows){ $maxRows = $ne.Count }
    $first = if($ne.Count -gt 0){ ($ne[0].runs.text -join '').Trim() } else { '' }
    Write-Info "t=${t}s active=$($d.popup_active) has_pty=$($d.popup_has_pty) rows=$($ne.Count) first='$first'"
}

Write-Host ""
if (-not $active) {
    Write-Fail "popup never opened (popup_active stayed false)"
} elseif ($hasPty -and $maxRows -gt 0) {
    Write-Pass "FIXED: popup is interactive and renders command output (max $maxRows non-blank rows)"
} else {
    Write-Fail "BUG REPRODUCED: popup opened with a PTY but rendered EMPTY (max non-blank rows=$maxRows)"
}

# Teardown
Get-Process psmux,tmux,pmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Get-ChildItem $psmuxDir -File -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Write-Host ""
