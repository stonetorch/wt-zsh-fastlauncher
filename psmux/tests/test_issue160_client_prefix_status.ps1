#!/usr/bin/env pwsh
# test_issue160_client_prefix_status.ps1
# Issue #160: status-right containing ONLY #{client_prefix} renders correctly.
# When prefix is not active the rendered value must be "0"; after prefix-begin it
# must be "1"; after prefix-end it must clear back to "0".  The empty-false-branch
# bug (is_empty guard) caused the status never to clear.
# https://github.com/psmux/psmux/issues/160

$ErrorActionPreference = 'Continue'
$PSMUX     = (Get-Command psmux -EA Stop).Source
$psmuxDir  = "$env:USERPROFILE\.psmux"
$SESSION   = "gap160"

$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-PortFile {
    param([string]$Name, [int]$TimeoutSec = 12)
    $portFile = "$psmuxDir\$Name.port"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $portFile) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# One-shot TCP command helper (returns the response line)
function Send-TcpCommand {
    param([string]$Cmd)
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw -EA Stop).Trim()
    $key  = (Get-Content "$psmuxDir\$SESSION.key"  -Raw -EA Stop).Trim()
    $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $w = [System.IO.StreamWriter]::new($stream); $w.AutoFlush = $true
    $r = [System.IO.StreamReader]::new($stream)
    $w.WriteLine("AUTH $key")
    $auth = $r.ReadLine()
    if ($auth -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $w.WriteLine($Cmd)
    $stream.ReadTimeout = 8000
    try { $resp = $r.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

# Open a persistent connection and return the handle
function Open-Persistent {
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw -EA Stop).Trim()
    $key  = (Get-Content "$psmuxDir\$SESSION.key"  -Raw -EA Stop).Trim()
    $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 6000
    $stream = $tcp.GetStream()
    $w = [System.IO.StreamWriter]::new($stream); $w.AutoFlush = $true
    $r = [System.IO.StreamReader]::new($stream)
    $w.WriteLine("AUTH $key"); $null = $r.ReadLine()
    $w.WriteLine("PERSISTENT")
    return @{ tcp=$tcp; w=$w; r=$r }
}

# Extract status_right from a dump-state JSON line
function Get-StatusRight {
    param([string]$JsonLine)
    if ($JsonLine -match '"status_right"\s*:\s*"([^"]*)"') { return $matches[1] }
    return $null
}

Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Issue #160: status-right '#{client_prefix}' renders correctly" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# ── Setup ────────────────────────────────────────────────────────────────────
Write-Host "`n[Setup] Creating detached session '$SESSION'..." -ForegroundColor Yellow
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
if (-not (Wait-PortFile -Name $SESSION)) {
    Write-Fail "Port file never appeared — cannot continue"
    exit 1
}
Start-Sleep -Milliseconds 800

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' did not start"
    Cleanup; exit 1
}

# ── Test 1: set-option accepts '#{client_prefix}' as status-right ────────────
Write-Host "`n[Test 1] set-option -g status-right '#{client_prefix}' is accepted" -ForegroundColor Yellow
& $PSMUX set-option -g -t $SESSION status-right '#{client_prefix}' 2>&1 | Out-Null
$exitCode = $LASTEXITCODE
if ($exitCode -eq 0) {
    Write-Pass "set-option returned exit 0 (accepted without error)"
} else {
    Write-Fail "set-option returned exit $exitCode (rejected)"
}

# ── Test 2: show-options confirms the value was stored ───────────────────────
Write-Host "`n[Test 2] show-options reflects status-right = '#{client_prefix}'" -ForegroundColor Yellow
$showOut = (& $PSMUX show-options -g -t $SESSION 2>&1 | Where-Object { $_ -match 'status-right' })
Write-Host "  show-options: $showOut" -ForegroundColor DarkGray
if ($showOut -match 'client_prefix') {
    Write-Pass "show-options confirms status-right contains '#{client_prefix}'"
} else {
    Write-Fail "show-options did not show '#{client_prefix}' in status-right; got: $showOut"
}

# ── Test 3: dump-state status_right field = "0" when prefix is NOT active ────
Write-Host "`n[Test 3] dump-state status_right = '0' when prefix is not active" -ForegroundColor Yellow
Start-Sleep -Milliseconds 400
$resp = Send-TcpCommand -Cmd "dump-state"
$srNoPrefix = Get-StatusRight -JsonLine $resp
Write-Host "  dump-state status_right (no prefix): '$srNoPrefix'" -ForegroundColor DarkGray
if ($srNoPrefix -eq "0") {
    Write-Pass "status_right = '0' with no prefix active (correct)"
} else {
    Write-Fail "status_right = '$srNoPrefix' (expected '0' — no prefix active)"
}

