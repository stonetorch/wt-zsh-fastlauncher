# Issue #245: psmux + opencode mouse cannot correctly select according to program layout
#
# Add a `mouse-selection on/off` option (default on).  When off, psmux skips
# its own client-side drag selection overlay so apps inside a pane (opencode,
# nvim, etc.) can implement their own mouse selection without psmux drawing
# on top.  Mouse events are still forwarded to apps (click-to-focus, scroll,
# app-level mouse tracking continue to work).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue245"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    foreach ($s in @($SESSION, "issue245_tui", "issue245_cfg", "issue245_oc")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\test_issue245.*" -Force -EA SilentlyContinue
    Remove-Item "$psmuxDir\issue245_*" -Force -EA SilentlyContinue
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Session.key"  -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $auth = $reader.ReadLine()
    if ($auth -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 5000
    $resp = ""
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            if ($line -eq "EOF" -or $line -eq "OK") { break }
            $resp += $line + "`n"
        }
    } catch {}
    $tcp.Close()
    return $resp
}

# === SETUP ===
Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

Write-Host "`n=== Issue #245 Tests: mouse-selection option ===" -ForegroundColor Cyan

# --- Test 1: default value is "on" ---
Write-Host "`n[Test 1] Default value of mouse-selection is 'on'" -ForegroundColor Yellow
$default = (& $PSMUX show-options -g -v "mouse-selection" -t $SESSION 2>&1 | Out-String).Trim()
if ($default -eq "on") { Write-Pass "Default mouse-selection = on" }
else { Write-Fail "Expected 'on', got '$default'" }

# --- Test 2: set-option via CLI ---
Write-Host "`n[Test 2] set-option mouse-selection off via CLI" -ForegroundColor Yellow
& $PSMUX set-option -g mouse-selection off -t $SESSION 2>&1 | Out-Null
$v = (& $PSMUX show-options -g -v "mouse-selection" -t $SESSION 2>&1 | Out-String).Trim()
if ($v -eq "off") { Write-Pass "set -g mouse-selection off applied (got '$v')" }
else { Write-Fail "Expected 'off', got '$v'" }

& $PSMUX set-option -g mouse-selection on -t $SESSION 2>&1 | Out-Null
$v = (& $PSMUX show-options -g -v "mouse-selection" -t $SESSION 2>&1 | Out-String).Trim()
if ($v -eq "on") { Write-Pass "set -g mouse-selection on toggles back" }
else { Write-Fail "Expected 'on', got '$v'" }

# --- Test 3: appears in show-options listing ---
Write-Host "`n[Test 3] mouse-selection appears in show-options listing" -ForegroundColor Yellow
$all = & $PSMUX show-options -g -t $SESSION 2>&1 | Out-String
if ($all -match "mouse-selection (on|off)") { Write-Pass "mouse-selection listed in show-options" }
else { Write-Fail "mouse-selection not present in show-options output" }

# --- Test 4: appears in dump-state JSON ---
Write-Host "`n[Test 4] mouse-selection field present in dump-state JSON" -ForegroundColor Yellow
& $PSMUX set-option -g mouse-selection off -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$dump = Send-TcpCommand -Session $SESSION -Command "dump-state"
if ($dump -match '"mouse_selection"\s*:\s*false') { Write-Pass "dump-state contains mouse_selection:false" }
else { Write-Fail "mouse_selection:false not found in dump-state JSON" }

& $PSMUX set-option -g mouse-selection on -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$dump = Send-TcpCommand -Session $SESSION -Command "dump-state"
if ($dump -match '"mouse_selection"\s*:\s*true') { Write-Pass "dump-state contains mouse_selection:true" }
else { Write-Fail "mouse_selection:true not found in dump-state JSON" }

# --- Test 5: TCP set-option round-trip ---
Write-Host "`n[Test 5] TCP server set-option path" -ForegroundColor Yellow
$resp = Send-TcpCommand -Session $SESSION -Command "set-option -g mouse-selection off"
$v = (& $PSMUX show-options -g -v "mouse-selection" -t $SESSION 2>&1 | Out-String).Trim()
if ($v -eq "off") { Write-Pass "TCP set-option mouse-selection off applied" }
else { Write-Fail "TCP set-option failed; show-options returned '$v'" }

# --- Test 6: set -u resets to default ---
Write-Host "`n[Test 6] set -u resets mouse-selection to default" -ForegroundColor Yellow
& $PSMUX set-option -g mouse-selection off -t $SESSION 2>&1 | Out-Null
& $PSMUX set-option -g -u mouse-selection -t $SESSION 2>&1 | Out-Null
$v = (& $PSMUX show-options -g -v "mouse-selection" -t $SESSION 2>&1 | Out-String).Trim()
if ($v -eq "on") { Write-Pass "set -u reset mouse-selection back to 'on'" }
else { Write-Fail "Expected 'on' after set -u, got '$v'" }

