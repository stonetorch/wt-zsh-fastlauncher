# Issue #5: Security: any process can connect over TCP, including running under different users
# Fix: TCP control socket requires AUTH <key> as first message before accepting commands.
#
# This test proves:
#   1. Without any AUTH, commands are rejected with an authentication error
#   2. With a wrong key, commands are rejected with an invalid-key error
#   3. With the correct key, commands succeed
#   4. The positive security assertion: wrong/no key cannot run commands

$ErrorActionPreference = "Continue"
$PSMUX    = (Get-Command psmux -EA Stop).Source
$SESSION  = "gap5"
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
        $pf = "$psmuxDir\$Name.port"
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -EA SilentlyContinue)
            if ($port -and $port.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port.Trim())
                    $tcp.Close()
                    return [int]$port.Trim()
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

# Send a raw TCP message without auth and return first response line
function Send-RawTcp {
    param([int]$Port, [string]$Message, [int]$TimeoutMs = 3000)
    try {
        $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $Port)
        $t.NoDelay = $true
        $s = $t.GetStream()
        $s.ReadTimeout = $TimeoutMs
        $w = [System.IO.StreamWriter]::new($s)
        $r = [System.IO.StreamReader]::new($s)
        $w.Write("$Message`n"); $w.Flush()
        try { $resp = $r.ReadLine() } catch { $resp = $null }
        $t.Close()
        return $resp
    } catch {
        return "CONNECTION_FAILED: $_"
    }
}

# Send AUTH <key> then a command; return command response line
function Send-AuthenticatedTcp {
    param([int]$Port, [string]$Key, [string]$Command, [int]$TimeoutMs = 5000)
    try {
        $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $Port)
        $t.NoDelay = $true
        $s = $t.GetStream()
        $s.ReadTimeout = $TimeoutMs
        $w = [System.IO.StreamWriter]::new($s)
        $r = [System.IO.StreamReader]::new($s)
        $w.Write("AUTH $Key`n"); $w.Flush()
        try { $authResp = $r.ReadLine() } catch { $authResp = $null }
        if ($authResp -ne "OK") { $t.Close(); return "AUTH_FAILED: $authResp" }
        $w.Write("$Command`n"); $w.Flush()
        try { $resp = $r.ReadLine() } catch { $resp = $null }
        $t.Close()
        return $resp
    } catch {
        return "CONNECTION_FAILED: $_"
    }
}

# ── Setup ─────────────────────────────────────────────────────────────────────
Cleanup
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
$port = Wait-PortFile $SESSION
if (-not $port) {
    Write-Fail "Session '$SESSION' port never became reachable"
    exit 1
}

$keyFile = "$psmuxDir\$SESSION.key"
if (-not (Test-Path $keyFile)) {
    Write-Fail "Key file '$keyFile' does not exist - auth not implemented?"
    Cleanup
    exit 1
}
$correctKey = (Get-Content $keyFile -Raw).Trim()

Write-Host "`n=== Issue #5: TCP Auth Security ===" -ForegroundColor Cyan
Write-Host "  Session: $SESSION  Port: $port  Key length: $($correctKey.Length)" -ForegroundColor DarkGray

# ── Test 1: No auth - command rejected ────────────────────────────────────────
Write-Host "`n[Test 1] Command sent WITHOUT auth is rejected" -ForegroundColor Yellow
$resp = Send-RawTcp -Port $port -Message "list-sessions"
Write-Host "  Response: '$resp'" -ForegroundColor DarkGray
if ($resp -match "ERROR.*[Aa]uthentication" -or $null -eq $resp -or $resp -eq "") {
    Write-Pass "No-auth command rejected (response: '$resp')"
} else {
    Write-Fail "No-auth command was NOT rejected - got: '$resp'"
}

# ── Test 2: Wrong key - rejected ──────────────────────────────────────────────
Write-Host "`n[Test 2] Wrong AUTH key is rejected" -ForegroundColor Yellow
$resp = Send-RawTcp -Port $port -Message "AUTH thewrongkey00000000"
Write-Host "  Response to wrong AUTH: '$resp'" -ForegroundColor DarkGray
if ($resp -match "ERROR" -or $null -eq $resp -or $resp -eq "") {
    Write-Pass "Wrong key rejected (response: '$resp')"
} else {
    Write-Fail "Wrong key was NOT rejected - got: '$resp'"
}

