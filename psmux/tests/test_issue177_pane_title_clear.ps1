# Issue #177: pane title not cleared when set to empty string via select-pane -T
#
# BUG: select-pane -T "" does not clear an explicit pane title. After calling
#   psmux select-pane -t <session> -T "MYTITLE"
#   psmux select-pane -t <session> -T ""
# the title remains "MYTITLE" instead of being cleared (should revert to hostname).
#
# EXPECTED FIXED BEHAVIOR:
#   1. select-pane -T "MYTITLE" sets pane_title to "MYTITLE"
#   2. select-pane -T ""         clears it; pane_title reverts to auto-inferred hostname
#   3. Setting a new title after clearing works correctly
#   4. list-panes -F '#{pane_title}' reflects cleared state too

$ErrorActionPreference = "Continue"
$PSMUX      = (Get-Command psmux -EA Stop).Source
$SESSION    = "gap177"
$psmuxDir   = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.port" -Force -EA SilentlyContinue
    Remove-Item "$psmuxDir\$SESSION.key"  -Force -EA SilentlyContinue
}

# === SETUP ===
Cleanup
& $PSMUX new-session -d -s $SESSION
$deadline = (Get-Date).AddSeconds(12)
while (-not (Test-Path "$psmuxDir\$SESSION.port") -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Milliseconds 800

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' could not be created"
    exit 1
}

$hostname = [System.Net.Dns]::GetHostName()
Write-Host "`n=== Issue #177: pane title clear via select-pane -T '' ===" -ForegroundColor Cyan
Write-Host "  Hostname: $hostname" -ForegroundColor DarkGray

# ---------------------------------------------------------------
# [Test 1] Setting an explicit title works
# ---------------------------------------------------------------
Write-Host "`n[Test 1] select-pane -T 'MYTITLE' sets pane_title" -ForegroundColor Yellow
& $PSMUX select-pane -t $SESSION -T "MYTITLE" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$t1 = (& $PSMUX display-message -t $SESSION -p '#{pane_title}' 2>&1 | Out-String).Trim()
Write-Host "  pane_title after -T MYTITLE: '$t1'" -ForegroundColor DarkGray
if ($t1 -eq "MYTITLE") {
    Write-Pass "pane_title == 'MYTITLE' after explicit set"
} else {
    Write-Fail "Expected 'MYTITLE', got '$t1'"
}

# ---------------------------------------------------------------
# [Test 2] CORE: clearing with empty string reverts to hostname
# This is the exact bug from issue #177
# ---------------------------------------------------------------
Write-Host "`n[Test 2] select-pane -T '' clears title (reverts to hostname)" -ForegroundColor Yellow
& $PSMUX select-pane -t $SESSION -T "" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$t2 = (& $PSMUX display-message -t $SESSION -p '#{pane_title}' 2>&1 | Out-String).Trim()
Write-Host "  pane_title after -T '': '$t2'" -ForegroundColor DarkGray
Write-Host "  Expected (hostname):    '$hostname'" -ForegroundColor DarkGray
if ($t2 -eq $hostname) {
    Write-Pass "pane_title reverted to hostname '$hostname' after -T '' (bug fixed)"
} elseif ($t2 -eq "MYTITLE") {
    Write-Fail "BUG PRESENT: pane_title still 'MYTITLE' after -T '' -- title was not cleared"
} elseif ($t2 -eq "") {
    Write-Fail "pane_title is empty string instead of hostname '$hostname' after -T ''"
} else {
    Write-Fail "pane_title is '$t2', expected hostname '$hostname'"
}

# ---------------------------------------------------------------
# [Test 3] #T alias also reflects cleared title
# ---------------------------------------------------------------
Write-Host "`n[Test 3] #T alias matches pane_title after clear" -ForegroundColor Yellow
$hashT = (& $PSMUX display-message -t $SESSION -p '#T' 2>&1 | Out-String).Trim()
Write-Host "  #T after clear: '$hashT'" -ForegroundColor DarkGray
if ($hashT -eq $hostname) {
    Write-Pass "#T == hostname '$hostname' after title cleared"
} elseif ($hashT -eq "MYTITLE") {
    Write-Fail "BUG: #T still 'MYTITLE' after clear"
} else {
    Write-Fail "#T is '$hashT', expected hostname '$hostname'"
}

# ---------------------------------------------------------------
# [Test 4] list-panes -F '#{pane_title}' reflects cleared state
# ---------------------------------------------------------------
Write-Host "`n[Test 4] list-panes -F '#{pane_title}' reflects cleared state" -ForegroundColor Yellow
$lpTitle = (& $PSMUX list-panes -t $SESSION -F '#{pane_title}' 2>&1 | Out-String).Trim()
Write-Host "  list-panes pane_title: '$lpTitle'" -ForegroundColor DarkGray
if ($lpTitle -eq $hostname) {
    Write-Pass "list-panes shows hostname '$hostname' after title cleared"
} elseif ($lpTitle -eq "MYTITLE") {
    Write-Fail "BUG: list-panes still shows 'MYTITLE' after clear"
} else {
    Write-Fail "list-panes pane_title is '$lpTitle', expected hostname '$hostname'"
}

# ---------------------------------------------------------------
# [Test 5] After clearing, a new title can be set again
# ---------------------------------------------------------------
Write-Host "`n[Test 5] Setting a new title after clear works" -ForegroundColor Yellow
& $PSMUX select-pane -t $SESSION -T "NEWTITLE" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$t5 = (& $PSMUX display-message -t $SESSION -p '#{pane_title}' 2>&1 | Out-String).Trim()
Write-Host "  pane_title after re-set to NEWTITLE: '$t5'" -ForegroundColor DarkGray
if ($t5 -eq "NEWTITLE") {
    Write-Pass "pane_title == 'NEWTITLE' after re-setting title post-clear"
} else {
    Write-Fail "Expected 'NEWTITLE', got '$t5'"
}

# ---------------------------------------------------------------
# [Test 6] Clearing the re-set title also reverts to hostname
# ---------------------------------------------------------------
Write-Host "`n[Test 6] Clearing NEWTITLE also reverts to hostname" -ForegroundColor Yellow
& $PSMUX select-pane -t $SESSION -T "" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$t6 = (& $PSMUX display-message -t $SESSION -p '#{pane_title}' 2>&1 | Out-String).Trim()
Write-Host "  pane_title after second clear: '$t6'" -ForegroundColor DarkGray
if ($t6 -eq $hostname) {
    Write-Pass "Second clear also reverts to hostname '$hostname'"
} elseif ($t6 -eq "NEWTITLE") {
    Write-Fail "BUG: second clear did not work, still 'NEWTITLE'"
} else {
    Write-Fail "pane_title is '$t6', expected hostname '$hostname'"
}

# === TEARDOWN ===
Cleanup

# === SUMMARY ===
Write-Host "`n=== Issue #177 Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -eq 0) {
    Write-Host "`n  VERDICT: Issue #177 fix CONFIRMED. select-pane -T '' clears pane title." -ForegroundColor Green
} else {
    Write-Host "`n  VERDICT: Issue #177 STILL BROKEN or fix incomplete." -ForegroundColor Red
    Write-Host "  Expected: select-pane -T '' clears title, pane_title reverts to hostname." -ForegroundColor DarkGray
}

exit $script:TestsFailed
