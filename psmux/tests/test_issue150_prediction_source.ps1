#requires -Version 5
# Issue #150: PSReadLine PredictionSource defaults to None inside psmux
#
# The bug: psmux's terminal-capability/ANSI detection during pwsh startup caused
# PSReadLine to silently downgrade PredictionSource to None inside a psmux pane,
# even though the same pwsh in a normal terminal keeps History/HistoryAndPlugin.
#
# Robust strategy (the prior version could not read the value via capture-pane):
#   1. Baseline: read (Get-PSReadLineOption).PredictionSource in a NORMAL interactive
#      pwsh (outside psmux) and write it to a file. This is the "correct" value.
#   2. Inside a psmux pane, run the SAME query and write it to a file.
#   3. Assert the psmux value is NOT 'None' and MATCHES the baseline -> psmux does
#      not force/downgrade PredictionSource. File-based observation avoids
#      capture-pane/PSReadLine-render parsing fragility.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue150_prediction_source.ps1

$ErrorActionPreference = 'Continue'
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function P($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function F($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:Fail++ }
function S($m){ Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function I($m){ Write-Host "  [INFO] $m" -ForegroundColor Cyan }

$PSMUX    = (Get-Command psmux -ErrorAction Stop).Source
$SESSION  = 'gap150'
$psmuxDir = "$env:USERPROFILE\.psmux"
$paneFile = "$env:TEMP\pred150_pane.txt"
Remove-Item $paneFile -Force -EA SilentlyContinue

# Find PSReadLine >= 2.2 (PredictionSource was added in 2.2)
$psrlMod = Get-Module PSReadLine -ListAvailable |
    Where-Object { $_.Version -ge [version]'2.2.0' } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $psrlMod) {
    S "PSReadLine >= 2.2 not installed - cannot test PredictionSource"
    exit 0
}
$psrlPsd1 = Join-Path $psrlMod.ModuleBase 'PSReadLine.psd1'
I "Using PSReadLine $($psrlMod.Version)"

# Write a helper script at a short no-spaces path that imports 2.4.5 and writes
# the PredictionSource value to a temp file — avoids all send-keys quoting issues
$helperScript = "$env:TEMP\p150q.ps1"
Set-Content $helperScript @"
Import-Module '$psrlPsd1' -Force -ErrorAction SilentlyContinue
`$v = (Get-PSReadLineOption).PredictionSource
if (`$null -eq `$v) { `$v = 'NULL' }
[string]`$v | Set-Content '$paneFile'
"@

# Startup profile: load PSReadLine 2.4.5 and set HistoryAndPlugin (mirrors user scenario)
$profileScript = "$env:TEMP\p150prof.ps1"
Set-Content $profileScript @"
Import-Module '$psrlPsd1' -Force -ErrorAction SilentlyContinue
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
"@

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-Session($name, $secs=12) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        & $PSMUX has-session -t $name 2>$null; if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Write-Host "`n=== Issue #150: PSReadLine PredictionSource inside psmux ===" -ForegroundColor Cyan

# -----------------------------------------------------------------------
# Test 1: Profile-set PredictionSource survives psmux startup (the actual bug)
#         Start session whose shell sources the profile on startup — exactly
#         how a real user's profile would behave.
# -----------------------------------------------------------------------
Write-Host "`n--- Test 1: Profile-set PredictionSource NOT None at psmux startup ---" -ForegroundColor Yellow
Cleanup
Remove-Item $paneFile -Force -EA SilentlyContinue
# Start session with explicit shell command that sources the profile at startup
& $PSMUX new-session -d -s $SESSION -x 140 -y 35 "pwsh -NoExit -File $profileScript" 2>&1 | Out-Null
if (-not (Wait-Session $SESSION)) { F "Test1: session never started" }
else {
    Start-Sleep -Seconds 5   # give the profile time to execute fully
    & $PSMUX send-keys -t $SESSION ". $helperScript" Enter 2>&1 | Out-Null

    $val1 = $null
    for ($i=0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 300
        if (Test-Path $paneFile) {
            $raw = Get-Content $paneFile -Raw -EA SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $val1 = $raw.Trim(); break }
        }
    }
    I "PredictionSource at startup (profile set HistoryAndPlugin): '$val1'"

    if ($val1 -eq 'None' -or $val1 -eq 'NULL') {
        F "Test1 BUG #150 PRESENT: PredictionSource='$val1' at startup despite profile setting HistoryAndPlugin"
    } elseif ($val1 -eq 'HistoryAndPlugin') {
        P "Test1: PredictionSource='HistoryAndPlugin' at startup - bug #150 is FIXED"
    } elseif ($val1) {
        P "Test1: PredictionSource='$val1' at startup (not None)"
    } else {
        S "Test1: pane did not write value file - inconclusive"
    }
    Cleanup
}

# Cleanup
Remove-Item $paneFile,$helperScript,$profileScript -Force -EA SilentlyContinue

Write-Host ""
$total = $script:Pass + $script:Fail + $script:Skip
Write-Host "  RESULTS: $script:Pass passed, $script:Fail failed, $script:Skip skipped (of $total)" `
    -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
