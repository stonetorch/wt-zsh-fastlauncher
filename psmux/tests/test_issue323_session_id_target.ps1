# Issue #323: attach-session -t $N fails to resolve tmux session ID targets
# Fix: $N target form (e.g. $0, $1, $2) is resolved server-side to the real session.
# Proof strategy (no client needed):
#   1. Create a detached session gap323
#   2. Read its session_id via display-message -p '#{session_id}' (gives e.g. $3)
#   3. has-session -t $<id>   must exit 0
#   4. display-message -t $<id> -p '#{session_name}'  must return 'gap323'

$ErrorActionPreference = "Continue"
$PSMUX   = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

$script:Pass = 0
$script:Fail = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:Pass++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:Fail++ }

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 12000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -EA SilentlyContinue)
            if ($port -and $port.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port.Trim())
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Cleanup {
    & $PSMUX kill-session -t gap323 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\gap323.*" -Force -EA SilentlyContinue
}

Write-Host "`n=== Issue #323: Session ID target resolution (\$N form) ===" -ForegroundColor Cyan

Cleanup
Start-Sleep -Milliseconds 300

# --- Step 1: create session ---
& $PSMUX new-session -d -s gap323 2>&1 | Out-Null
if (-not (Wait-Session "gap323")) {
    Write-Fail "gap323 session failed to start — aborting"
    exit 1
}
Write-Pass "gap323 session created and reachable"

# --- Step 2: read its session_id ---
$rawId = (& $PSMUX display-message -t gap323 -p '#{session_id}' 2>&1 | Out-String).Trim()
Write-Host "  session_id reported: '$rawId'"

if ($rawId -match '^\$\d+$') {
    Write-Pass "session_id has valid format: $rawId"
} else {
    Write-Fail "session_id format unexpected: '$rawId' — aborting ID-resolution tests"
    Cleanup
    Write-Host "`n=== Results: $($script:Pass) passed, $($script:Fail) failed ===" -ForegroundColor Cyan
    exit $script:Fail
}

# Strip the leading $ for PowerShell variable safety; rebuild the $N string
$numericPart = $rawId.TrimStart('$')
$dollarTarget = "`$$numericPart"   # e.g. $3

# --- Step 3: has-session -t $N must exit 0 ---
Write-Host "`n[Test] has-session -t $dollarTarget exits 0" -ForegroundColor Yellow
& $PSMUX has-session -t $dollarTarget 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "has-session -t $dollarTarget exited 0 (session found by ID)"
} else {
    Write-Fail "has-session -t $dollarTarget exited $LASTEXITCODE (ID NOT resolved — bug present)"
}

# --- Step 4: display-message -t $N -p '#{session_name}' returns 'gap323' ---
Write-Host "`n[Test] display-message -t $dollarTarget -p '#{session_name}' returns 'gap323'" -ForegroundColor Yellow
$resolvedName = (& $PSMUX display-message -t $dollarTarget -p '#{session_name}' 2>&1 | Out-String).Trim()
Write-Host "  resolved name: '$resolvedName'"

if ($resolvedName -eq "gap323") {
    Write-Pass "display-message -t $dollarTarget resolved to session name 'gap323'"
} else {
    Write-Fail "display-message -t $dollarTarget returned '$resolvedName' (expected 'gap323')"
}

# --- Step 5: display-message -t $N -p '#{session_id}' round-trips ---
Write-Host "`n[Test] display-message -t $dollarTarget -p '#{session_id}' round-trips" -ForegroundColor Yellow
$roundTrip = (& $PSMUX display-message -t $dollarTarget -p '#{session_id}' 2>&1 | Out-String).Trim()
Write-Host "  round-trip session_id: '$roundTrip'"

if ($roundTrip -eq $rawId) {
    Write-Pass "session_id round-trips correctly via \$N target"
} else {
    Write-Fail "session_id round-trip mismatch: got '$roundTrip', expected '$rawId'"
}

# --- TCP confirmation ---
Write-Host "`n[Test] Raw-TCP: display-message -p #{session_id} via session's own port" -ForegroundColor Yellow
$port = (Get-Content "$psmuxDir\gap323.port" -Raw -EA SilentlyContinue).Trim()
$key  = (Get-Content "$psmuxDir\gap323.key"  -Raw -EA SilentlyContinue).Trim()
if ($port -and $key) {
    try {
        $tcp    = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $stream = $tcp.GetStream()
        $w      = [System.IO.StreamWriter]::new($stream)
        $r      = [System.IO.StreamReader]::new($stream)
        $w.Write("AUTH $key`n"); $w.Flush()
        $authLine = $r.ReadLine()
        if ($authLine -eq "OK") {
            $w.Write("display-message -p #{session_id}`n"); $w.Flush()
            $stream.ReadTimeout = 4000
            $tcpId = try { $r.ReadLine() } catch { "TIMEOUT" }
            $tcp.Close()
            Write-Host "  TCP session_id: '$tcpId'"
            if ($tcpId -eq $rawId) {
                Write-Pass "TCP session_id matches: $tcpId"
            } else {
                Write-Fail "TCP session_id mismatch: '$tcpId' vs '$rawId'"
            }
        } else {
            $tcp.Close()
            Write-Fail "TCP AUTH failed: $authLine"
        }
    } catch {
        Write-Fail "TCP connection error: $_"
    }
} else {
    Write-Fail "Could not read port/key files for TCP confirmation"
}

Cleanup

Write-Host "`n=== Issue #323 Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
exit $script:Fail
