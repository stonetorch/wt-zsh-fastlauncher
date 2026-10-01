# Issue #32: How to unbind Ctrl+Q (quit)? `unbind C-q` doesn't work
# Fix: unbind-key C-q (and unbind generally) removes the binding from list-keys.
#
# This test proves:
#   1. C-q (or a freshly bound key) appears in list-keys BEFORE unbind
#   2. unbind-key <key> executes without error
#   3. list-keys AFTER unbind-key shows the binding is GONE
#   4. Both CLI and TCP paths remove the binding correctly
#   5. The exact user config scenario (unbind C-b, unbind C-q, set prefix C-a) works

$ErrorActionPreference = "Continue"
$PSMUX    = (Get-Command psmux -EA Stop).Source
$SESSION  = "gap32"
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
    param([string]$Sess, [string]$Cmd, [int]$TimeoutMs = 5000)
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

# Read all lines from a TCP multi-line response (list-keys, etc.)
function Send-TcpCommandMultiLine {
    param([string]$Sess, [string]$Cmd, [int]$TimeoutMs = 3000)
    $portFile = "$psmuxDir\$Sess.port"
    $keyFile  = "$psmuxDir\$Sess.key"
    if (-not (Test-Path $portFile) -or -not (Test-Path $keyFile)) { return @() }
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
        if ($authResp -ne "OK") { $tcp.Close(); return @() }
        $writer.Write("$Cmd`n"); $writer.Flush()
        $lines = [System.Collections.Generic.List[string]]::new()
        try {
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                $lines.Add($line)
            }
        } catch { }
        $tcp.Close()
        return $lines.ToArray()
    } catch {
        return @()
    }
}

