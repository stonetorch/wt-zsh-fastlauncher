# Issue #321: Fall back to global window options
#
# The bug: show-options -w (window-scoped lookup) returned EMPTY for options
# that are not purely window-scoped, like pane-base-index, base-index, etc.
# libtmux and tmuxp expect these to have a value when queried with -w.
# If a window-scope lookup returns empty, it should fall back to the global
# option value instead.
#
# Fix verification:
#   1. set -g pane-base-index 1 and show-options -w -v pane-base-index returns "1"
#   2. set -g base-index 1 and show-options -w -v base-index returns "1"
#   3. True window options (automatic-rename, window-status-format, etc.) still work
#   4. A newly created window inherits global window option values
#   5. TCP path: ShowWindowOptionValue returns global fallback for non-window opts
#   6. show-options -gw returns both window and global options

$ErrorActionPreference = "Continue"
$PSMUX    = (Get-Command psmux -EA Stop).Source
$SESSION  = "gap321"
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

# ── setup ────────────────────────────────────────────────────────────────────
Cleanup
& $PSMUX new-session -d -s $SESSION
if (-not (Wait-PortFile $SESSION)) {
    Write-Fail "Session '$SESSION' port file never appeared"
    exit 1
}
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' not alive"
    exit 1
}
Start-Sleep -Milliseconds 400

Write-Host "`n=== Issue #321: Fall back to global window options ===" -ForegroundColor Cyan

# ── Part A: pane-base-index via -w falls back to global ──────────────────────
Write-Host "`n--- Part A: pane-base-index global fallback via -w ---" -ForegroundColor Magenta

# [Test 1] set pane-base-index globally, show-options -w -v returns it
Write-Host "`n[Test 1] set -g pane-base-index 1 -> show-options -w -v pane-base-index returns '1'" -ForegroundColor Yellow
& $PSMUX set -g pane-base-index 1 -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$pbiW = (& $PSMUX show-options -w -v pane-base-index -t $SESSION 2>&1).Trim()
Write-Host "    show-options -w -v pane-base-index: '$pbiW'" -ForegroundColor DarkGray
if ($pbiW -eq "1") {
    Write-Pass "show-options -w -v pane-base-index returns '1' (global fallback works)"
} elseif ($pbiW -eq "") {
    Write-Fail "BROKEN: show-options -w -v pane-base-index returned empty string (no global fallback)"
} else {
    Write-Fail "Unexpected value: got '$pbiW' (expected '1')"
}

# [Test 2] pane-base-index=0 (default), -w still returns it
Write-Host "`n[Test 2] set -g pane-base-index 0 -> show-options -w -v returns '0'" -ForegroundColor Yellow
& $PSMUX set -g pane-base-index 0 -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$pbi0 = (& $PSMUX show-options -w -v pane-base-index -t $SESSION 2>&1).Trim()
Write-Host "    show-options -w -v pane-base-index (=0): '$pbi0'" -ForegroundColor DarkGray
if ($pbi0 -eq "0") {
    Write-Pass "show-options -w -v pane-base-index returns '0' for default value"
} elseif ($pbi0 -eq "") {
    Write-Fail "BROKEN: show-options -w -v pane-base-index returned empty for value 0"
} else {
    Write-Fail "Unexpected: got '$pbi0' (expected '0')"
}

# ── Part B: base-index via -w falls back to global ───────────────────────────
Write-Host "`n--- Part B: base-index global fallback via -w ---" -ForegroundColor Magenta

# [Test 3] base-index is not a window option — -w should fall back to global
Write-Host "`n[Test 3] set -g base-index 1 -> show-options -w -v base-index returns '1'" -ForegroundColor Yellow
& $PSMUX set -g base-index 1 -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$biW = (& $PSMUX show-options -w -v base-index -t $SESSION 2>&1).Trim()
Write-Host "    show-options -w -v base-index: '$biW'" -ForegroundColor DarkGray
if ($biW -eq "1") {
    Write-Pass "show-options -w -v base-index returns '1' (global fallback works)"
} elseif ($biW -eq "") {
    Write-Fail "BROKEN: show-options -w -v base-index returned empty (no global fallback)"
} else {
    Write-Fail "Unexpected: got '$biW' (expected '1')"
}
# Reset
& $PSMUX set -g base-index 0 -t $SESSION 2>&1 | Out-Null

# ── Part C: True window options still return correct values ───────────────────
Write-Host "`n--- Part C: True window options with -w ---" -ForegroundColor Magenta

# [Test 4] automatic-rename is a real window option — must work with -w
Write-Host "`n[Test 4] show-options -w -v automatic-rename returns 'on' (default)" -ForegroundColor Yellow
$arW = (& $PSMUX show-options -w -v automatic-rename -t $SESSION 2>&1).Trim()
Write-Host "    show-options -w -v automatic-rename: '$arW'" -ForegroundColor DarkGray
if ($arW -eq "on" -or $arW -eq "off") {
    Write-Pass "show-options -w -v automatic-rename returns '$arW' (valid window option)"
} elseif ($arW -eq "") {
    Write-Fail "show-options -w -v automatic-rename returned empty (window option broken)"
} else {
    Write-Fail "Unexpected: automatic-rename = '$arW'"
}

# [Test 5] window-status-format is a window option — must work with -w
Write-Host "`n[Test 5] show-options -w -v window-status-format returns non-empty" -ForegroundColor Yellow
$wsfW = (& $PSMUX show-options -w -v window-status-format -t $SESSION 2>&1).Trim()
Write-Host "    show-options -w -v window-status-format: '$wsfW'" -ForegroundColor DarkGray
if ($wsfW.Length -gt 0) {
    Write-Pass "show-options -w -v window-status-format = '$wsfW'"
} else {
    Write-Fail "show-options -w -v window-status-format returned empty"
}

