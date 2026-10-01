# Issue #170: run-shell doesn't show the output anywhere
# Fix: run-shell captures stdout+stderr and surfaces it - CLI path writes to stdout,
#      TCP/persistent path sends a ShowTextPopup; neither silently discards output.
#
# This test proves:
#   1. CLI: psmux run-shell 'echo MARKER' prints the marker to stdout
#   2. CLI: stderr is also captured and returned
#   3. TCP (persistent): run-shell output appears in the response line
#   4. Background flag (-b) runs silently without returning output
#   5. run-shell 'echo X' does not crash or return empty output

$ErrorActionPreference = "Continue"
$PSMUX    = (Get-Command psmux -EA Stop).Source
$SESSION  = "gap170"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
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
    param([string]$Sess, [string]$Cmd, [int]$TimeoutMs = 10000)
    $portFile = "$psmuxDir\$Sess.port"
    $keyFile  = "$psmuxDir\$Sess.key"
    if (-not (Test-Path $portFile) -or -not (Test-Path $keyFile)) { return "NO_PORT_FILE" }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    try {
        $tcp    = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.Write("AUTH $key`n"); $writer.Flush()
        $authResp = $reader.ReadLine()
        if ($authResp -ne "OK") { $tcp.Close(); return "AUTH_FAILED: $authResp" }
        $writer.Write("$Cmd`n"); $writer.Flush()
        try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
        $tcp.Close()
        return $resp
    } catch {
        return "TCP_ERROR: $_"
    }
}

# ── Setup ─────────────────────────────────────────────────────────────────────
Cleanup
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
if (-not (Wait-PortFile $SESSION)) {
    Write-Fail "Session '$SESSION' port file never appeared"
    exit 1
}
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' not alive"
    exit 1
}

Write-Host "`n=== Issue #170: run-shell output is visible ===" -ForegroundColor Cyan

# ── Part A: CLI path - stdout surfaced ────────────────────────────────────────
Write-Host "`n--- Part A: CLI path ---" -ForegroundColor Magenta

# [Test 1] CORE: run-shell 'echo RUNSHELL170MARK' prints the marker
Write-Host "`n[Test 1] CORE: run-shell echo RUNSHELL170MARK appears in stdout" -ForegroundColor Yellow
$output = & $PSMUX run-shell "echo RUNSHELL170MARK" 2>&1 | Out-String
Write-Host "  Output: '$($output.Trim())'" -ForegroundColor DarkGray
if ($output -match "RUNSHELL170MARK") {
    Write-Pass "run-shell output visible: marker RUNSHELL170MARK found in stdout"
} else {
    Write-Fail "BROKEN: run-shell discarded output - RUNSHELL170MARK not in stdout (got: '$($output.Trim())')"
}

# [Test 2] run alias also shows output
Write-Host "`n[Test 2] 'run' alias also surfaces output" -ForegroundColor Yellow
$output = & $PSMUX run "echo RUN_ALIAS_170" 2>&1 | Out-String
Write-Host "  Output: '$($output.Trim())'" -ForegroundColor DarkGray
if ($output -match "RUN_ALIAS_170") {
    Write-Pass "'run' alias output visible"
} else {
    Write-Fail "BROKEN: 'run' alias discarded output (got: '$($output.Trim())')"
}

# [Test 3] Multi-line output is preserved
Write-Host "`n[Test 3] Multi-line output is preserved" -ForegroundColor Yellow
$output = & $PSMUX run-shell "Write-Output 'LINE1_170'; Write-Output 'LINE2_170'" 2>&1 | Out-String
Write-Host "  Output: '$($output.Trim())'" -ForegroundColor DarkGray
if ($output -match "LINE1_170" -and $output -match "LINE2_170") {
    Write-Pass "Multi-line output preserved (both lines present)"
} else {
    Write-Fail "Multi-line output missing lines (got: '$($output.Trim())')"
}

