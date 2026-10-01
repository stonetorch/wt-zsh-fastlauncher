#!/usr/bin/env pwsh
# Issue #9: detach was killing the entire session.
# Fix: detach-client disconnects the client but the session (and its panes) survive.
#
# Assertion: after detach-client -s <session>, has-session exits 0 and the
# session is still reachable over TCP.

$ErrorActionPreference = "Continue"
$PSMUX    = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION  = "gap9"

$script:Pass = 0
$script:Fail = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:Fail++ }

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 12000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path "$psmuxDir\$Name.port") {
            $raw = (Get-Content "$psmuxDir\$Name.port" -Raw -EA SilentlyContinue)
            if ($raw -and $raw.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$raw.Trim())
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
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    & $PSMUX kill-session -t "${SESSION}_tui" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    Remove-Item "$psmuxDir\$SESSION.*"       -Force -EA SilentlyContinue
    Remove-Item "$psmuxDir\${SESSION}_tui.*" -Force -EA SilentlyContinue
}

Cleanup

Write-Host "`n=== Issue #9: detach must NOT kill the session ===" -ForegroundColor Cyan

# ── T1: CLI path (detached background session) ──────────────────────────────
Write-Host "`n[T1] CLI: detach-client -s <session> leaves session alive" -ForegroundColor Yellow

& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
$up = Wait-Session $SESSION
if (-not $up) {
    Write-Fail "session $SESSION never came up — cannot continue T1"
} else {
    Start-Sleep -Milliseconds 500

    # Issue the detach command (no attached client in -d mode; this is a safe no-op
    # on the client list but must NOT kill the session itself)
    $out = & $PSMUX detach-client -s $SESSION 2>&1
    $rc  = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-Fail "detach-client returned non-zero ($rc): $out"
    } else {
        Write-Pass "detach-client exited 0"
    }

    Start-Sleep -Milliseconds 500

    # Primary assertion: has-session must exit 0
    & $PSMUX has-session -t $SESSION 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "has-session exits 0 after detach (session survived)"
    } else {
        Write-Fail "has-session exits non-zero: session was KILLED by detach (regression #9)"
    }

    # Secondary assertion: TCP port still connectable
    $still = Wait-Session $SESSION 3000
    if ($still) {
        Write-Pass "TCP port still connectable after detach"
    } else {
        Write-Fail "TCP port gone after detach — server process died"
    }
}

# ── T2: 'detach' alias also keeps session alive ──────────────────────────────
Write-Host "`n[T2] 'detach' alias: session survives" -ForegroundColor Yellow

& $PSMUX has-session -t $SESSION 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    # Re-create if T1 left it dead
    & $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
    Wait-Session $SESSION | Out-Null
    Start-Sleep -Milliseconds 500
}

& $PSMUX detach -s $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX has-session -t $SESSION 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "'detach' alias: session intact after detach"
} else {
    Write-Fail "'detach' alias killed the session (regression #9)"
}

# ── T3: TUI — Start-Process attached client, detach via CLI, server survives ──
Write-Host "`n[T3] TUI: real attached client detached via CLI, server preserved" -ForegroundColor Yellow

& $PSMUX kill-session -t "${SESSION}_tui" 2>&1 | Out-Null
Remove-Item "$psmuxDir\${SESSION}_tui.*" -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 300

# Launch psmux as a real attached TUI client in a new window
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","${SESSION}_tui" -PassThru
Start-Sleep -Seconds 4

$up = Wait-Session "${SESSION}_tui"
if (-not $up) {
    Write-Fail "TUI session never came up"
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
} else {
    # Detach the client via CLI
    & $PSMUX detach-client -s "${SESSION}_tui" 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # The server session must still exist
    & $PSMUX has-session -t "${SESSION}_tui" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "TUI: session survives after client detach (core fix for #9)"
    } else {
        Write-Fail "TUI: session was killed when client detached (regression #9)"
    }

    # list-sessions must include it
    $ls = & $PSMUX list-sessions 2>&1 | Out-String
    if ($ls -match "${SESSION}_tui") {
        Write-Pass "TUI: list-sessions still shows the session"
    } else {
        Write-Fail "TUI: session missing from list-sessions"
    }

    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}

Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
$failColor = if ($script:Fail -gt 0) { "Red" } else { "Green" }
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $failColor
exit $script:Fail
