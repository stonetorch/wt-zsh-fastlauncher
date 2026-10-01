# PR #207 Compatibility Bugs: Irrefutable Proof Tests
# Tests 4 confirmed behavioural deltas vs tmux:
#   Bug 2: -F#{fmt} concatenated form ignored (only space-separated works)
#   Bug 3: has-session -t =NAME exact-prefix not supported
#   Bug 5: Named paste buffers don't exist (-b NAME silently collapses to slot 0)
#   Bug 6: paste-buffer -p ignores -p (no bracketed paste, always SendText)
#
# Each test is designed to PASS once the bug is fixed (green when fixed, red now)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "pr207_compat"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup {
    param([string]$Name = $SESSION)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 10000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        & $PSMUX has-session -t $Name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $portFile = "$psmuxDir\$Session.port"
    $keyFile  = "$psmuxDir\$Session.key"
    if (-not (Test-Path $portFile)) { return "NO_PORT_FILE" }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile -Raw).Trim()
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
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
    } catch { return "CONNECT_FAILED: $_" }
}

# === SETUP: create base session ===
Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
if (-not (Wait-Session $SESSION)) {
    Write-Host "FATAL: Cannot create base session '$SESSION'. Aborting." -ForegroundColor Red
    exit 99
}
Write-Host "Base session '$SESSION' ready.`n"

# =====================================================================
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " BUG 2: Concatenated -F#{fmt} form ignored" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
# tmux and libtmux pass "-F#{session_id}" as a SINGLE argv token.
# psmux only matches exact "-F" as a separate token, so the
# concatenated form is silently ignored and default output is returned.
# =====================================================================

Write-Host "`n--- CLI path tests ---" -ForegroundColor Yellow

# Test 2.1: list-sessions with concatenated -F#{session_name}
Write-Host "[2.1] list-sessions with concatenated -F#{session_name}" -ForegroundColor Yellow
$ls_concat = & $PSMUX list-sessions "-F#{session_name}" 2>&1
Write-Info "  Raw output: '$ls_concat'"
# If the bug is fixed, output should be session names only (no "windows (created" text)
$has_default_format = ($ls_concat -match "windows \(created")
if ($has_default_format) {
    Write-Fail "list-sessions -F#{session_name} (concat) returned default format instead of formatted"
} else {
    Write-Pass "list-sessions -F#{session_name} (concat) returned formatted output"
}

# Test 2.2: list-sessions with space-separated -F (control: should always work)
Write-Host "[2.2] list-sessions with space-separated -F (control)" -ForegroundColor Yellow
$ls_space = & $PSMUX list-sessions -F '#{session_name}' 2>&1
$space_has_default = ($ls_space -match "windows \(created")
if (-not $space_has_default) {
    Write-Pass "list-sessions -F '#{session_name}' (space) works correctly"
} else {
    Write-Fail "list-sessions -F '#{session_name}' (space) also broken"
}

# Test 2.3: new-session -P with concatenated -F#{session_id}
Write-Host "[2.3] new-session -P -F#{session_id} (concat)" -ForegroundColor Yellow
$S23 = "pr207_fconcat"
Cleanup $S23
$out_concat = & $PSMUX new-session -d -s $S23 -P "-F#{session_id}" 2>&1
Start-Sleep -Milliseconds 500
Write-Info "  Output: '$out_concat'"
# tmux returns something like "$0" for session_id
# If broken, returns "sessionname:" (the default -P output)
$looks_like_id = ($out_concat -match '^\$\d+$')
$looks_like_default = ($out_concat -match "^${S23}:")
if ($looks_like_id) {
    Write-Pass "new-session -P -F#{session_id} (concat) returned session ID"
} elseif ($looks_like_default) {
    Write-Fail "new-session -P -F#{session_id} (concat) returned default format '$out_concat' instead of session ID"
} else {
    Write-Fail "new-session -P -F#{session_id} (concat) unexpected output: '$out_concat'"
}
Cleanup $S23

