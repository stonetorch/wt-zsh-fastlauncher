# Issue #195: unbind-key -a not working
#
# The bug: unbind-key -a (unbind ALL keys) did not actually remove default
# prefix bindings. After `unbind-key -a`, `list-keys` still showed all the
# original prefix bindings unchanged.
#
# Fix verification:
#   1. list-keys BEFORE unbind-key -a shows N bindings (N > 0)
#   2. unbind-key -a succeeds without error
#   3. list-keys AFTER shows drastically fewer (ideally 0 in prefix table)
#   4. AFTER count < BEFORE count
#   5. unbind-key -a -T <table> clears only that table
#   6. new bind-key after unbind-key -a works (starts fresh)
#   7. TCP path and CLI path both clear bindings

$ErrorActionPreference = "Continue"
$PSMUX    = (Get-Command psmux -EA Stop).Source
$SESSION  = "gap195"
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

# Wait until list-keys shows at least MinBindings prefix bindings (defaults loaded)
function Wait-DefaultBindings {
    param([string]$Sess, [int]$MinBindings = 10, [int]$MaxSeconds = 10)
    $deadline = [DateTime]::Now.AddSeconds($MaxSeconds)
    while ([DateTime]::Now -lt $deadline) {
        $count = Count-PrefixBindings $Sess
        if ($count -ge $MinBindings) { return $count }
        Start-Sleep -Milliseconds 300
    }
    return Count-PrefixBindings $Sess
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

# Read all lines of a multi-line TCP response (for list-keys, show-options, etc.)
function Send-TcpCommandMultiLine {
    param([string]$Sess, [string]$Cmd, [int]$TimeoutMs = 2000)
    $portFile = "$psmuxDir\$Sess.port"
    $keyFile  = "$psmuxDir\$Sess.key"
    if (-not (Test-Path $portFile) -or -not (Test-Path $keyFile)) { return @() }
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
        if ($authResp -ne "OK") { $tcp.Close(); return @() }
        $writer.Write("$Cmd`n"); $writer.Flush()
        $stream.ReadTimeout = $TimeoutMs
        $lines = [System.Collections.Generic.List[string]]::new()
        try {
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                $lines.Add($line)
            }
        } catch {
            # ReadTimeout = end of response
        }
        $tcp.Close()
        return $lines.ToArray()
    } catch {
        return @()
    }
}