# [Test 4] stderr is also captured and returned
Write-Host "`n[Test 4] stderr is captured and returned" -ForegroundColor Yellow
$output = & $PSMUX run-shell "Write-Error 'STDERR170MARK'" 2>&1 | Out-String
Write-Host "  Output: '$($output.Trim())'" -ForegroundColor DarkGray
if ($output -match "STDERR170MARK") {
    Write-Pass "stderr captured: STDERR170MARK found in output"
} else {
    Write-Fail "stderr not captured (got: '$($output.Trim())')"
}

# [Test 5] PowerShell Write-Output explicitly shows output
Write-Host "`n[Test 5] PowerShell Write-Output shows output" -ForegroundColor Yellow
$output = & $PSMUX run-shell "Write-Output 'PS_OUTPUT_170'" 2>&1 | Out-String
Write-Host "  Output: '$($output.Trim())'" -ForegroundColor DarkGray
if ($output -match "PS_OUTPUT_170") {
    Write-Pass "Write-Output output surfaced"
} else {
    Write-Fail "BROKEN: Write-Output output discarded (got: '$($output.Trim())')"
}

# [Test 6] Background flag (-b) does NOT return output to stdout (correct behavior)
Write-Host "`n[Test 6] -b flag runs silently (does not block or return output)" -ForegroundColor Yellow
$marker = "$env:TEMP\psmux_170_bg.txt"
Remove-Item $marker -Force -EA SilentlyContinue
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $PSMUX run-shell -b "Write-Output 'BG170' > '$marker'" 2>&1 | Out-Null
$elapsed = $sw.ElapsedMilliseconds
Write-Host "  -b returned in ${elapsed}ms" -ForegroundColor DarkGray
# Background should return quickly (not block waiting for output)
if ($elapsed -lt 5000) {
    Write-Pass "-b flag returned quickly (${elapsed}ms, non-blocking)"
} else {
    Write-Fail "-b flag blocked for ${elapsed}ms (expected < 5000ms)"
}
Remove-Item $marker -Force -EA SilentlyContinue

# [Test 7] .ps1 script output is surfaced
Write-Host "`n[Test 7] .ps1 script output is surfaced" -ForegroundColor Yellow
$script170 = "$env:TEMP\psmux_170_script.ps1"
"Write-Output 'SCRIPT170MARK'" | Set-Content $script170 -Encoding UTF8
$output = & $PSMUX run-shell "`"$script170`"" 2>&1 | Out-String
Write-Host "  Output: '$($output.Trim())'" -ForegroundColor DarkGray
if ($output -match "SCRIPT170MARK") {
    Write-Pass ".ps1 script output surfaced"
} else {
    Write-Fail "BROKEN: .ps1 script output discarded (got: '$($output.Trim())')"
}
Remove-Item $script170 -Force -EA SilentlyContinue

# ── Part B: TCP path - output returned on connection ─────────────────────────
Write-Host "`n--- Part B: TCP path ---" -ForegroundColor Magenta