# ── Test 3: Wrong key + command - command does NOT execute ────────────────────
Write-Host "`n[Test 3] new-window with wrong key does NOT create a window" -ForegroundColor Yellow
$windowsBefore = (& $PSMUX list-windows -t $SESSION 2>&1 | Where-Object { $_ -match "^\d+" }).Count
# Try the exact PoC: wrong auth then a new-window
$t2 = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
$t2.NoDelay = $true
$s2 = $t2.GetStream(); $s2.ReadTimeout = 2000
$w2 = [System.IO.StreamWriter]::new($s2)
$r2 = [System.IO.StreamReader]::new($s2)
$w2.Write("AUTH bad_key_issue5`n"); $w2.Flush()
try { $ar = $r2.ReadLine() } catch { $ar = $null }
$w2.Write("new-window`n"); $w2.Flush()
try { $cr = $r2.ReadLine() } catch { $cr = $null }
$t2.Close()
Start-Sleep -Milliseconds 800
$windowsAfter = (& $PSMUX list-windows -t $SESSION 2>&1 | Where-Object { $_ -match "^\d+" }).Count
Write-Host "  Auth resp: '$ar'  Cmd resp: '$cr'  Windows before=$windowsBefore after=$windowsAfter" -ForegroundColor DarkGray
if ($windowsAfter -le $windowsBefore) {
    Write-Pass "new-window with wrong key: window count unchanged ($windowsBefore -> $windowsAfter)"
} else {
    Write-Fail "SECURITY FAILURE: window created without correct auth ($windowsBefore -> $windowsAfter)"
}

# ── Test 4: Correct key - command succeeds ────────────────────────────────────
Write-Host "`n[Test 4] Correct AUTH key - list-sessions succeeds" -ForegroundColor Yellow
$resp = Send-AuthenticatedTcp -Port $port -Key $correctKey -Command "list-sessions"
Write-Host "  Response: '$resp'" -ForegroundColor DarkGray
if ($resp -match $SESSION) {
    Write-Pass "Correct key accepted, list-sessions returned session name"
} else {
    Write-Fail "Correct key did not work - got: '$resp'"
}

# ── Test 5: Correct key - new-window succeeds ─────────────────────────────────
Write-Host "`n[Test 5] Correct AUTH key - new-window succeeds" -ForegroundColor Yellow
$windowsBefore = (& $PSMUX list-windows -t $SESSION 2>&1 | Where-Object { $_ -match "^\d+" }).Count
$resp = Send-AuthenticatedTcp -Port $port -Key $correctKey -Command "new-window"
Start-Sleep -Milliseconds 800
$windowsAfter = (& $PSMUX list-windows -t $SESSION 2>&1 | Where-Object { $_ -match "^\d+" }).Count
Write-Host "  Windows before=$windowsBefore after=$windowsAfter" -ForegroundColor DarkGray
if ($windowsAfter -gt $windowsBefore) {
    Write-Pass "new-window with correct key created a window ($windowsBefore -> $windowsAfter)"
} else {
    Write-Fail "new-window with correct key did NOT create a window ($windowsBefore -> $windowsAfter)"
}

# ── Test 6: No auth send-keys also rejected ────────────────────────────────────
Write-Host "`n[Test 6] send-keys WITHOUT auth is rejected" -ForegroundColor Yellow
$resp = Send-RawTcp -Port $port -Message 'send-keys "echo INJECTED5" Enter'
Write-Host "  Response: '$resp'" -ForegroundColor DarkGray
if ($resp -match "ERROR.*[Aa]uthentication" -or $null -eq $resp -or $resp -eq "") {
    Write-Pass "send-keys without auth rejected"
} else {
    Write-Fail "send-keys without auth was NOT rejected - got: '$resp'"
}

# ── Teardown ──────────────────────────────────────────────────────────────────
Cleanup

Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "RESULTS  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""

exit $script:TestsFailed