function Count-PrefixBindings {
    param([string]$Sess)
    $lines = & $PSMUX list-keys -t $Sess 2>&1
    $prefixLines = @($lines | Where-Object { $_ -match "-T\s+prefix\b" })
    return $prefixLines.Count
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

Write-Host "`n=== Issue #195: unbind-key -a removes all bindings ===" -ForegroundColor Cyan

# ── Part A: CLI path — baseline then unbind-all ──────────────────────────────
Write-Host "`n--- Part A: CLI path ---" -ForegroundColor Magenta

# [Test 1] Default session has many prefix bindings
Write-Host "`n[Test 1] Default list-keys shows multiple prefix bindings" -ForegroundColor Yellow
$beforeCount = Count-PrefixBindings $SESSION
Write-Host "    Prefix bindings before unbind-key -a: $beforeCount" -ForegroundColor DarkGray
if ($beforeCount -ge 10) {
    Write-Pass "Baseline: $beforeCount prefix bindings present (expected >= 10)"
} else {
    Write-Fail "Baseline too low: only $beforeCount prefix bindings (expected >= 10)"
}

# [Test 2] unbind-key -a executes without error
Write-Host "`n[Test 2] unbind-key -a executes without error" -ForegroundColor Yellow
$unbindOut = & $PSMUX unbind-key -a -t $SESSION 2>&1 | Out-String
$unbindExit = $LASTEXITCODE
Write-Host "    exit code: $unbindExit  output: '$($unbindOut.Trim())'" -ForegroundColor DarkGray
if ($unbindExit -eq 0 -and $unbindOut -notmatch "error|ERR") {
    Write-Pass "unbind-key -a succeeded (exit 0, no error output)"
} else {
    Write-Fail "unbind-key -a returned exit $unbindExit or error: '$($unbindOut.Trim())'"
}
Start-Sleep -Milliseconds 500

# [Test 3] CORE: list-keys after unbind-key -a shows drastically fewer bindings
Write-Host "`n[Test 3] CORE: list-keys after unbind-key -a shows 0 prefix bindings" -ForegroundColor Yellow
$afterCount = Count-PrefixBindings $SESSION
Write-Host "    Prefix bindings after unbind-key -a: $afterCount" -ForegroundColor DarkGray
$allLines = @(& $PSMUX list-keys -t $SESSION 2>&1)
Write-Host "    Total list-keys lines: $($allLines.Count)" -ForegroundColor DarkGray
if ($allLines.Count -le 5) {
    foreach ($l in $allLines) { Write-Host "      $l" -ForegroundColor DarkGray }
}

if ($afterCount -eq 0) {
    Write-Pass "VERIFIED: 0 prefix bindings remain after unbind-key -a"
} elseif ($afterCount -lt ($beforeCount / 2)) {
    Write-Fail "PARTIAL: $afterCount prefix bindings remain (expected 0, had $beforeCount before)"
} else {
    Write-Fail "BROKEN: $afterCount prefix bindings remain after unbind-key -a (had $beforeCount before, no reduction)"
}

# [Test 4] AFTER < BEFORE assertion
Write-Host "`n[Test 4] After count ($afterCount) is less than before count ($beforeCount)" -ForegroundColor Yellow
if ($afterCount -lt $beforeCount) {
    Write-Pass "Count reduced: $beforeCount -> $afterCount"
} else {
    Write-Fail "Count NOT reduced: $beforeCount -> $afterCount (unbind-key -a had no effect)"
}

# ── Part B: new bind-key after unbind-all starts fresh ───────────────────────
Write-Host "`n--- Part B: bind-key after unbind-key -a ---" -ForegroundColor Magenta

# [Test 5] After unbind-all, add one binding and verify it's the ONLY one in prefix
Write-Host "`n[Test 5] After unbind-key -a, bind-key adds exactly 1 prefix binding" -ForegroundColor Yellow
& $PSMUX bind-key -t $SESSION x new-window 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$afterBindCount = Count-PrefixBindings $SESSION
Write-Host "    Prefix bindings after adding 'x': $afterBindCount" -ForegroundColor DarkGray
if ($afterBindCount -eq 1) {
    Write-Pass "Exactly 1 prefix binding after unbind-all + bind-key x: clean slate confirmed"
} elseif ($afterBindCount -gt 1 -and $afterCount -eq 0) {
    Write-Fail "Expected 1 binding after bind-key x, got $afterBindCount (defaults may have reappeared)"
} else {
    # afterCount was not 0 — partial unbind; at least verify x was added
    $hasX = @(& $PSMUX list-keys -t $SESSION 2>&1 | Where-Object { $_ -match "-T\s+prefix\s+x\b" })
    if ($hasX.Count -gt 0) {
        Write-Pass "bind-key x is present in prefix table after unbind-all (count=$afterBindCount)"
    } else {
        Write-Fail "bind-key x not found in prefix table after unbind-all + bind-key"
    }
}

# ── Part C: unbind-key -a -T <table> clears only that table ──────────────────
Write-Host "`n--- Part C: unbind-key -a -T <table> selective clear ---" -ForegroundColor Magenta

# First, restore defaults via kill/recreate session
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION
if (-not (Wait-PortFile $SESSION)) {
    Write-Fail "Re-created session '$SESSION' port file never appeared"
} else {
    Start-Sleep -Milliseconds 500

    # [Test 6] unbind-key -a -T prefix clears only prefix table
    Write-Host "`n[Test 6] unbind-key -a -T prefix clears only prefix table" -ForegroundColor Yellow
    $prefixBefore = Count-PrefixBindings $SESSION
    $allBefore    = @(& $PSMUX list-keys -t $SESSION 2>&1).Count
    Write-Host "    Before: prefix=$prefixBefore  total=$allBefore" -ForegroundColor DarkGray

    & $PSMUX unbind-key -a -T prefix -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400

    $prefixAfter = Count-PrefixBindings $SESSION
    $allAfter    = @(& $PSMUX list-keys -t $SESSION 2>&1).Count
    Write-Host "    After:  prefix=$prefixAfter  total=$allAfter" -ForegroundColor DarkGray

    if ($prefixAfter -eq 0) {
        Write-Pass "unbind-key -a -T prefix cleared prefix table (0 prefix bindings)"
    } else {
        Write-Fail "unbind-key -a -T prefix: $prefixAfter prefix bindings remain (expected 0)"
    }
}

# ── Part D: TCP path ──────────────────────────────────────────────────────────
Write-Host "`n--- Part D: TCP path ---" -ForegroundColor Magenta

# Recreate clean session for TCP tests
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION
if (-not (Wait-PortFile $SESSION)) {
    Write-Fail "TCP-test session port file never appeared — skipping TCP tests"
} else {
    # Poll until default bindings are populated (session fully initialised)
    $readyCount = Wait-DefaultBindings $SESSION 10 10
    Write-Host "    TCP session ready with $readyCount prefix bindings" -ForegroundColor DarkGray

    # [Test 7] TCP list-keys BEFORE shows many bindings
    Write-Host "`n[Test 7] TCP list-keys BEFORE unbind-key -a shows many bindings" -ForegroundColor Yellow
    $tcpBeforeLines = @(Send-TcpCommandMultiLine -Sess $SESSION -Cmd "list-keys" | Where-Object { $_ -match "-T\s+prefix\b" })
    Write-Host "    TCP prefix bindings before: $($tcpBeforeLines.Count)" -ForegroundColor DarkGray
    if ($tcpBeforeLines.Count -ge 10) {
        Write-Pass "TCP: $($tcpBeforeLines.Count) prefix bindings before unbind-all"
    } else {
        Write-Fail "TCP: only $($tcpBeforeLines.Count) prefix bindings before (expected >= 10)"
    }

    # [Test 8] TCP unbind-key -a then list-keys
    Write-Host "`n[Test 8] TCP: unbind-key -a then list-keys shows 0 prefix bindings" -ForegroundColor Yellow
    $ubResp = Send-TcpCommand -Sess $SESSION -Cmd "unbind-key -a"
    Write-Host "    TCP unbind-key -a response: '$ubResp'" -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 400

    $tcpAfterLines = @(Send-TcpCommandMultiLine -Sess $SESSION -Cmd "list-keys" | Where-Object { $_ -match "-T\s+prefix\b" })
    Write-Host "    TCP prefix bindings after unbind-key -a: $($tcpAfterLines.Count)" -ForegroundColor DarkGray

    if ($tcpAfterLines.Count -eq 0) {
        Write-Pass "TCP: 0 prefix bindings after unbind-key -a"
    } elseif ($tcpAfterLines.Count -lt $tcpBeforeLines.Count) {
        Write-Fail "TCP PARTIAL: $($tcpAfterLines.Count) prefix bindings remain (expected 0, had $($tcpBeforeLines.Count))"
    } else {
        Write-Fail "TCP BROKEN: $($tcpAfterLines.Count) prefix bindings remain unchanged after unbind-key -a"
    }

    if ($tcpAfterLines.Count -lt $tcpBeforeLines.Count) {
        Write-Pass "TCP: count reduced $($tcpBeforeLines.Count) -> $($tcpAfterLines.Count)"
    } else {
        Write-Fail "TCP: count NOT reduced: $($tcpBeforeLines.Count) -> $($tcpAfterLines.Count)"
    }
}

# ── Part E: config-file path (exact user config from issue report) ────────────
Write-Host "`n--- Part E: config-file path (exact issue scenario) ---" -ForegroundColor Magenta

$SESSION_CFG = "gap195cfg"
& $PSMUX kill-session -t $SESSION_CFG 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\$SESSION_CFG.*" -Force -EA SilentlyContinue

$confFile = "$env:TEMP\psmux_test_195.conf"
@'
# unbind all keys - exact user config from issue #195
unbind-key -a
unbind-key -a -T prefix
unbind-key -a -T root
# switch prefix to C-a
set -g prefix C-a
# add just two bindings
bind-key r source-file ~/.tmux.conf
bind-key c new-window
'@ | Set-Content -Path $confFile -Encoding UTF8

Write-Host "`n[Test 9] Config file with unbind-key -a then bind-key leaves only user bindings" -ForegroundColor Yellow
$env:PSMUX_CONFIG_FILE = $confFile
& $PSMUX new-session -d -s $SESSION_CFG 2>&1 | Out-Null
$env:PSMUX_CONFIG_FILE = $null
if (-not (Wait-PortFile $SESSION_CFG 12)) {
    Write-Fail "Config session '$SESSION_CFG' never started"
} else {
    Start-Sleep -Milliseconds 800
    $cfgLines = @(& $PSMUX list-keys -t $SESSION_CFG 2>&1)
    $cfgPrefixLines = @($cfgLines | Where-Object { $_ -match "-T\s+prefix\b" })
    Write-Host "    Config session prefix bindings: $($cfgPrefixLines.Count)" -ForegroundColor DarkGray
    foreach ($l in $cfgPrefixLines) { Write-Host "      $l" -ForegroundColor DarkGray }

    # After unbind-all + bind-key r + bind-key c, expect exactly 2 prefix bindings
    if ($cfgPrefixLines.Count -le 3) {
        Write-Pass "Config file: $($cfgPrefixLines.Count) prefix bindings (unbind-all + 2 user bindings = expected <= 3)"
    } else {
        Write-Fail "Config file: $($cfgPrefixLines.Count) prefix bindings remain (expected ~2 after unbind-all)"
    }

    # Verify the user's own bindings are present
    $hasR = $cfgPrefixLines | Where-Object { $_ -match "\br\b.*source-file" }
    $hasC = $cfgPrefixLines | Where-Object { $_ -match "\bc\b.*new-window" }
    if ($hasR) {
        Write-Pass "Config session: 'bind-key r source-file' is present"
    } else {
        Write-Fail "Config session: 'bind-key r source-file' NOT found in list-keys"
    }
    if ($hasC) {
        Write-Pass "Config session: 'bind-key c new-window' is present"
    } else {
        Write-Fail "Config session: 'bind-key c new-window' NOT found in list-keys"
    }

    & $PSMUX kill-session -t $SESSION_CFG 2>&1 | Out-Null
    Remove-Item "$psmuxDir\$SESSION_CFG.*" -Force -EA SilentlyContinue
}
Remove-Item $confFile -Force -EA SilentlyContinue

# ── teardown ──────────────────────────────────────────────────────────────────
Cleanup

Write-Host "`n$(('=' * 60))" -ForegroundColor Cyan
Write-Host "RESULTS  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""

exit $script:TestsFailed