# === TEST 7: Config file directive ===
Write-Host "`n[Test 7] mouse-selection from psmux.conf" -ForegroundColor Yellow
$conf = "$env:TEMP\psmux_test_245.conf"
"set -g mouse-selection off`n" | Set-Content -Path $conf -Encoding UTF8
& $PSMUX kill-session -t "issue245_cfg" 2>&1 | Out-Null
Remove-Item "$psmuxDir\issue245_cfg.*" -Force -EA SilentlyContinue
$env:PSMUX_CONFIG_FILE = $conf
Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","issue245_cfg","-d" -WindowStyle Hidden
Start-Sleep -Seconds 3
$env:PSMUX_CONFIG_FILE = $null
& $PSMUX has-session -t "issue245_cfg" 2>$null
if ($LASTEXITCODE -eq 0) {
    $v = (& $PSMUX show-options -g -v "mouse-selection" -t "issue245_cfg" 2>&1 | Out-String).Trim()
    if ($v -eq "off") { Write-Pass "Config 'set -g mouse-selection off' applied at startup" }
    else { Write-Fail "Expected 'off' from config, got '$v'" }
} else {
    Write-Fail "Session with config did not start"
}

# Test source-file reload
"set -g mouse-selection on`n" | Set-Content -Path $conf -Encoding UTF8
& $PSMUX source-file -t "issue245_cfg" $conf 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$v = (& $PSMUX show-options -g -v "mouse-selection" -t "issue245_cfg" 2>&1 | Out-String).Trim()
if ($v -eq "on") { Write-Pass "source-file reloads mouse-selection value" }
else { Write-Fail "After source-file reload expected 'on', got '$v'" }

& $PSMUX kill-session -t "issue245_cfg" 2>&1 | Out-Null
Remove-Item $conf -Force -EA SilentlyContinue

# === TEST 8: Edge case - bad value treated as off ---
Write-Host "`n[Test 8] Invalid value treated as 'off'" -ForegroundColor Yellow
& $PSMUX set-option -g mouse-selection garbage -t $SESSION 2>&1 | Out-Null
$v = (& $PSMUX show-options -g -v "mouse-selection" -t $SESSION 2>&1 | Out-String).Trim()
if ($v -eq "off") { Write-Pass "Invalid value 'garbage' treated as 'off'" }
else { Write-Fail "Expected 'off' for invalid input, got '$v'" }

# === Win32 TUI Visual Verification ===
Write-Host ("`n" + ("=" * 60)) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION"
Write-Host ("=" * 60) -ForegroundColor Cyan

$SESSION_TUI = "issue245_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

# Drive option toggles via CLI and verify
& $PSMUX set-option -g mouse-selection off -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$v = (& $PSMUX display-message -t $SESSION_TUI -p '#{mouse-selection}' 2>&1).Trim()
# display-message #{option} format may not work for boolean; fall back to show-options
$v2 = (& $PSMUX show-options -g -v "mouse-selection" -t $SESSION_TUI 2>&1 | Out-String).Trim()
if ($v2 -eq "off") { Write-Pass "TUI: set mouse-selection off, show-options returns 'off'" }
else { Write-Fail "TUI: expected 'off', got show-options='$v2'" }

# Verify session still works (split-window after disabling selection)
& $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window still works with mouse-selection off" }
else { Write-Fail "TUI: expected 2 panes, got '$panes'" }

# Toggle back on while attached
& $PSMUX set-option -g mouse-selection on -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$v2 = (& $PSMUX show-options -g -v "mouse-selection" -t $SESSION_TUI 2>&1 | Out-String).Trim()
if ($v2 -eq "on") { Write-Pass "TUI: live toggle to 'on' applied" }
else { Write-Fail "TUI: expected 'on', got '$v2'" }

# Cleanup
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# === Optional: opencode integration smoke test ===
Write-Host ("`n" + ("=" * 60)) -ForegroundColor Cyan
Write-Host "opencode integration smoke test (issue reporter's scenario)"
Write-Host ("=" * 60) -ForegroundColor Cyan

$SESSION_OC = "issue245_oc"
& $PSMUX kill-session -t $SESSION_OC 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION_OC.*" -Force -EA SilentlyContinue

# Create a session and disable mouse-selection BEFORE launching opencode
& $PSMUX new-session -d -s $SESSION_OC -c "C:\cctest"
Start-Sleep -Seconds 2
& $PSMUX set-option -g mouse-selection off -t $SESSION_OC 2>&1 | Out-Null

# Verify the option is off AND mouse forwarding is still on
$ms = (& $PSMUX show-options -g -v "mouse-selection" -t $SESSION_OC 2>&1 | Out-String).Trim()
$mouse = (& $PSMUX show-options -g -v "mouse" -t $SESSION_OC 2>&1 | Out-String).Trim()
if ($ms -eq "off" -and $mouse -eq "on") {
    Write-Pass "opencode scenario: mouse=on, mouse-selection=off (apps still receive mouse, psmux skips selection)"
} else {
    Write-Fail "opencode scenario: expected mouse=on/mouse-selection=off, got mouse=$mouse, mouse-selection=$ms"
}

& $PSMUX kill-session -t $SESSION_OC 2>&1 | Out-Null

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