# ── Test 4: after prefix-begin, dump-state status_right = "1" ────────────────
Write-Host "`n[Test 4] After prefix-begin: dump-state status_right = '1'" -ForegroundColor Yellow
$conn = Open-Persistent
$conn.w.WriteLine("prefix-begin")
Start-Sleep -Milliseconds 500

$resp2 = Send-TcpCommand -Cmd "dump-state"
$srWithPrefix = Get-StatusRight -JsonLine $resp2
Write-Host "  dump-state status_right (prefix active): '$srWithPrefix'" -ForegroundColor DarkGray
if ($srWithPrefix -eq "1") {
    Write-Pass "status_right = '1' with prefix active (correct)"
} else {
    Write-Fail "status_right = '$srWithPrefix' (expected '1' — prefix active)"
}

# ── Test 5: after prefix-end, status_right clears back to "0" ────────────────
# THIS is the core of the bug: the is_empty guard would keep the previous "1" value.
Write-Host "`n[Test 5] After prefix-end: dump-state status_right clears to '0' (bug regression)" -ForegroundColor Yellow
$conn.w.WriteLine("prefix-end")
Start-Sleep -Milliseconds 500

$resp3 = Send-TcpCommand -Cmd "dump-state"
$srAfterEnd = Get-StatusRight -JsonLine $resp3
Write-Host "  dump-state status_right (after prefix-end): '$srAfterEnd'" -ForegroundColor DarkGray
if ($srAfterEnd -eq "0") {
    Write-Pass "status_right cleared to '0' after prefix-end (bug fixed)"
} else {
    Write-Fail "status_right = '$srAfterEnd' after prefix-end (expected '0' — is_empty bug may still be present)"
}
$conn.tcp.Close()

# ── Test 6: conditional format #{?client_prefix,P,} — false branch is empty ──
# Issue title says "ONLY #{client_prefix}" but the user's actual config uses a
# conditional whose false branch is "".  Test the conditional form too.
Write-Host "`n[Test 6] Conditional '#{?client_prefix,P,}' false branch renders as empty string" -ForegroundColor Yellow
& $PSMUX set-option -g -t $SESSION status-right '#{?client_prefix,P,}' 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

$resp4 = Send-TcpCommand -Cmd "dump-state"
$srCond = Get-StatusRight -JsonLine $resp4
Write-Host "  dump-state status_right (conditional, no prefix): '$srCond'" -ForegroundColor DarkGray
if ($srCond -eq "") {
    Write-Pass "Conditional false branch = '' (empty) when prefix not active (correct)"
} else {
    Write-Fail "Conditional false branch = '$srCond' (expected '' empty — is_empty bug may still be present)"
}

# Toggle prefix and check the true branch renders, then clears again
$conn2 = Open-Persistent
$conn2.w.WriteLine("prefix-begin")
Start-Sleep -Milliseconds 400
$resp5 = Send-TcpCommand -Cmd "dump-state"
$srCondTrue = Get-StatusRight -JsonLine $resp5
Write-Host "  dump-state status_right (conditional, prefix active): '$srCondTrue'" -ForegroundColor DarkGray
if ($srCondTrue -eq "P") {
    Write-Pass "Conditional true branch = 'P' when prefix active"
} else {
    Write-Fail "Conditional true branch = '$srCondTrue' (expected 'P')"
}

$conn2.w.WriteLine("prefix-end")
Start-Sleep -Milliseconds 400
$resp6 = Send-TcpCommand -Cmd "dump-state"
$srCondClear = Get-StatusRight -JsonLine $resp6
Write-Host "  dump-state status_right (conditional, after prefix-end): '$srCondClear'" -ForegroundColor DarkGray
if ($srCondClear -eq "") {
    Write-Pass "Conditional false branch cleared back to '' after prefix-end (bug regression confirmed fixed)"
} else {
    Write-Fail "Conditional false branch = '$srCondClear' after prefix-end (expected '' — is_empty bug regression)"
}
$conn2.tcp.Close()

# ── Cleanup ──────────────────────────────────────────────────────────────────
Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "======================================================================" -ForegroundColor Cyan
exit $script:TestsFailed
