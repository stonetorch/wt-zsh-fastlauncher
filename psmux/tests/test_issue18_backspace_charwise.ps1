#!/usr/bin/env pwsh
# Issue #18: PWSH -> tmux: cannot BACKSPACE by character - inconsistent behaviour
#
# Injects "echo abcXYZ", then 3 backspaces, then "Q", then {ENTER}.
# Asserts the echoed output is "echo abcQ" — exactly 3 chars deleted
# (X, Y, Z each removed one-at-a-time), proving char-wise backspace.

$ErrorActionPreference = "Continue"

$PSMUX     = (Get-Command psmux -EA Stop).Source
$SESSION   = "gap18"
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

Write-Host "`n=== Issue #18: Char-wise backspace ===" -ForegroundColor Cyan

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

# Inject: "echo abcXYZ" + 3 backspaces (removes Z, Y, X) + "Q" + ENTER
# Expected echoed output: "echo abcQ"
$keys = "echo abcXYZ{SLEEP:200}$BS{SLEEP:100}$BS{SLEEP:100}$BS{SLEEP:200}Q{SLEEP:100}{ENTER}"
& $injector $proc.Id $keys
Start-Sleep -Milliseconds 2000

$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String

Write-Host "`n[Test 1] 'echo abcQ' appears in output (3 chars deleted one-by-one)" -ForegroundColor Yellow
if ($cap -match "echo abcQ") {
    Write-Pass "'echo abcQ' found — backspace deleted exactly 3 characters char-wise"
} else {
    Write-Fail "'echo abcQ' NOT found. Capture below:"
    ($cap -split "`n" | Select-Object -Last 10) | ForEach-Object { Write-Host "    |$_|" -ForegroundColor DarkGray }
}

Write-Host "`n[Test 2] 'echo abcXYZ' (unedited) does NOT appear (backspace had effect)" -ForegroundColor Yellow
if ($cap -notmatch "echo abcXYZ") {
    Write-Pass "'echo abcXYZ' absent — backspace did remove characters"
} else {
    Write-Fail "'echo abcXYZ' still present — backspace had no effect at all"
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
    Write-Host "`n  VERDICT: VERIFIED_BROKEN — backspace not deleting char-wise" -ForegroundColor Red
} else {
    Write-Host "`n  VERDICT: PASS — backspace deletes exactly one character per press" -ForegroundColor Green
}

exit $script:fail