# Returns $true if the given key name appears in list-keys -T prefix output
function Key-IsInListKeys {
    param([string]$Sess, [string]$KeyName)
    $lines = & $PSMUX list-keys -t $Sess 2>&1
    $escaped = [regex]::Escape($KeyName)
    return ($lines | Where-Object { $_ -match "\bprefix\b" -and $_ -match "\b$escaped\b" }).Count -gt 0
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

Write-Host "`n=== Issue #32: unbind-key C-q removes the binding ===" -ForegroundColor Cyan

# ── Part A: Bind a test key then unbind it (CLI path) ─────────────────────────
Write-Host "`n--- Part A: CLI path - bind then unbind ---" -ForegroundColor Magenta

# [Test 1] Bind a known key so we can reliably verify unbind
Write-Host "`n[Test 1] bind-key M-F1 new-window (creates binding we will unbind)" -ForegroundColor Yellow
& $PSMUX bind-key -t $SESSION "M-F1" new-window 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$present = Key-IsInListKeys -Sess $SESSION -KeyName "M-F1"
if ($present) {
    Write-Pass "M-F1 binding created and visible in list-keys"
} else {
    Write-Fail "M-F1 binding NOT found in list-keys after bind-key"
}

# [Test 2] unbind-key M-F1 executes without error
Write-Host "`n[Test 2] unbind-key M-F1 executes without error" -ForegroundColor Yellow
$out = & $PSMUX unbind-key -t $SESSION "M-F1" 2>&1 | Out-String
$ec  = $LASTEXITCODE
Write-Host "  exit=$ec  output='$($out.Trim())'" -ForegroundColor DarkGray
if ($ec -eq 0 -and $out -notmatch "error|ERR|unknown") {
    Write-Pass "unbind-key M-F1 succeeded (exit 0)"
} else {
    Write-Fail "unbind-key M-F1 returned exit=$ec or error: '$($out.Trim())'"
}

# [Test 3] CORE: list-keys after unbind shows binding is GONE
Write-Host "`n[Test 3] CORE: list-keys shows M-F1 is GONE after unbind-key" -ForegroundColor Yellow
Start-Sleep -Milliseconds 400
$goneNow = Key-IsInListKeys -Sess $SESSION -KeyName "M-F1"
if (-not $goneNow) {
    Write-Pass "VERIFIED: M-F1 is no longer in list-keys after unbind-key"
} else {
    Write-Fail "BROKEN: M-F1 still present in list-keys after unbind-key"
}

# ── Part B: Unbind C-q (exact issue scenario) ─────────────────────────────────
Write-Host "`n--- Part B: C-q exact issue scenario ---" -ForegroundColor Magenta

# C-q is a default binding (quit). First confirm it exists, then unbind.
Write-Host "`n[Test 4] C-q exists in default list-keys" -ForegroundColor Yellow
# Recreate a fresh session so defaults are present
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
if (-not (Wait-PortFile $SESSION)) { Write-Fail "Recreated session port never appeared"; exit 1 }
Start-Sleep -Milliseconds 600

$allKeys = & $PSMUX list-keys -t $SESSION 2>&1
Write-Host "  Total list-keys lines: $($allKeys.Count)" -ForegroundColor DarkGray
$cqLines = @($allKeys | Where-Object { $_ -match "\bC-q\b" })
Write-Host "  C-q lines: $($cqLines.Count)" -ForegroundColor DarkGray
foreach ($l in $cqLines) { Write-Host "    $l" -ForegroundColor DarkGray }

if ($cqLines.Count -gt 0) {
    Write-Pass "C-q is present in default list-keys ($($cqLines.Count) entries)"
} else {
    # C-q may not be a default prefix binding but the unbind test is still valid
    # - bind it first so we can verify unbind
    Write-Host "  C-q not in defaults; binding it for unbind test" -ForegroundColor DarkGray
    & $PSMUX bind-key -t $SESSION "C-q" new-window 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $cqLines = @(& $PSMUX list-keys -t $SESSION 2>&1 | Where-Object { $_ -match "\bC-q\b" })
    if ($cqLines.Count -gt 0) {
        Write-Pass "C-q bound manually and visible in list-keys (for unbind test)"
    } else {
        Write-Fail "Could not establish C-q binding to test unbind"
    }
}

# [Test 5] unbind-key C-q removes it
Write-Host "`n[Test 5] unbind-key C-q removes C-q from list-keys" -ForegroundColor Yellow
$out = & $PSMUX unbind-key -t $SESSION "C-q" 2>&1 | Out-String
$ec  = $LASTEXITCODE
Write-Host "  exit=$ec  output='$($out.Trim())'" -ForegroundColor DarkGray
Start-Sleep -Milliseconds 400

$cqAfter = @(& $PSMUX list-keys -t $SESSION 2>&1 | Where-Object { $_ -match "\bC-q\b" })
Write-Host "  C-q lines after unbind: $($cqAfter.Count)" -ForegroundColor DarkGray

if ($cqAfter.Count -eq 0) {
    Write-Pass "VERIFIED: C-q is GONE from list-keys after unbind-key C-q"
} else {
    Write-Fail "BROKEN: C-q still in list-keys after unbind-key C-q: $($cqAfter -join '; ')"
}

# ── Part C: TCP path ──────────────────────────────────────────────────────────
Write-Host "`n--- Part C: TCP path - bind then unbind ---" -ForegroundColor Magenta

# Recreate clean session
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
if (-not (Wait-PortFile $SESSION)) { Write-Fail "TCP session port never appeared"; exit 1 }
Start-Sleep -Milliseconds 600

# [Test 6] Bind via TCP then unbind via TCP, verify gone
Write-Host "`n[Test 6] TCP: bind-key F9 then unbind-key F9 removes binding" -ForegroundColor Yellow
$r1 = Send-TcpCommand -Sess $SESSION -Cmd "bind-key F9 new-window"
Start-Sleep -Milliseconds 400
$tcpBefore = @(Send-TcpCommandMultiLine -Sess $SESSION -Cmd "list-keys" | Where-Object { $_ -match "\bF9\b" })
Write-Host "  After bind: F9 lines=$($tcpBefore.Count)  bind resp='$r1'" -ForegroundColor DarkGray

$r2 = Send-TcpCommand -Sess $SESSION -Cmd "unbind-key F9"
Start-Sleep -Milliseconds 400
$tcpAfter = @(Send-TcpCommandMultiLine -Sess $SESSION -Cmd "list-keys" | Where-Object { $_ -match "\bF9\b" })
Write-Host "  After unbind: F9 lines=$($tcpAfter.Count)  unbind resp='$r2'" -ForegroundColor DarkGray

if ($tcpBefore.Count -gt 0 -and $tcpAfter.Count -eq 0) {
    Write-Pass "TCP: F9 present after bind, gone after unbind-key F9"
} elseif ($tcpBefore.Count -eq 0) {
    Write-Fail "TCP: F9 binding never appeared after bind-key (cannot test unbind)"
} else {
    Write-Fail "TCP BROKEN: F9 still in list-keys after unbind-key F9 ($($tcpAfter.Count) lines)"
}

# ── Part D: Config file path (exact user scenario from issue) ─────────────────
Write-Host "`n--- Part D: Config file path (exact issue #32 scenario) ---" -ForegroundColor Magenta

$SESSION_CFG = "gap32cfg"
& $PSMUX kill-session -t $SESSION_CFG 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\$SESSION_CFG.*" -Force -EA SilentlyContinue

$confFile = "$env:TEMP\psmux_test_32.conf"
@'
set -g prefix C-a
unbind C-b
unbind C-q
bind C-a send-prefix
'@ | Set-Content -Path $confFile -Encoding UTF8

Write-Host "`n[Test 7] Config with unbind C-q: C-q absent from list-keys after load" -ForegroundColor Yellow
$env:PSMUX_CONFIG_FILE = $confFile
& $PSMUX new-session -d -s $SESSION_CFG 2>&1 | Out-Null
$env:PSMUX_CONFIG_FILE = $null
if (-not (Wait-PortFile $SESSION_CFG 12)) {
    Write-Fail "Config session '$SESSION_CFG' port never appeared"
} else {
    # Poll up to 5s for config to fully apply (config execution is async)
    $deadline2 = [DateTime]::Now.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 400
        $cfgKeys = & $PSMUX list-keys -t $SESSION_CFG 2>&1
        $cbInCfg = @($cfgKeys | Where-Object { $_ -match "\bC-b\b" -and $_ -match "\bprefix\b" })
        if ($cbInCfg.Count -eq 0) { break }
    } while ([DateTime]::Now -lt $deadline2)
    $cqInCfg = @($cfgKeys | Where-Object { $_ -match "\bC-q\b" })
    Write-Host "  C-q lines in config session: $($cqInCfg.Count)" -ForegroundColor DarkGray
    Write-Host "  C-b prefix lines in config session: $($cbInCfg.Count)" -ForegroundColor DarkGray

    if ($cqInCfg.Count -eq 0) {
        Write-Pass "Config session: C-q unbound successfully (not in list-keys)"
    } else {
        Write-Fail "Config session: C-q still present after config unbind C-q: $($cqInCfg -join '; ')"
    }

    if ($cbInCfg.Count -eq 0) {
        Write-Pass "Config session: C-b prefix binding also unbound correctly"
    } else {
        Write-Fail "Config session: C-b still in prefix table after unbind C-b"
    }

    & $PSMUX kill-session -t $SESSION_CFG 2>&1 | Out-Null
    Remove-Item "$psmuxDir\$SESSION_CFG.*" -Force -EA SilentlyContinue
}
Remove-Item $confFile -Force -EA SilentlyContinue

# ── Teardown ──────────────────────────────────────────────────────────────────
Cleanup

Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "RESULTS  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""

exit $script:TestsFailed