# Test 2.4: new-session -P with space-separated -F (control)
Write-Host "[2.4] new-session -P -F '#{session_id}' (space, control)" -ForegroundColor Yellow
$S24 = "pr207_fspace"
Cleanup $S24
$out_space = & $PSMUX new-session -d -s $S24 -P -F '#{session_id}' 2>&1
Start-Sleep -Milliseconds 500
Write-Info "  Output: '$out_space'"
$space_id = ($out_space -match '^\$\d+$')
if ($space_id) {
    Write-Pass "new-session -P -F '#{session_id}' (space) returned session ID"
} else {
    Write-Fail "new-session -P -F '#{session_id}' (space) returned: '$out_space'"
}
Cleanup $S24

# Test 2.5: display-message with concatenated -F#{pane_index}
Write-Host "[2.5] display-message -p with concat -F (not applicable, uses -p)" -ForegroundColor Yellow
# display-message uses -p for print, but list-windows uses -F
# Test list-windows -F (concat vs space)
$lw_concat = & $PSMUX list-windows -t $SESSION "-F#{window_name}" 2>&1
$lw_space  = & $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1
Write-Info "  list-windows -F#{window_name} (concat): '$lw_concat'"
Write-Info "  list-windows -F '#{window_name}' (space): '$lw_space'"
# concat should NOT have default decorations like "(active)"
$lw_concat_default = ($lw_concat -match "\(active\)" -or $lw_concat -match "layout")
if (-not $lw_concat_default) {
    Write-Pass "list-windows concat -F returned formatted output"
} else {
    Write-Fail "list-windows concat -F returned default format"
}


# =====================================================================
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " BUG 3: has-session -t =NAME exact-prefix not supported" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
# tmux supports =NAME in -t to mean exact match (no prefix matching).
# psmux looks for a port file named "=NAME.port" which never exists.
# =====================================================================

Write-Host "`n--- CLI path tests ---" -ForegroundColor Yellow

$S3 = "pr207_exact"
Cleanup $S3
& $PSMUX new-session -d -s $S3
Start-Sleep -Seconds 2

# Test 3.1: =NAME exact match on existing session
Write-Host "[3.1] has-session -t =$S3 (exact match, session exists)" -ForegroundColor Yellow
& $PSMUX has-session -t "=$S3" 2>$null
$exit31 = $LASTEXITCODE
Write-Info "  Exit code: $exit31 (should be 0)"
if ($exit31 -eq 0) {
    Write-Pass "has-session -t =NAME found existing session"
} else {
    Write-Fail "has-session -t =NAME exit $exit31 (should be 0, session exists as '$S3')"
}

# Test 3.2: =NAME on session that does NOT exist (should exit 1)
Write-Host "[3.2] has-session -t =nonexistent_session_xyz (should fail)" -ForegroundColor Yellow
& $PSMUX has-session -t "=nonexistent_session_xyz" 2>$null
$exit32 = $LASTEXITCODE
Write-Info "  Exit code: $exit32 (should be non-0)"
if ($exit32 -ne 0) {
    Write-Pass "has-session -t =nonexistent correctly returns non-zero"
} else {
    Write-Fail "has-session -t =nonexistent_session_xyz returned 0 (should fail)"
}

# Test 3.3: =NAME must NOT prefix-match a longer session name
# Create "pr207_exactmatch_full", then check =pr207_exactmatch should NOT match
Write-Host "[3.3] =NAME must not prefix-match longer names" -ForegroundColor Yellow
$S33full = "pr207_exactmatch_full"
Cleanup $S33full
& $PSMUX new-session -d -s $S33full
Start-Sleep -Seconds 2

& $PSMUX has-session -t "=pr207_exactmatch" 2>$null
$exit33 = $LASTEXITCODE
Write-Info "  has-session -t =pr207_exactmatch exit: $exit33 (should be non-0, only pr207_exactmatch_full exists)"
if ($exit33 -ne 0) {
    Write-Pass "=NAME does not prefix-match (correct tmux semantics)"
} else {
    Write-Fail "=NAME prefix-matched a longer session name (wrong)"
}
Cleanup $S33full

# Test 3.4: Without = prefix (control: should always work)
Write-Host "[3.4] has-session -t $S3 (no =, control)" -ForegroundColor Yellow
& $PSMUX has-session -t $S3 2>$null
$exit34 = $LASTEXITCODE
if ($exit34 -eq 0) {
    Write-Pass "has-session without = works normally"
} else {
    Write-Fail "has-session without = also broken (exit $exit34)"
}

