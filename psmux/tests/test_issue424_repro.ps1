# Issue #424: nested-session guard blocks `new-session -d` when PSMUX_SESSION is set
# REPRODUCTION ONLY - proves whether the bug exists before any code change.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

function Info($m){ Write-Host $m -ForegroundColor Cyan }
function Good($m){ Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m){ Write-Host "  [BUG]  $m" -ForegroundColor Red }

function Cleanup {
    foreach ($s in @("i424_outer","i424_inner","i424_inner2","i424_attach")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
        Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue
    }
    Start-Sleep -Milliseconds 400
}

Cleanup

Info "`n=== BASELINE: new-session -d with NO PSMUX_SESSION set ==="
Remove-Item Env:\PSMUX_SESSION -EA SilentlyContinue
Remove-Item Env:\PSMUX_ACTIVE  -EA SilentlyContinue
$out = & $PSMUX new-session -d -s i424_outer 2>&1 | Out-String
Start-Sleep -Seconds 2
& $PSMUX has-session -t i424_outer 2>$null
$baseOk = ($LASTEXITCODE -eq 0)
Write-Host "  output: $($out.Trim())"
if ($baseOk) { Good "baseline detached session created" } else { Bad "baseline failed to create" }

Info "`n=== REPRO: new-session -d WHILE PSMUX_SESSION is set (simulating nested) ==="
$env:PSMUX_SESSION = "i424_outer"
$out2 = & $PSMUX new-session -d -s i424_inner 2>&1 | Out-String
Start-Sleep -Seconds 2
& $PSMUX has-session -t i424_inner 2>$null
$innerOk = ($LASTEXITCODE -eq 0)
Write-Host "  output: $($out2.Trim())"
Write-Host "  has-session inner exit: $LASTEXITCODE"
if ($innerOk) {
    Good "inner detached session WAS created (bug NOT reproduced on this path)"
} else {
    Bad "inner detached session was NOT created (BUG REPRODUCED)"
    if ($out2 -match "nested") { Bad "nesting warning printed for a -d session" }
}

Info "`n=== CONTROL: with PSMUX_ACTIVE set instead ==="
Remove-Item Env:\PSMUX_SESSION -EA SilentlyContinue
$env:PSMUX_ACTIVE = "1"
$out3 = & $PSMUX new-session -d -s i424_inner2 2>&1 | Out-String
Start-Sleep -Seconds 2
& $PSMUX has-session -t i424_inner2 2>$null
$inner2Ok = ($LASTEXITCODE -eq 0)
Write-Host "  output: $($out3.Trim())"
if ($inner2Ok) { Good "inner2 created with PSMUX_ACTIVE" } else { Bad "inner2 NOT created with PSMUX_ACTIVE (BUG)" }

Remove-Item Env:\PSMUX_ACTIVE -EA SilentlyContinue
Remove-Item Env:\PSMUX_SESSION -EA SilentlyContinue
Cleanup

Write-Host "`n=== SUMMARY ===" -ForegroundColor Yellow
Write-Host "baseline(-d, no env):        $baseOk"
Write-Host "nested -d (PSMUX_SESSION):    $innerOk   (expected: True)"
Write-Host "nested -d (PSMUX_ACTIVE):     $inner2Ok  (expected: True)"
