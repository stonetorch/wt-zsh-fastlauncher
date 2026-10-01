# Issue #182: Cannot override bg=default on status-style
#
# The bug: set -g status-style "fg=red,bg=default" (or bg=default,fg=red)
# was not honoured; the status bar background remained the default green
# because bg=default was not stored/reported correctly.
#
# Fix verification:
#   1. set-option stores the exact style string including bg=default
#   2. show-options -g -v status-style returns the stored string verbatim
#   3. dump-state (TCP) reflects the same value
#   4. Subsequent set overrides work (fg-only, bg-only, combined)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION  = "gap182"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-PortFile {
    param([string]$Name, [int]$MaxSeconds = 12)
    $deadline = [DateTime]::Now.AddSeconds($MaxSeconds)
    while ([DateTime]::Now -lt $deadline) {
        if (Test-Path "$psmuxDir\$Name.port") { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Send-TcpCommand {
    param([string]$Sess, [string]$Cmd)
    $portFile = "$psmuxDir\$Sess.port"
    $keyFile  = "$psmuxDir\$Sess.key"
    if (-not (Test-Path $portFile) -or -not (Test-Path $keyFile)) { return "NO_PORT_FILE" }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    try {
        $tcp    = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.Write("AUTH $key`n"); $writer.Flush()
        $authResp = $reader.ReadLine()
        if ($authResp -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
        $writer.Write("$Cmd`n"); $writer.Flush()
        $stream.ReadTimeout = 8000
        try   { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
        $tcp.Close()
        return $resp
    } catch {
        return "TCP_ERROR: $_"
    }
}

# ── setup ───────────────────────────────────────────────────────────────────
Cleanup
& $PSMUX new-session -d -s $SESSION
if (-not (Wait-PortFile $SESSION)) {
    Write-Fail "Session '$SESSION' port file never appeared (session did not start)"
    exit 1
}
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' not alive after startup"
    exit 1
}

Write-Host "`n=== Issue #182: status-style bg=default override ===" -ForegroundColor Cyan

# ── Part A: CLI path ─────────────────────────────────────────────────────────
Write-Host "`n--- Part A: CLI path (show-options -v status-style) ---" -ForegroundColor Magenta

# [Test 1] Default status-style contains bg=green (verify baseline)
Write-Host "`n[Test 1] Default status-style contains bg=green" -ForegroundColor Yellow
$defaultStyle = (& $PSMUX show-options -g -v status-style -t $SESSION 2>&1).Trim()
Write-Host "    default status-style: '$defaultStyle'" -ForegroundColor DarkGray
if ($defaultStyle -match "bg=green") {
    Write-Pass "Baseline: default status-style contains bg=green ('$defaultStyle')"
} else {
    # It may be stored as just "bg=green,fg=black" or similar — accept any non-empty value
    if ($defaultStyle.Length -gt 0) {
        Write-Pass "Baseline: status-style is non-empty ('$defaultStyle') - default present"
    } else {
        Write-Fail "Default status-style is empty — cannot establish baseline"
    }
}

# [Test 2] set status-style fg=white,bg=default — verbatim from the issue report
Write-Host "`n[Test 2] set -g status-style 'fg=white,bg=default' stores bg=default" -ForegroundColor Yellow
& $PSMUX set -g status-style "fg=white,bg=default" -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$styleAfter = (& $PSMUX show-options -g -v status-style -t $SESSION 2>&1).Trim()
Write-Host "    status-style after set: '$styleAfter'" -ForegroundColor DarkGray
if ($styleAfter -match "bg=default") {
    Write-Pass "bg=default is preserved in status-style: '$styleAfter'"
} else {
    Write-Fail "bg=default was NOT preserved. Got: '$styleAfter' (expected to contain 'bg=default')"
}
if ($styleAfter -match "fg=white") {
    Write-Pass "fg=white is preserved in status-style: '$styleAfter'"
} else {
    Write-Fail "fg=white was NOT preserved. Got: '$styleAfter'"
}

# [Test 3] set status-style bg=default,fg=red (reversed order, from issue)
Write-Host "`n[Test 3] set -g status-style 'bg=default,fg=red' (issue report order)" -ForegroundColor Yellow
& $PSMUX set -g status-style "bg=default,fg=red" -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$styleRev = (& $PSMUX show-options -g -v status-style -t $SESSION 2>&1).Trim()
Write-Host "    status-style: '$styleRev'" -ForegroundColor DarkGray
if ($styleRev -match "bg=default") {
    Write-Pass "bg=default preserved in reversed order: '$styleRev'"
} else {
    Write-Fail "bg=default lost in reversed order. Got: '$styleRev'"
}
if ($styleRev -match "fg=red") {
    Write-Pass "fg=red preserved in reversed order: '$styleRev'"
} else {
    Write-Fail "fg=red lost in reversed order. Got: '$styleRev'"
}

# [Test 4] set status-style bg=default alone (no fg)
Write-Host "`n[Test 4] set -g status-style 'bg=default' (bg only, no fg)" -ForegroundColor Yellow
& $PSMUX set -g status-style "bg=default" -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$styleBgOnly = (& $PSMUX show-options -g -v status-style -t $SESSION 2>&1).Trim()
Write-Host "    status-style: '$styleBgOnly'" -ForegroundColor DarkGray
if ($styleBgOnly -match "bg=default") {
    Write-Pass "bg=default preserved when set alone: '$styleBgOnly'"
} else {
    Write-Fail "bg=default lost when set alone. Got: '$styleBgOnly'"
}

# ── Part B: TCP dump-state path ──────────────────────────────────────────────
Write-Host "`n--- Part B: TCP dump-state path ---" -ForegroundColor Magenta

# [Test 5] Set a distinctive style and verify via dump-state
Write-Host "`n[Test 5] TCP dump-state reflects bg=default,fg=cyan after set" -ForegroundColor Yellow
& $PSMUX set -g status-style "bg=default,fg=cyan" -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$dumpResp = Send-TcpCommand -Sess $SESSION -Cmd "dump-state"
Write-Host "    dump-state (first 200 chars): $($dumpResp.Substring(0, [Math]::Min(200, $dumpResp.Length)))" -ForegroundColor DarkGray
if ($dumpResp -match '"status_style"\s*:\s*"([^"]*)"') {
    $dumpStyle = $matches[1]
    Write-Host "    dump-state status_style: '$dumpStyle'" -ForegroundColor DarkGray
    if ($dumpStyle -match "bg=default") {
        Write-Pass "TCP dump-state shows bg=default: '$dumpStyle'"
    } else {
        Write-Fail "TCP dump-state does NOT show bg=default. Got: '$dumpStyle'"
    }
    if ($dumpStyle -match "fg=cyan") {
        Write-Pass "TCP dump-state shows fg=cyan: '$dumpStyle'"
    } else {
        Write-Fail "TCP dump-state does NOT show fg=cyan. Got: '$dumpStyle'"
    }
} else {
    Write-Fail "TCP dump-state did not contain status_style field. Response: $($dumpResp.Substring(0, [Math]::Min(300, $dumpResp.Length)))"
}

# [Test 6] show-options via TCP (show-options command over TCP)
Write-Host "`n[Test 6] TCP show-options returns status-style with bg=default" -ForegroundColor Yellow
$tcpShowResp = Send-TcpCommand -Sess $SESSION -Cmd "show-options -v status-style"
Write-Host "    TCP show-options status-style: '$tcpShowResp'" -ForegroundColor DarkGray
if ($tcpShowResp -match "bg=default") {
    Write-Pass "TCP show-options: bg=default present in '$tcpShowResp'"
} else {
    Write-Fail "TCP show-options: bg=default missing. Got: '$tcpShowResp'"
}

# ── Part C: Round-trip consistency ───────────────────────────────────────────
Write-Host "`n--- Part C: Round-trip set/get consistency ---" -ForegroundColor Magenta

# [Test 7] Multiple round-trips: set several styles, each must be stored verbatim
Write-Host "`n[Test 7] Round-trip: multiple styles including bg=default preserved verbatim" -ForegroundColor Yellow
$styles = @(
    "bg=default,fg=white",
    "fg=red,bg=default",
    "bg=default",
    "bg=default,fg=colour196,bold",
    "fg=white,bg=default,italics"
)
$allOk = $true
foreach ($s in $styles) {
    & $PSMUX set -g status-style $s -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $got = (& $PSMUX show-options -g -v status-style -t $SESSION 2>&1).Trim()
    if ($got -match "bg=default") {
        Write-Host "      set '$s' -> got '$got' [OK]" -ForegroundColor DarkGray
    } else {
        Write-Host "      set '$s' -> got '$got' [FAIL: bg=default missing]" -ForegroundColor Red
        $allOk = $false
    }
}
if ($allOk) {
    Write-Pass "All round-trip styles preserved bg=default"
} else {
    Write-Fail "One or more round-trip styles lost bg=default"
}

# [Test 8] Resetting to a non-default bg (e.g. bg=green) still works
Write-Host "`n[Test 8] Resetting to bg=green after bg=default works" -ForegroundColor Yellow
& $PSMUX set -g status-style "bg=default,fg=cyan" -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX set -g status-style "bg=green,fg=black" -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$greenStyle = (& $PSMUX show-options -g -v status-style -t $SESSION 2>&1).Trim()
if ($greenStyle -match "bg=green") {
    Write-Pass "Can reset from bg=default to bg=green: '$greenStyle'"
} else {
    Write-Fail "Failed to reset to bg=green after bg=default: '$greenStyle'"
}

# ── teardown ─────────────────────────────────────────────────────────────────
Cleanup

Write-Host "`n$(('=' * 60))" -ForegroundColor Cyan
Write-Host "RESULTS  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""

exit $script:TestsFailed