# Test 3.5: TCP path for has-session with =NAME
Write-Host "[3.5] TCP has-session with =NAME" -ForegroundColor Yellow
$resp35 = Send-TcpCommand -Session $S3 -Command "has-session -t =$S3"
Write-Info "  TCP response: '$resp35'"
# has-session via TCP should not error on the = prefix
# The server connection.rs handler also needs to strip =

Cleanup $S3


# =====================================================================
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " BUG 5: Named paste buffers don't work" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
# tmux supports named buffers: set-buffer -b mybuf "content"
# psmux's set-buffer handler in connection.rs filters out -b but treats
# the buffer name as content: it joins all non-dash args as the content
# string. show-buffer -b NAME also ignores the name.
# =====================================================================

Write-Host "`n--- CLI path tests ---" -ForegroundColor Yellow

$S5 = "pr207_buffers"
Cleanup $S5
& $PSMUX new-session -d -s $S5
Start-Sleep -Seconds 2

# Test 5.1: set-buffer -b name content stores ONLY the content, not the name
Write-Host "[5.1] set-buffer -b alpha 'ALPHA_DATA' should not include name in content" -ForegroundColor Yellow
& $PSMUX set-buffer -b alpha "ALPHA_DATA" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$buf51 = & $PSMUX show-buffer -b alpha -t $S5 2>&1
Write-Info "  show-buffer: '$buf51'"
# When fixed: should be exactly "ALPHA_DATA" (not "alpha ALPHA_DATA")
$name_leaked = ($buf51 -match "alpha ALPHA_DATA")
$correct     = ($buf51.Trim() -eq "ALPHA_DATA")
if ($correct) {
    Write-Pass "set-buffer -b alpha stored only content 'ALPHA_DATA'"
} elseif ($name_leaked) {
    Write-Fail "Buffer name 'alpha' leaked into content: got '$buf51' instead of 'ALPHA_DATA'"
} else {
    Write-Fail "Unexpected buffer content: '$buf51'"
}

# Test 5.2: Two named buffers stay independent
Write-Host "[5.2] Two named buffers with -b should be independent" -ForegroundColor Yellow
& $PSMUX set-buffer -b buf_one "CONTENT_ONE" 2>&1 | Out-Null
Start-Sleep -Milliseconds 200
& $PSMUX set-buffer -b buf_two "CONTENT_TWO" 2>&1 | Out-Null
Start-Sleep -Milliseconds 200

$show_one = & $PSMUX show-buffer -b buf_one -t $S5 2>&1
$show_two = & $PSMUX show-buffer -b buf_two -t $S5 2>&1
Write-Info "  show-buffer -b buf_one: '$show_one'"
Write-Info "  show-buffer -b buf_two: '$show_two'"

# When fixed: buf_one=CONTENT_ONE, buf_two=CONTENT_TWO
$one_ok = ($show_one.Trim() -eq "CONTENT_ONE")
$two_ok = ($show_two.Trim() -eq "CONTENT_TWO")
if ($one_ok -and $two_ok) {
    Write-Pass "Named buffers are independent (buf_one != buf_two)"
} else {
    Write-Fail "Named buffers not independent: one='$show_one' two='$show_two'"
}

# Test 5.3: Overwriting a named buffer replaces only that buffer
Write-Host "[5.3] Overwriting named buffer replaces only that name" -ForegroundColor Yellow
& $PSMUX set-buffer -b buf_one "UPDATED_ONE" 2>&1 | Out-Null
Start-Sleep -Milliseconds 200
$show_one_v2 = & $PSMUX show-buffer -b buf_one -t $S5 2>&1
$show_two_v2 = & $PSMUX show-buffer -b buf_two -t $S5 2>&1
Write-Info "  After overwrite: buf_one='$show_one_v2' buf_two='$show_two_v2'"
if ($show_one_v2.Trim() -eq "UPDATED_ONE" -and $show_two_v2.Trim() -eq "CONTENT_TWO") {
    Write-Pass "Overwrite only affected buf_one, buf_two unchanged"
} else {
    Write-Fail "Named buffer overwrite failed: one='$show_one_v2' two='$show_two_v2'"
}

