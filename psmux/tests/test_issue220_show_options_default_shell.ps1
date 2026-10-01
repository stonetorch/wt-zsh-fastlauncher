# Issue #220: show-options: default-shell has no value when unset
# Tests that show-options -g default-shell (and show-options -g) returns
# a real, non-empty shell path/name even when default-shell is not configured.
#
# The bug: when default-shell was unset, the option line was emitted with
# no value ("default-shell" with blank), instead of the resolved shell path.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "gap220"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $portFile = "$psmuxDir\$Session.port"
    $keyFile  = "$psmuxDir\$Session.key"
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $authResp = $reader.ReadLine()
    if ($authResp -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 10000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

# Wait for the port file to appear (up to 12 seconds)
function Wait-PortFile {
    param([string]$Session, [int]$TimeoutSec = 12)
    $portFile = "$psmuxDir\$Session.port"
    $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
    while ([DateTime]::Now -lt $deadline) {
        if (Test-Path $portFile) {
            $content = (Get-Content $portFile -Raw -EA SilentlyContinue).Trim()
            if ($content -match '^\d+$') { return $true }
        }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# === SETUP ===
Cleanup
Start-Sleep -Milliseconds 300
& $PSMUX new-session -d -s $SESSION

$portReady = Wait-PortFile -Session $SESSION -TimeoutSec 12
if (-not $portReady) {
    Write-Fail "Session port file never appeared within 12s"
    Cleanup
    exit 1
}

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session did not start"
    Cleanup
    exit 1
}

Write-Host "`n=== Issue #220 Tests: show-options default-shell value ===" -ForegroundColor Cyan

# ================================================================
# Part A: CLI path -- show-options -g default-shell
# ================================================================
Write-Host "`n--- Part A: CLI Path (show-options -g default-shell) ---" -ForegroundColor Magenta

# Test 1: show-options -g default-shell returns a line with a non-empty value
Write-Host "`n[Test 1] show-options -g default-shell returns non-empty value" -ForegroundColor Yellow
$output = (& $PSMUX show-options -g default-shell -t $SESSION 2>&1 | Out-String).Trim()
Write-Host "    Raw output: '$output'" -ForegroundColor DarkGray

# Must contain "default-shell" followed by at least one non-whitespace character
if ($output -match 'default-shell\s+\S+') {
    $shellValue = ($output -replace '^default-shell\s+', '').Trim()
    Write-Pass "show-options -g default-shell has value: '$shellValue'"
} else {
    Write-Fail "show-options -g default-shell returned no value or blank. Got: '$output'"
}

# Test 2: The value looks like a shell (pwsh, powershell, cmd, or a path ending in .exe)
Write-Host "`n[Test 2] Returned value is a recognizable shell" -ForegroundColor Yellow
if ($output -match 'default-shell\s+(\S+)') {
    $shellValue = $matches[1].Trim()
    $looksLikeShell = (
        $shellValue -match 'pwsh'         -or
        $shellValue -match 'powershell'   -or
        $shellValue -match 'cmd'          -or
        $shellValue -match '\.exe$'       -or
        $shellValue -match '[/\\]'         # any path separator
    )
    if ($looksLikeShell) {
        Write-Pass "Value looks like a shell executable: '$shellValue'"
    } else {
        Write-Fail "Value does not look like a shell: '$shellValue'"
    }
} else {
    Write-Fail "Cannot extract shell value from output: '$output'"
}

# Test 3: Value is NOT just whitespace or "default-shell" alone on its line
Write-Host "`n[Test 3] Output line is not bare 'default-shell' with no value" -ForegroundColor Yellow
$lines = $output -split "`n" | Where-Object { $_ -match 'default-shell' }
$bareLines = $lines | Where-Object { $_.Trim() -eq 'default-shell' }
if ($bareLines.Count -eq 0) {
    Write-Pass "No bare 'default-shell' line (value is always present)"
} else {
    Write-Fail "Found bare 'default-shell' line with no value: '$($bareLines -join ', ')'"
}

# ================================================================
# Part B: show-options -g (full list) includes default-shell with value
# ================================================================
Write-Host "`n--- Part B: Full show-options -g includes default-shell ---" -ForegroundColor Magenta

# Test 4: show-options -g (all options) includes a default-shell line with a value
Write-Host "`n[Test 4] show-options -g includes default-shell with a value" -ForegroundColor Yellow
$allOpts = (& $PSMUX show-options -g -t $SESSION 2>&1 | Out-String)
Write-Host "    (Checking for 'default-shell <value>' in full output)" -ForegroundColor DarkGray

if ($allOpts -match 'default-shell\s+\S+') {
    $m = [regex]::Match($allOpts, 'default-shell\s+(\S+)')
    Write-Pass "Full show-options -g contains default-shell value: '$($m.Groups[1].Value)'"
} else {
    # Check if the key is present at all but with no value
    if ($allOpts -match 'default-shell') {
        Write-Fail "default-shell appears in full show-options -g but has NO value"
    } else {
        Write-Fail "default-shell is completely absent from full show-options -g output"
    }
}

# Test 5: The default-shell values from single-option and full-list queries agree
Write-Host "`n[Test 5] show-options -g default-shell and show-options -g agree on value" -ForegroundColor Yellow
$singleVal = ""
$fullVal   = ""
if ($output -match 'default-shell\s+(\S+)')   { $singleVal = $matches[1].Trim() }
if ($allOpts  -match 'default-shell\s+(\S+)') { $fullVal   = $matches[1].Trim() }

if ($singleVal -ne "" -and $fullVal -ne "" -and $singleVal -eq $fullVal) {
    Write-Pass "Both queries agree: default-shell = '$singleVal'"
} elseif ($singleVal -eq "" -or $fullVal -eq "") {
    Write-Fail "One or both queries returned no value (single='$singleVal', full='$fullVal')"
} else {
    Write-Fail "Values differ: single='$singleVal', full='$fullVal'"
}

# ================================================================
# Part C: TCP server path
# ================================================================
Write-Host "`n--- Part C: TCP Server Path ---" -ForegroundColor Magenta

# Test 6: TCP show-options -g default-shell returns non-empty value
Write-Host "`n[Test 6] TCP show-options -g default-shell returns non-empty value" -ForegroundColor Yellow
$tcpResp = Send-TcpCommand -Session $SESSION -Command "show-options -g default-shell"
Write-Host "    TCP response: '$tcpResp'" -ForegroundColor DarkGray

if ($tcpResp -match 'default-shell\s+\S+') {
    $tcpVal = ($tcpResp -replace '^default-shell\s+', '').Trim()
    Write-Pass "TCP show-options default-shell has value: '$tcpVal'"
} else {
    Write-Fail "TCP show-options default-shell returned no value or blank. Got: '$tcpResp'"
}

# Test 7: TCP value matches CLI value
Write-Host "`n[Test 7] TCP and CLI default-shell values match" -ForegroundColor Yellow
$tcpVal2 = ""
if ($tcpResp -match 'default-shell\s+(\S+)') { $tcpVal2 = $matches[1].Trim() }

if ($singleVal -ne "" -and $tcpVal2 -ne "" -and $singleVal -eq $tcpVal2) {
    Write-Pass "CLI and TCP agree: '$singleVal'"
} elseif ($tcpVal2 -eq "") {
    Write-Fail "TCP returned no value; CLI returned '$singleVal'"
} elseif ($singleVal -eq "") {
    Write-Fail "CLI returned no value; TCP returned '$tcpVal2'"
} else {
    # Different paths may use slightly different resolution — warn but don't fail hard
    Write-Fail "CLI='$singleVal' != TCP='$tcpVal2'"
}

# ================================================================
# Part D: After explicitly setting default-shell, value reflects that
# ================================================================
Write-Host "`n--- Part D: Explicit set-option overrides fallback ---" -ForegroundColor Magenta

# Test 8: After set-option -g default-shell, show-options returns that exact value
Write-Host "`n[Test 8] Explicit set-option -g default-shell is reflected in show-options" -ForegroundColor Yellow
$customShell = "C:\Windows\System32\cmd.exe"
& $PSMUX set-option -g -t $SESSION default-shell $customShell 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

$afterSet = (& $PSMUX show-options -g default-shell -t $SESSION 2>&1 | Out-String).Trim()
Write-Host "    After set: '$afterSet'" -ForegroundColor DarkGray

if ($afterSet -match [regex]::Escape($customShell)) {
    Write-Pass "After set-option, show-options returns custom value: '$customShell'"
} else {
    Write-Fail "After set-option, expected '$customShell', got: '$afterSet'"
}

# ================================================================
# TEARDOWN
# ================================================================
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