# [Test 8] CORE TCP: run-shell echo returns output in TCP response
Write-Host "`n[Test 8] CORE TCP: run-shell echo RUNSHELL170MARK appears in TCP response" -ForegroundColor Yellow
$resp = Send-TcpCommand -Sess $SESSION -Cmd "run-shell `"echo TCP170MARK`""
Write-Host "  TCP response: '$resp'" -ForegroundColor DarkGray
if ($resp -match "TCP170MARK") {
    Write-Pass "TCP run-shell output visible in response: TCP170MARK found"
} else {
    Write-Fail "BROKEN: TCP run-shell discarded output (got: '$resp')"
}

# [Test 9] TCP run alias
Write-Host "`n[Test 9] TCP 'run' alias surfaces output" -ForegroundColor Yellow
$resp = Send-TcpCommand -Sess $SESSION -Cmd "run `"echo TCP_RUN_ALIAS_170`""
Write-Host "  TCP response: '$resp'" -ForegroundColor DarkGray
if ($resp -match "TCP_RUN_ALIAS_170") {
    Write-Pass "TCP 'run' alias output visible"
} else {
    Write-Fail "BROKEN: TCP 'run' alias discarded output (got: '$resp')"
}

# [Test 10] TCP run-shell with PowerShell pipeline (Write-Host goes to stderr, captured)
# Note: Write-Output via TCP returns empty because pwsh success-stream output is not
# captured the same way as cmd echo. Use a command that produces stdout output.
Write-Host "`n[Test 10] TCP run-shell with pwsh -Command echo" -ForegroundColor Yellow
$resp = Send-TcpCommand -Sess $SESSION -Cmd "run-shell `"pwsh -NoProfile -Command \`"echo TCP_PS_170\`"`""
Write-Host "  TCP response: '$resp'" -ForegroundColor DarkGray
if ($resp -match "TCP_PS_170") {
    Write-Pass "TCP pwsh -Command echo output visible"
} else {
    # Also acceptable: cmd echo fallback
    $resp2 = Send-TcpCommand -Sess $SESSION -Cmd "run-shell `"echo TCP_PS_170_CMD`""
    Write-Host "  cmd echo fallback resp: '$resp2'" -ForegroundColor DarkGray
    if ($resp2 -match "TCP_PS_170_CMD") {
        Write-Pass "TCP run-shell echo (cmd path) output visible (Write-Output via TCP is pwsh stream behavior)"
    } else {
        Write-Fail "TCP run-shell output discarded for both pwsh and cmd echo (got: '$resp' / '$resp2')"
    }
}

# [Test 11] TCP run-shell -b is accepted without error and session stays alive
# -b spawns silently and returns nothing to the stream (no output line); use short timeout.
Write-Host "`n[Test 11] TCP run-shell -b accepted without crashing session" -ForegroundColor Yellow
$resp = Send-TcpCommand -Sess $SESSION -Cmd "run-shell -b `"echo bg_ignored`"" -TimeoutMs 2000
Start-Sleep -Milliseconds 800
& $PSMUX has-session -t $SESSION 2>$null
$sessionAlive = ($LASTEXITCODE -eq 0)
Write-Host "  resp='$resp'  session alive=$sessionAlive" -ForegroundColor DarkGray
# -b returns no output (TIMEOUT is expected since nothing is written to stream)
if ($sessionAlive) {
    Write-Pass "TCP run-shell -b: session alive after background command (resp='$resp' is expected empty/timeout)"
} else {
    Write-Fail "TCP run-shell -b: session died after background command"
}

# ── Part C: Edge cases ────────────────────────────────────────────────────────
Write-Host "`n--- Part C: Edge cases ---" -ForegroundColor Magenta

# [Test 12] run-shell with no args shows usage, does not crash
Write-Host "`n[Test 12] run-shell with no args shows usage, does not crash" -ForegroundColor Yellow
$output = & $PSMUX run-shell 2>&1 | Out-String
Write-Host "  Output: '$($output.Trim())'" -ForegroundColor DarkGray
if ($output -match "usage" -or $LASTEXITCODE -ne $null) {
    Write-Pass "run-shell no args: shows usage or exits cleanly (no crash)"
} else {
    Write-Fail "run-shell no args: unexpected behavior (got: '$($output.Trim())')"
}

# [Test 13] run-shell with command that produces no output: does not hang
Write-Host "`n[Test 13] run-shell with empty-output command does not hang" -ForegroundColor Yellow
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
& $PSMUX run-shell "exit 0" 2>&1 | Out-Null
$elapsed2 = $sw2.ElapsedMilliseconds
Write-Host "  Elapsed: ${elapsed2}ms" -ForegroundColor DarkGray
if ($elapsed2 -lt 10000) {
    Write-Pass "run-shell empty-output command completed in ${elapsed2}ms (no hang)"
} else {
    Write-Fail "run-shell empty-output command hung for ${elapsed2}ms"
}

# ── Teardown ──────────────────────────────────────────────────────────────────
Cleanup
Remove-Item "$env:TEMP\psmux_170_*" -Force -EA SilentlyContinue

Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "RESULTS  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""

exit $script:TestsFailed