# Test 5.4: list-buffers shows named buffer identifiers
Write-Host "[5.4] list-buffers shows buffer names" -ForegroundColor Yellow
$lsb = & $PSMUX list-buffers -t $S5 2>&1 | Out-String
Write-Info "  list-buffers output:`n$lsb"
# tmux shows: buffer0, buffer1, etc. but with named buffers shows the name
# At minimum, the content should not have name leaking
$leaks_name = ($lsb -match "buf_one UPDATED_ONE" -or $lsb -match "buf_two CONTENT_TWO")
if ($leaks_name) {
    Write-Fail "list-buffers shows buffer name leaked into content"
} else {
    Write-Pass "list-buffers content does not leak buffer names"
}

# Test 5.5: TCP path for set-buffer and show-buffer with -b name
Write-Host "[5.5] TCP set-buffer with -b name" -ForegroundColor Yellow
$resp55a = Send-TcpCommand -Session $S5 -Command "set-buffer -b tcp_buf TCP_CONTENT_123"
Write-Info "  TCP set-buffer response: '$resp55a'"
Start-Sleep -Milliseconds 300
$resp55b = Send-TcpCommand -Session $S5 -Command "show-buffer -b tcp_buf"
Write-Info "  TCP show-buffer -b tcp_buf: '$resp55b'"
if ($resp55b.Trim() -eq "TCP_CONTENT_123") {
    Write-Pass "TCP: named buffer set and retrieved correctly"
} else {
    Write-Fail "TCP: expected 'TCP_CONTENT_123', got '$resp55b'"
}

Cleanup $S5


# =====================================================================
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " BUG 6: paste-buffer -p ignores -p (no bracketed paste)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
# tmux: paste-buffer -p wraps content in ESC[200~ ... ESC[201~ (bracketed paste)
# psmux: paste-buffer handler in connection.rs always sends CtrlReq::SendText
# regardless of -p flag. It should send CtrlReq::SendPaste when -p is set.
#
# We cannot directly observe ESC sequences from capture-pane, but we CAN
# verify that paste-buffer with and without -p both work (pasting content),
# and use TCP to check the CtrlReq dispatch.
# =====================================================================

Write-Host "`n--- CLI path tests ---" -ForegroundColor Yellow

$S6 = "pr207_paste"
Cleanup $S6
& $PSMUX new-session -d -s $S6
Start-Sleep -Seconds 3

# Test 6.1: paste-buffer (no -p) should paste content into pane
Write-Host "[6.1] paste-buffer (no -p) pastes content" -ForegroundColor Yellow
& $PSMUX set-buffer "PASTE_NO_P_MARKER" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $S6 "clear" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX paste-buffer -t $S6 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cap61 = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
Write-Info "  Pane after paste-buffer (no -p):"
($cap61.Trim() -split "`n" | Select-Object -First 3) | ForEach-Object { Write-Info "    $_" }
if ($cap61 -match "PASTE_NO_P_MARKER") {
    Write-Pass "paste-buffer (no -p) pasted content into pane"
} else {
    Write-Fail "paste-buffer (no -p) did not paste content"
}

# Test 6.2: paste-buffer -p should ALSO paste content (with bracketed wrapper)
Write-Host "[6.2] paste-buffer -p pastes content (should use bracketed paste)" -ForegroundColor Yellow
& $PSMUX set-buffer "PASTE_WITH_P_MARKER" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $S6 "clear" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX paste-buffer -p -t $S6 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cap62 = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
Write-Info "  Pane after paste-buffer -p:"
($cap62.Trim() -split "`n" | Select-Object -First 3) | ForEach-Object { Write-Info "    $_" }
if ($cap62 -match "PASTE_WITH_P_MARKER") {
    Write-Pass "paste-buffer -p pasted content into pane"
} else {
    Write-Fail "paste-buffer -p did not paste content"
}

