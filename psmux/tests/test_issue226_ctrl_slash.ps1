# Issue #226: send-keys C-/ and C-o produce identical bytes (0x0F),
# making them indistinguishable in send-keys. tmux sends 0x1F for C-/
# and 0x0F only for C-o. This test exercises the real send-keys path
# end-to-end via the live psmux binary.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue226"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# Helper: send a key string, then send the printable token "PROBE" + Enter.
# capture-pane will show the echoed control byte (e.g. ^O, ^_) immediately
# before "PROBE", so we can identify which raw byte was emitted.
function Probe-Key {
    param([string]$Key)
    & $PSMUX send-keys -t $SESSION 'clear' Enter | Out-Null
    Start-Sleep -Milliseconds 700
    & $PSMUX send-keys -t $SESSION $Key | Out-Null
    Start-Sleep -Milliseconds 200
    & $PSMUX send-keys -t $SESSION 'PROBE' Enter | Out-Null
    Start-Sleep -Seconds 1
    return (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String)
}

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

Write-Host "`n=== Issue #226: send-keys C-/ vs C-o parity ===" -ForegroundColor Cyan

# --- Test 1: C-o still produces ^O ---
Write-Host "`n[Test 1] C-o produces ^O (0x0F)" -ForegroundColor Yellow
$capO = Probe-Key 'C-o'
if ($capO -match '\^O') { Write-Pass "C-o renders as ^O in pane" }
else { Write-Fail "C-o did not render as ^O. Pane: $capO" }

# --- Test 2: C-/ must NOT produce ^O ---
Write-Host "`n[Test 2] C-/ does NOT produce ^O" -ForegroundColor Yellow
$capSlash = Probe-Key 'C-/'
if ($capSlash -notmatch '\^O') {
    Write-Pass "C-/ no longer collapses to ^O (bug #226 fixed)"
} else {
    Write-Fail "BUG #226 STILL PRESENT: C-/ rendered as ^O. Pane: $capSlash"
}

# --- Test 3: C-/ produces ^_ (0x1F) per tmux parity ---
Write-Host "`n[Test 3] C-/ produces ^_ (0x1F) like tmux" -ForegroundColor Yellow
# PowerShell echoes 0x1F as ^_ in the prompt buffer.
if ($capSlash -match '\^_') {
    Write-Pass "C-/ renders as ^_ matching tmux behavior"
} else {
    # Some shells swallow 0x1F silently. Accept either: bytes were not ^O,
    # AND the captured output differs from C-o's output.
    if ($capSlash -ne $capO) {
        Write-Pass "C-/ output differs from C-o output (bytes are distinct)"
    } else {
        Write-Fail "C-/ produced the same pane content as C-o. Pane: $capSlash"
    }
}

# --- Test 4: Direct TCP send-keys verifies server-side path ---
Write-Host "`n[Test 4] TCP send-keys path produces distinct bytes for C-/ vs C-o" -ForegroundColor Yellow
function Send-Tcp {
    param([string]$Cmd)
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$SESSION.key"  -Raw).Trim()
    $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $w = [System.IO.StreamWriter]::new($stream)
    $r = [System.IO.StreamReader]::new($stream)
    $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
    $w.Write("$Cmd`n"); $w.Flush()
    $stream.ReadTimeout = 3000
    try { $resp = $r.ReadLine() } catch { $resp = "" }
    $tcp.Close()
    return $resp
}
& $PSMUX send-keys -t $SESSION 'clear' Enter | Out-Null
Start-Sleep -Milliseconds 700
$null = Send-Tcp "send-keys C-/"
Start-Sleep -Milliseconds 200
& $PSMUX send-keys -t $SESSION 'TCPMARK1' Enter | Out-Null
Start-Sleep -Seconds 1
$capTcpSlash = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String

& $PSMUX send-keys -t $SESSION 'clear' Enter | Out-Null
Start-Sleep -Milliseconds 700
$null = Send-Tcp "send-keys C-o"
Start-Sleep -Milliseconds 200
& $PSMUX send-keys -t $SESSION 'TCPMARK2' Enter | Out-Null
Start-Sleep -Seconds 1
$capTcpO = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String

# C-o on TCP path should still produce ^O.
if ($capTcpO -match '\^O') { Write-Pass "TCP send-keys C-o renders as ^O" }
else { Write-Fail "TCP send-keys C-o did not render as ^O" }

# C-/ on TCP path must NOT match ^O.
if ($capTcpSlash -notmatch '\^O') {
    Write-Pass "TCP send-keys C-/ does not collapse to ^O"
} else {
    Write-Fail "TCP path: C-/ still collapses to ^O"
}

# === Win32 TUI VISUAL VERIFICATION ===
Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan

$SESSION_TUI = "test_issue226_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

& $PSMUX send-keys -t $SESSION_TUI 'clear' Enter | Out-Null
Start-Sleep -Milliseconds 700
& $PSMUX send-keys -t $SESSION_TUI 'C-/' | Out-Null
Start-Sleep -Milliseconds 200
& $PSMUX send-keys -t $SESSION_TUI 'TUIMARK' Enter | Out-Null
Start-Sleep -Seconds 1
$capTui = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
if ($capTui -notmatch '\^O') { Write-Pass "TUI: send-keys C-/ does not collapse to ^O" }
else { Write-Fail "TUI: send-keys C-/ still collapses to ^O" }

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