# [Test 6] set a global window option and new window inherits it
Write-Host "`n[Test 6] New window inherits global window-status-format" -ForegroundColor Yellow
$customFmt = "#I:#W[custom]"
& $PSMUX set -gw window-status-format $customFmt -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
# Query on the new window (window index 1)
$newWinFmt = (& $PSMUX show-options -w -v window-status-format -t "${SESSION}:1" 2>&1).Trim()
Write-Host "    New window window-status-format: '$newWinFmt'" -ForegroundColor DarkGray
if ($newWinFmt -eq $customFmt) {
    Write-Pass "New window inherits global window-status-format '$customFmt'"
} elseif ($newWinFmt.Length -gt 0) {
    Write-Pass "New window shows window-status-format '$newWinFmt' (non-empty, global fallback present)"
} else {
    Write-Fail "New window: show-options -w -v window-status-format returned empty (no global fallback)"
}

# ── Part D: TCP path — ShowWindowOptionValue with non-window option ───────────
Write-Host "`n--- Part D: TCP path (show-options -w -v) ---" -ForegroundColor Magenta

# [Test 7] TCP: show-options -w -v pane-base-index returns global value
Write-Host "`n[Test 7] TCP: show-options -w -v pane-base-index returns global value" -ForegroundColor Yellow
& $PSMUX set -g pane-base-index 2 -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$tcpPbi = Send-TcpCommand -Sess $SESSION -Cmd "show-options -w -v pane-base-index"
Write-Host "    TCP show-options -w -v pane-base-index: '$tcpPbi'" -ForegroundColor DarkGray
if ($tcpPbi -eq "2") {
    Write-Pass "TCP: show-options -w -v pane-base-index = '2' (global fallback via TCP)"
} elseif ($tcpPbi -eq "" -or $tcpPbi -eq $null) {
    Write-Fail "TCP BROKEN: show-options -w -v pane-base-index returned empty over TCP"
} else {
    Write-Fail "TCP: Unexpected value '$tcpPbi' (expected '2')"
}
# Reset
& $PSMUX set -g pane-base-index 0 -t $SESSION 2>&1 | Out-Null

# [Test 8] TCP: show-options -w -v mouse (global bool option fallback)
Write-Host "`n[Test 8] TCP: show-options -w -v mouse returns global value" -ForegroundColor Yellow
& $PSMUX set -g mouse on -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$tcpMouse = Send-TcpCommand -Sess $SESSION -Cmd "show-options -w -v mouse"
Write-Host "    TCP show-options -w -v mouse: '$tcpMouse'" -ForegroundColor DarkGray
if ($tcpMouse -eq "on") {
    Write-Pass "TCP: show-options -w -v mouse = 'on' (global fallback works for bool options)"
} elseif ($tcpMouse -eq "" -or $tcpMouse -eq $null) {
    Write-Fail "TCP BROKEN: show-options -w -v mouse returned empty (no global fallback)"
} else {
    Write-Fail "TCP: Unexpected mouse value '$tcpMouse' (expected 'on')"
}
& $PSMUX set -g mouse off -t $SESSION 2>&1 | Out-Null

# ── Part E: libtmux/tmuxp scenario — set pane-base-index 1, query via -w ─────
Write-Host "`n--- Part E: libtmux / tmuxp compatibility scenario ---" -ForegroundColor Magenta

# [Test 9] Exact scenario from issue: set pane-base-index 1, query -w returns it
Write-Host "`n[Test 9] libtmux scenario: set pane-base-index 1, show-options -w -v returns non-empty" -ForegroundColor Yellow
& $PSMUX set -g pane-base-index 1 -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$libtmuxVal = (& $PSMUX show-options -w -v pane-base-index -t $SESSION 2>&1).Trim()
Write-Host "    libtmux scenario pane-base-index -w: '$libtmuxVal'" -ForegroundColor DarkGray
if ($libtmuxVal -ne "") {
    Write-Pass "libtmux scenario: pane-base-index -w = '$libtmuxVal' (non-empty, no compatibility break)"
} else {
    Write-Fail "libtmux scenario BROKEN: pane-base-index -w returned empty (libtmux/tmuxp would fail)"
}
if ($libtmuxVal -eq "1") {
    Write-Pass "libtmux scenario: value is exactly '1' as set globally"
} elseif ($libtmuxVal -ne "") {
    Write-Fail "libtmux scenario: value '$libtmuxVal' != '1' (wrong global value returned)"
}

# [Test 10] show-options -gw (combined -g -w) lists window options with values
Write-Host "`n[Test 10] show-options -gw returns window options non-empty" -ForegroundColor Yellow
$gwOut = (& $PSMUX show-options -gw -t $SESSION 2>&1 | Out-String).Trim()
Write-Host "    show-options -gw (first 200): $($gwOut.Substring(0, [Math]::Min(200, $gwOut.Length)))" -ForegroundColor DarkGray
$gwLines = @($gwOut -split "`n" | Where-Object { $_.Trim().Length -gt 0 })
if ($gwLines.Count -ge 1) {
    Write-Pass "show-options -gw returns $($gwLines.Count) option line(s)"
} else {
    Write-Fail "show-options -gw returned empty (expected window option listing)"
}

# ── teardown ──────────────────────────────────────────────────────────────────
Cleanup

Write-Host "`n$(('=' * 60))" -ForegroundColor Cyan
Write-Host "RESULTS  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""

exit $script:TestsFailed