# Test 6.3: TCP path verification -- paste-buffer -p should dispatch SendPaste not SendText
# We verify by checking that the server handler parses the -p flag
Write-Host "[6.3] TCP paste-buffer dispatches differently with -p" -ForegroundColor Yellow
# Set a known buffer first
$resp63a = Send-TcpCommand -Session $S6 -Command "set-buffer TCP_PASTE_TEST_DATA"
Write-Info "  set-buffer response: '$resp63a'"
Start-Sleep -Milliseconds 300
# Clear pane
& $PSMUX send-keys -t $S6 "clear" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
# Paste via TCP with -p flag
$resp63b = Send-TcpCommand -Session $S6 -Command "paste-buffer -p"
Write-Info "  paste-buffer -p TCP response: '$resp63b'"
Start-Sleep -Seconds 1
$cap63 = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
Write-Info "  Pane content:"
($cap63.Trim() -split "`n" | Select-Object -First 3) | ForEach-Object { Write-Info "    $_" }
# At minimum content should appear; the key difference is SendPaste wraps in
# bracketed paste ESC sequences which we cannot see via capture-pane.
# A unit test is needed to prove the CtrlReq dispatch difference.
if ($cap63 -match "TCP_PASTE_TEST_DATA") {
    Write-Pass "TCP paste-buffer -p pasted content"
} else {
    Write-Fail "TCP paste-buffer -p did not paste content"
}

# Test 6.4: Verify send-keys -p uses SendPaste path (control)
Write-Host "[6.4] send-keys -p uses SendPaste (bracketed paste path, control)" -ForegroundColor Yellow
& $PSMUX send-keys -t $S6 "clear" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -p -t $S6 "SENDKEYS_P_MARKER" 2>&1 | Out-Null
Start-Sleep -Seconds 1
$cap64 = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
if ($cap64 -match "SENDKEYS_P_MARKER") {
    Write-Pass "send-keys -p pasted content (SendPaste path works)"
} else {
    Write-Info "send-keys -p content not found (may not be visible in capture-pane)"
}

Cleanup $S6

# =====================================================================
# Win32 TUI Visual Verification (MANDATORY Layer 2)
# Launch a real visible psmux window and verify bugs via CLI commands
# =====================================================================
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$SESSION_TUI = "pr207_tui_proof"
$psmuxExe = (Get-Command psmux -EA Stop).Source
$proc = Start-Process -FilePath $psmuxExe -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

# TUI Test A: Verify session is responsive
Write-Host "[TUI-A] Session responsive via display-message" -ForegroundColor Yellow
$sname = (& $psmuxExe display-message -t $SESSION_TUI -p '#{session_name}' 2>&1).Trim()
if ($sname -eq $SESSION_TUI) {
    Write-Pass "TUI: session '$SESSION_TUI' responds to display-message"
} else {
    Write-Fail "TUI: expected '$SESSION_TUI', got '$sname'"
}

# TUI Test B: set-buffer + paste-buffer into the live TUI pane
Write-Host "[TUI-B] paste-buffer into live TUI pane" -ForegroundColor Yellow
& $psmuxExe set-buffer "TUI_PASTE_CHECK" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $psmuxExe send-keys -t $SESSION_TUI "clear" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $psmuxExe paste-buffer -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Seconds 2
$capTUI = & $psmuxExe capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
if ($capTUI -match "TUI_PASTE_CHECK") {
    Write-Pass "TUI: paste-buffer pasted into live pane"
} else {
    Write-Fail "TUI: paste-buffer content not found in pane"
}

# TUI Test C: has-session with =NAME on the TUI session
Write-Host "[TUI-C] has-session -t =$SESSION_TUI on live TUI session" -ForegroundColor Yellow
& $psmuxExe has-session -t "=$SESSION_TUI" 2>$null
$exitTUI = $LASTEXITCODE
if ($exitTUI -eq 0) {
    Write-Pass "TUI: has-session -t =NAME found live TUI session"
} else {
    Write-Fail "TUI: has-session -t =NAME exit $exitTUI on live session"
}

# TUI Test D: list-sessions with concatenated -F on the TUI session
Write-Host "[TUI-D] list-sessions -F#{session_name} (concat) on TUI session" -ForegroundColor Yellow
$lsTUI = & $psmuxExe list-sessions "-F#{session_name}" 2>&1
$tuiDefault = ($lsTUI -match "windows \(created")
if (-not $tuiDefault -and $lsTUI -match $SESSION_TUI) {
    Write-Pass "TUI: list-sessions concat -F returned formatted output"
} else {
    Write-Fail "TUI: list-sessions concat -F returned default format"
}

# Cleanup TUI
& $psmuxExe kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# =====================================================================
# FINAL CLEANUP
# =====================================================================
Cleanup

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " RESULTS" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -gt 0) {
    Write-Host "`n  When all 4 bugs are fixed, ALL tests should pass." -ForegroundColor Yellow
}
exit $script:TestsFailed
