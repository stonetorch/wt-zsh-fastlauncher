#!/usr/bin/env pwsh
# Issue #7: pressing backspace removes whole words
#
# Injects "echo wordone wordtwo", then ONE backspace, then "X", then {ENTER}.
# Asserts the echoed output is "echo wordone wordtwX"
# (only the last char 'o' removed), NOT "echo wordone " (whole last word gone).

$ErrorActionPreference = "Continue"

$PSMUX     = (Get-Command psmux -EA Stop).Source
$SESSION   = "gap7"
$psmuxDir  = "$env:USERPROFILE\.psmux"
$injector  = "$env:TEMP\psmux_injector.exe"
$csc       = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$injSrc    = "$PSScriptRoot\injector.cs"

$script:pass = 0
$script:fail = 0

function Write-Pass([string]$msg) { $script:pass++; Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Write-Fail([string]$msg) { $script:fail++; Write-Host "  [FAIL] $msg" -ForegroundColor Red }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-Port {
    param([string]$sess)
    $portFile = "$psmuxDir\$sess.port"
    for ($i = 0; $i -lt 24; $i++) {
        if (Test-Path $portFile) {
            $v = (Get-Content $portFile -Raw -EA SilentlyContinue).Trim()
            if ($v -match '^\d+$' -and [int]$v -gt 0) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Write-Host "`n=== Issue #7: One backspace removes ONE char, not a whole word ===" -ForegroundColor Cyan

# Build injector if missing
if (-not (Test-Path $injector)) {
    if (Test-Path $injSrc) {
        & $csc /nologo /optimize /out:$injector $injSrc 2>&1 | Out-Null
    }
}
if (-not (Test-Path $injector)) {
    Write-Host "[SKIP] Injector not available" -ForegroundColor DarkYellow
    exit 0
}

Cleanup

# Launch an attached (visible) session so injection has a console
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru

if (-not (Wait-Port -sess $SESSION)) {
    Write-Host "[ERROR] Port file did not appear within 12s" -ForegroundColor Red
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    Cleanup; exit 1
}

# Clear startup noise, wait for shell prompt
Start-Sleep -Milliseconds 1500

# Backspace token: {RAW:08:08:0000} — VK_BACK (0x08), UnicodeChar=0x08, no modifier
$BS = "{RAW:08:08:0000}"

# Inject: "echo wordone wordtwo" + 1 backspace (removes 'o') + "X" + ENTER
# Expected echoed output: "echo wordone wordtwX"
$keys = "echo wordone wordtwo{SLEEP:200}$BS{SLEEP:200}X{SLEEP:100}{ENTER}"
& $injector $proc.Id $keys
Start-Sleep -Milliseconds 2000

$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String

Write-Host "`n[Test 1] 'wordtwX' appears (only last char removed, one backspace = one char)" -ForegroundColor Yellow
if ($cap -match "wordtwX") {
    Write-Pass "'wordtwX' found — single backspace removed exactly one character"
} else {
    Write-Fail "'wordtwX' NOT found. Capture below:"
    ($cap -split "`n" | Select-Object -Last 10) | ForEach-Object { Write-Host "    |$_|" -ForegroundColor DarkGray }
}

Write-Host "`n[Test 2] 'wordone X' (whole word deleted) does NOT appear" -ForegroundColor Yellow
# If whole word was removed, "wordtwo" would be gone and we'd see "wordone X" or "wordone" followed by X
if ($cap -notmatch "wordone X" -and $cap -notmatch "wordoneX") {
    Write-Pass "No evidence of whole-word deletion — backspace was char-wise"
} else {
    Write-Fail "Pattern suggests whole-word deletion occurred"
    ($cap -split "`n" | Select-Object -Last 10) | ForEach-Object { Write-Host "    |$_|" -ForegroundColor DarkGray }
}

Write-Host "`n[Test 3] 'echo wordone wordtwX' appears as complete expected string" -ForegroundColor Yellow
if ($cap -match "echo wordone wordtwX") {
    Write-Pass "'echo wordone wordtwX' found — full expected output correct"
} else {
    Write-Fail "'echo wordone wordtwX' NOT found"
    Write-Host "    NOTE: full string check failed — check individual tests above for detail" -ForegroundColor DarkGray
}

# Teardown
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:fail)" -ForegroundColor $(if ($script:fail -gt 0) { "Red" } else { "Green" })

if ($script:fail -gt 0) {
    Write-Host "`n  VERDICT: VERIFIED_BROKEN — backspace still deletes whole words" -ForegroundColor Red
} else {
    Write-Host "`n  VERDICT: PASS — backspace deletes exactly one character per press" -ForegroundColor Green
}

exit $script:fail
