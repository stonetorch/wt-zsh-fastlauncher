#!/usr/bin/env pwsh
# Issue #17: PWSH -> tmux: cannot enter SPACE
#
# Injects "echo hello world" (contains a space) then {ENTER}.
# Asserts capture-pane shows "hello world" with the space intact,
# proving the space key is delivered to the child shell correctly.

$ErrorActionPreference = "Continue"

$PSMUX     = (Get-Command psmux -EA Stop).Source
$SESSION   = "gap17"
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

Write-Host "`n=== Issue #17: Space key injection ===" -ForegroundColor Cyan

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

# Clear any startup noise and wait for shell prompt
Start-Sleep -Milliseconds 1500

# Inject "echo hello world" then ENTER
# The space between "hello" and "world" is the critical character under test
& $injector $proc.Id "echo hello world{SLEEP:200}{ENTER}"
Start-Sleep -Milliseconds 2000

# Capture the pane output and look for the echoed string
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String

Write-Host "`n[Test 1] 'hello world' appears in pane output (space preserved)" -ForegroundColor Yellow
if ($cap -match "hello world") {
    Write-Pass "'hello world' found in capture-pane — space was delivered correctly"
} else {
    Write-Fail "'hello world' NOT found — space may have been dropped. Capture: $($cap[-300..-1] -join '')"
    Write-Host "    --- last 8 lines of capture-pane ---" -ForegroundColor DarkGray
    ($cap -split "`n" | Select-Object -Last 8) | ForEach-Object { Write-Host "    |$_|" -ForegroundColor DarkGray }
}

# Also confirm the two words were NOT merged (i.e. "helloworld" is absent or "hello world" is present)
Write-Host "`n[Test 2] 'helloworld' (merged, no space) does NOT appear" -ForegroundColor Yellow
if ($cap -notmatch "helloworld") {
    Write-Pass "'helloworld' absent — words were not merged due to missing space"
} else {
    Write-Fail "'helloworld' found — space was dropped, words merged"
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
    Write-Host "`n  VERDICT: VERIFIED_BROKEN — space key still not delivered" -ForegroundColor Red
} else {
    Write-Host "`n  VERDICT: PASS — space key delivered correctly" -ForegroundColor Green
}

exit $script:fail
