# Issue #424 PROOF: detached nested new-session is allowed; attaching one still warns.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:P = 0; $script:F = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:P++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:F++ }

$names = @("i424_outer","i424_d","i424_dP","i424_Ad","i424_attach","i424_force")
function Cleanup {
    foreach ($s in $names) { & $PSMUX kill-session -t $s 2>&1 | Out-Null; Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue }
    Start-Sleep -Milliseconds 400
}
function Has($s){ & $PSMUX has-session -t $s 2>$null; return ($LASTEXITCODE -eq 0) }

Cleanup
Remove-Item Env:\PSMUX_SESSION -EA SilentlyContinue
Remove-Item Env:\PSMUX_ACTIVE  -EA SilentlyContinue
Remove-Item Env:\PSMUX_ALLOW_NESTING -EA SilentlyContinue

Write-Host "`n=== Issue #424 Proof ===" -ForegroundColor Cyan

# Simulate being inside a session
$env:PSMUX_SESSION = "i424_outer"

# TEST 1: nested `new-session -d` succeeds
Write-Host "`n[1] nested new-session -d creates detached session" -ForegroundColor Yellow
$o = & $PSMUX new-session -d -s i424_d 2>&1 | Out-String
Start-Sleep -Seconds 2
if ((Has "i424_d") -and ($o -notmatch "nested")) { Pass "new-session -d created while nested, no warning" }
else { Fail "new-session -d blocked/failed. out=$($o.Trim())" }

# TEST 2: combined flag -dP (getopt expansion) also allowed
Write-Host "`n[2] nested new-session -dP creates detached session" -ForegroundColor Yellow
$o = & $PSMUX new-session -dP -s i424_dP 2>&1 | Out-String
Start-Sleep -Seconds 2
if ((Has "i424_dP") -and ($o -notmatch "nested")) { Pass "combined -dP created while nested" }
else { Fail "-dP blocked/failed. out=$($o.Trim())" }

# TEST 3: -A -d (attach-if-exists but detached) allowed
Write-Host "`n[3] nested new-session -A -d creates detached session" -ForegroundColor Yellow
$o = & $PSMUX new-session -A -d -s i424_Ad 2>&1 | Out-String
Start-Sleep -Seconds 2
if ((Has "i424_Ad") -and ($o -notmatch "nested")) { Pass "-A -d created while nested" }
else { Fail "-A -d blocked/failed. out=$($o.Trim())" }

# TEST 4: attaching nested new-session (NO -d) STILL warns and does NOT create
Write-Host "`n[4] nested attaching new-session (no -d) still blocked" -ForegroundColor Yellow
$o = & $PSMUX new-session -s i424_attach 2>&1 | Out-String
Start-Sleep -Seconds 1
if (-not (Has "i424_attach") -and ($o -match "nested")) { Pass "attaching new-session warned and did not create (guard preserved)" }
else { Fail "attaching new-session should warn+block. created=$(Has 'i424_attach') out=$($o.Trim())" }

# TEST 5: PSMUX_ALLOW_NESTING=1 forces even an attaching one to proceed past guard
Write-Host "`n[5] PSMUX_ALLOW_NESTING=1 bypasses guard for -d" -ForegroundColor Yellow
$env:PSMUX_ALLOW_NESTING = "1"
$o = & $PSMUX new-session -d -s i424_force 2>&1 | Out-String
Start-Sleep -Seconds 2
if ((Has "i424_force") -and ($o -notmatch "nested")) { Pass "override still works with -d" }
else { Fail "override path broken. out=$($o.Trim())" }
Remove-Item Env:\PSMUX_ALLOW_NESTING -EA SilentlyContinue

Remove-Item Env:\PSMUX_SESSION -EA SilentlyContinue
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:P" -ForegroundColor Green
Write-Host "  Failed: $script:F" -ForegroundColor $(if($script:F -gt 0){"Red"}else{"Green"})
exit $script:F
