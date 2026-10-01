# Issue #399 (deeper cause): Claude Code agent-teams launches a teammate with the
# POSIX idiom  `cd '<dir>' && env VAR=val ... '<program>' <args>`  delivered via
# `respawn-pane -- <command>`. psmux runs the pane command through PowerShell,
# where `env` is not a cmdlet, so the launch dies with
#   "env: The term 'env' is not recognized ..."
# and the teammate never starts (mailbox never read -> idle). This reproduced the
# real, intermittent teammate failure (intermittent because `env` only works when
# Git's usr\bin happens to be on the pane's PATH).
#
# FIX: build_command parses the `env VAR=val program` idiom (and optional
# `cd DIR &&`) and applies the env/cwd directly, running the program without the
# `env` prefix -- independent of PATH.
#
# This test is DETERMINISTIC (no Claude, no credits): it drives the exact
# mechanism and proves the env vars are set AND the program runs.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue399env"
$psmuxDir = "$env:USERPROFILE\.psmux"
$out = "C:\cctest\env399_out.txt"
$script:TestsPassed = 0; $script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Cleanup { & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 400; Remove-Item "$psmuxDir\$SESSION.*",$out -Force -EA SilentlyContinue }

if (-not (Test-Path "C:\cctest")) { New-Item -ItemType Directory "C:\cctest" -Force | Out-Null }
Cleanup
# Guarantee `env` (Git's usr\bin) is NOT on the session's PATH, so this reproduces
# the failure deterministically instead of depending on ambient PATH. The fix must
# make the launch work WITHOUT relying on the `env` binary being present.
$origPath = $env:PATH
$env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notlike '*Git\usr\bin*' -and $_ -notlike '*Git\bin*' -and $_ -notlike '*Git\mingw64*' }) -join ';'
& $PSMUX new-session -d -s $SESSION -x 200 -y 50 -c "C:\cctest"
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

Write-Host "`n=== Issue #399: respawn-pane honors POSIX 'env VAR=val program' launch idiom ===" -ForegroundColor Cyan

# A placeholder pane (Claude uses split-window -- cat)
$id = (& $PSMUX split-window -P -F '#{pane_id}' -t $SESSION -- cat 2>&1 | Out-String).Trim()
Start-Sleep -Seconds 1

# The exact idiom Claude Code uses to launch a teammate: cd + env VAR=val + program.
# Program + args are all SPACE-FREE paths (no inline quotes) because the CLI->server
# pipeline strips quotes; Claude's real teammate command is likewise space/quote-free
# (C:\Users\...\claude.exe --agent-id Bob@x --model haiku). The probe script reads an
# env var it received and writes it to a file -- proving env was set AND the program ran.
$nodeSrc = (Get-Command node -EA Stop).Source
$nodeExe = "C:\cctest\node399.exe"
Copy-Item $nodeSrc $nodeExe -Force
$probe = "C:\cctest\probe399.js"
"require('fs').writeFileSync('C:/cctest/env399_out.txt','PSMUX399='+process.env.PSMUX399)" | Set-Content $probe -Encoding ascii
$cmd = "cd 'C:\cctest' && env PSMUX399=itworks $nodeExe $probe"
Write-Host "[respawn] respawn-pane -k -t $id -- <cd && env PSMUX399=itworks node ...>" -ForegroundColor Yellow
& $PSMUX respawn-pane -k -t $id -- $cmd 2>&1 | Out-Null

$ok = $false
for ($i=0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (Test-Path $out) { $ok = $true; break } }

if ($ok) {
    $content = (Get-Content $out -Raw).Trim()
    if ($content -eq "PSMUX399=itworks") { Write-Pass "env var was set AND program ran (got '$content')" }
    else { Write-Fail "program ran but env var wrong (got '$content', expected 'PSMUX399=itworks')" }
} else {
    Write-Fail "program never ran -- the 'env' idiom failed (this is the bug: 'env' not recognized under pwsh)"
    $cap = & $PSMUX capture-pane -t $id -p 2>&1 | Out-String
    Write-Host "  pane content:" -ForegroundColor DarkGray
    ($cap -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 5) | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
}

Cleanup
Remove-Item "C:\cctest\node399.exe","C:\cctest\probe399.js" -Force -EA SilentlyContinue
$env:PATH = $origPath
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed