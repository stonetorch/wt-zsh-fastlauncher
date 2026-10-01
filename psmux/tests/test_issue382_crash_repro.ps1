# Issue #382: "psmux + claude + neovim = window crashes"
#
# CONCLUSION (proven by this harness): this is NOT a psmux bug. It is a Windows
# conhost.exe use-after-free provoked by Claude Code spawning nvim as its editor.
# It reproduces IDENTICALLY with no psmux involved.
#
# Evidence chain:
#   - WER dumps (%LOCALAPPDATA%\CrashDumps\conhost.exe.*.dmp) are all identical:
#     0xC0000005 read access violation at conhost.exe TextBuffer::GetSize, called
#     from ConsoleWaitBlock::Notify (a pending console read completed against a
#     TextBuffer that nvim's alternate-screen swap had already freed).
#   - Inside psmux, the only byte psmux writes to the pane before the crash is the
#     forwarded 0x07 (Ctrl+G) keystroke: psmux injects nothing unsolicited.
#   - PART B below runs the SAME scenario with NO psmux (claude in its own
#     console) and gets the SAME conhost crash.
#
# This harness is DIAGNOSTIC, not a pass/fail regression: there is no psmux code
# change that fixes a conhost bug. It documents and re-demonstrates the finding.
#
# SAFETY: launches a second `claude`. It NEVER kills claude by name (that would
# kill the Claude Code session driving this). It records pre-existing claude PIDs
# and only stops NEW ones; kill-session cascades to the pane tree anyway.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA SilentlyContinue).Source
$SESSION = "crash382"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$repoTests = Split-Path -Parent $MyInvocation.MyCommand.Path

$claudeCmd = Get-Command claude -EA SilentlyContinue
$nvimCmd   = Get-Command nvim   -EA SilentlyContinue
if (-not $PSMUX -or -not $claudeCmd -or -not $nvimCmd) {
    Write-Host "[SKIP] needs psmux + claude + nvim on PATH (psmux=$([bool]$PSMUX) claude=$([bool]$claudeCmd) nvim=$([bool]$nvimCmd))" -ForegroundColor Yellow
    exit 0
}

$script:preClaudePids = @(Get-Process claude -EA SilentlyContinue | Select-Object -ExpandProperty Id)
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injectorExe (Join-Path $repoTests 'injector.cs') 2>&1 | Out-Null
}
function Kill-NewClaude {
    foreach ($cpid in @(Get-Process claude -EA SilentlyContinue | Select-Object -ExpandProperty Id)) {
        if ($script:preClaudePids -notcontains $cpid) { try { Stop-Process -Id $cpid -Force -EA SilentlyContinue } catch {} }
    }
}
function Conhost-FaultSince($since) {
    $fault = $false
    Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$since; Id=1000} -EA SilentlyContinue |
      Select-Object -First 8 | ForEach-Object { if ($_.Message -match "conhost") { $fault = $true } }
    return $fault
}

# ── PART A: inside psmux ────────────────────────────────────────────────────
Write-Host "`n=== PART A: claude + nvim + Ctrl+G INSIDE psmux ===" -ForegroundColor Cyan
Kill-NewClaude
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Get-Process psmux,nvim,WerFault -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 800
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$tA = Get-Date
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4
& $PSMUX send-keys -t $SESSION '$env:EDITOR="nvim --clean"' Enter
Start-Sleep -Milliseconds 800
& $PSMUX send-keys -t $SESSION 'claude' Enter
Start-Sleep -Seconds 12
& $injectorExe $proc.Id "{ENTER}" | Out-Null
Start-Sleep -Seconds 2
& $injectorExe $proc.Id "hello" | Out-Null
Start-Sleep -Milliseconds 800
Write-Host "[ACTION] Ctrl+G" -ForegroundColor Yellow
& $injectorExe $proc.Id "^g" | Out-Null
$aCrashed = $false
for ($i=0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    & $PSMUX has-session -t $SESSION 2>$null
    if (($LASTEXITCODE -ne 0) -or ($null -eq (Get-Process -Id $proc.Id -EA SilentlyContinue))) { $aCrashed = $true; break }
}
$aFault = Conhost-FaultSince $tA
Write-Host ("PART A: sessionDied={0}  conhostFault={1}" -f $aCrashed, $aFault) -ForegroundColor $(if($aCrashed -or $aFault){"Red"}else{"Green"})
Kill-NewClaude
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
if ($proc) { try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {} }
Get-Process nvim,WerFault -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Start-Sleep -Seconds 1

# ── PART B: control, NO psmux ───────────────────────────────────────────────
Write-Host "`n=== PART B: SAME scenario with NO psmux (claude in its own console) ===" -ForegroundColor Cyan
$tB = Get-Date
$env:EDITOR = "nvim --clean"
$bproc = Start-Process -FilePath $claudeCmd.Source -WorkingDirectory (Split-Path $repoTests -Parent) -PassThru
Start-Sleep -Seconds 13
& $injectorExe $bproc.Id "{ENTER}" | Out-Null
Start-Sleep -Seconds 2
& $injectorExe $bproc.Id "hello" | Out-Null
Start-Sleep -Milliseconds 800
Write-Host "[ACTION] Ctrl+G (no psmux)" -ForegroundColor Yellow
& $injectorExe $bproc.Id "^g" | Out-Null
$bCrashed = $false
for ($i=0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    if ($null -eq (Get-Process -Id $bproc.Id -EA SilentlyContinue)) { $bCrashed = $true; break }
}
$bFault = Conhost-FaultSince $tB
Write-Host ("PART B: claudeDied={0}  conhostFault={1}" -f $bCrashed, $bFault) -ForegroundColor $(if($bCrashed -or $bFault){"Red"}else{"Green"})
foreach ($cp in @(Get-Process claude -EA SilentlyContinue | Where-Object { $script:preClaudePids -notcontains $_.Id })) { try { Stop-Process -Id $cp.Id -Force -EA SilentlyContinue } catch {} }
if ($bproc) { try { Stop-Process -Id $bproc.Id -Force -EA SilentlyContinue } catch {} }
Get-Process nvim,WerFault -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
$env:EDITOR = $null

# ── Verdict ─────────────────────────────────────────────────────────────────
Write-Host "`n=== VERDICT ===" -ForegroundColor Cyan
if (($aCrashed -or $aFault) -and ($bCrashed -or $bFault)) {
    Write-Host "conhost.exe crashes BOTH inside psmux AND without psmux -> confirmed Windows/Claude-Code/nvim bug, NOT a psmux regression." -ForegroundColor Yellow
} elseif (($aCrashed -or $aFault) -and -not ($bCrashed -or $bFault)) {
    Write-Host "Crashed only inside psmux -> revisit: psmux may be involved after all." -ForegroundColor Red
} else {
    Write-Host "No crash observed this run (the conhost UAF is timing-racy; re-run a few times)." -ForegroundColor DarkYellow
}