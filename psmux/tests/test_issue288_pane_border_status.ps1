# Issue #288: pane-border-status bottom/top overlaps pane content
# Tests that pane-border-status correctly reserves 1 row for the border label,
# so it does not overlap the PowerShell input area or pane content.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    param([string]$Name)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 15000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw).Trim()
            if ($port -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# Kill all psmux processes for a clean slate
Get-Process psmux,tmux,pmux -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Remove-Item "$psmuxDir\__warm__.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #288 Tests: pane-border-status height calculation ===" -ForegroundColor Cyan

# ============================================================
# Part A: CLI path tests (detached sessions)
# ============================================================
Write-Host "`n--- Part A: CLI Path (detached sessions) ---" -ForegroundColor Yellow

# Test 1: Baseline without border-status (pane_height == window_height)
Write-Host "`n[Test 1] Baseline: no border-status" -ForegroundColor Yellow
$S = "t288_baseline"
Cleanup $S
& $PSMUX new-session -d -s $S
Start-Sleep -Seconds 4
$h = (& $PSMUX display-message -t $S -p '#{pane_height}' 2>&1).Trim()
$wh = (& $PSMUX display-message -t $S -p '#{window_height}' 2>&1).Trim()
if ([int]$h -eq [int]$wh) { Write-Pass "No border-status: pane_height ($h) == window_height ($wh)" }
else { Write-Fail "Expected pane_height=$wh, got $h" }
Cleanup $S

# Test 2: border-status bottom via config file (single pane)
Write-Host "`n[Test 2] Config: border-status bottom, single pane" -ForegroundColor Yellow
$S = "t288_bottom"
$conf = "$env:TEMP\psmux_t288_bottom.conf"
@"
set -g pane-border-status bottom
set -g pane-border-format "#{pane_index}: #{pane_title}"
"@ | Set-Content -Path $conf -Encoding UTF8
Cleanup $S
$env:PSMUX_CONFIG_FILE = $conf
& $PSMUX new-session -d -s $S
$env:PSMUX_CONFIG_FILE = $null
Start-Sleep -Seconds 4
$h = (& $PSMUX display-message -t $S -p '#{pane_height}' 2>&1).Trim()
$wh = (& $PSMUX display-message -t $S -p '#{window_height}' 2>&1).Trim()
if ([int]$h -eq ([int]$wh - 1)) { Write-Pass "border-status bottom: pane_height ($h) = window_height ($wh) - 1" }
else { Write-Fail "Expected pane_height=$([int]$wh - 1), got $h (window=$wh)" }

# Test 3: border-status bottom with split panes
Write-Host "`n[Test 3] Split panes with border-status bottom" -ForegroundColor Yellow
& $PSMUX split-window -v -t $S 2>&1 | Out-Null
Start-Sleep -Seconds 2
$h0 = (& $PSMUX display-message -t "${S}:0.0" -p '#{pane_height}' 2>&1).Trim()
$h1 = (& $PSMUX display-message -t "${S}:0.1" -p '#{pane_height}' 2>&1).Trim()
$total = [int]$h0 + [int]$h1 + 1  # +1 for separator
$expected_max = [int]$wh - 2  # -2 for 2 border-status lines
if ($total -le [int]$wh -and [int]$h0 -lt ([int]$wh / 2)) {
    Write-Pass "Split: h0=$h0 h1=$h1 total_with_sep=$total <= window=$wh"
} else {
    Write-Fail "Split heights wrong: h0=$h0 h1=$h1 total=$total window=$wh"
}
Cleanup $S

# Test 4: border-status top via config file
Write-Host "`n[Test 4] Config: border-status top, single pane" -ForegroundColor Yellow
$S = "t288_top"
$conf2 = "$env:TEMP\psmux_t288_top.conf"
@"
set -g pane-border-status top
set -g pane-border-format "#{pane_index}: #{pane_title}"
"@ | Set-Content -Path $conf2 -Encoding UTF8
Cleanup $S
$env:PSMUX_CONFIG_FILE = $conf2
& $PSMUX new-session -d -s $S
$env:PSMUX_CONFIG_FILE = $null
Start-Sleep -Seconds 4
$h = (& $PSMUX display-message -t $S -p '#{pane_height}' 2>&1).Trim()
$wh = (& $PSMUX display-message -t $S -p '#{window_height}' 2>&1).Trim()
if ([int]$h -eq ([int]$wh - 1)) { Write-Pass "border-status top: pane_height ($h) = window_height ($wh) - 1" }
else { Write-Fail "Expected pane_height=$([int]$wh - 1), got $h (window=$wh)" }
Cleanup $S

# Test 5: Runtime set-option toggles height correctly
Write-Host "`n[Test 5] Runtime set-option toggle" -ForegroundColor Yellow
$S = "t288_runtime"
Cleanup $S
Get-Process psmux,tmux,pmux -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Remove-Item "$psmuxDir\__warm__.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $S
Start-Sleep -Seconds 4
$h_off = (& $PSMUX display-message -t $S -p '#{pane_height}' 2>&1).Trim()
& $PSMUX set-option -g -t $S pane-border-status bottom 2>&1 | Out-Null
& $PSMUX set-option -g -t $S pane-border-format '"#P"' 2>&1 | Out-Null
Start-Sleep -Seconds 1
$h_on = (& $PSMUX display-message -t $S -p '#{pane_height}' 2>&1).Trim()
if ([int]$h_on -eq ([int]$h_off - 1)) {
    Write-Pass "Runtime toggle: off=$h_off -> bottom=$h_on (reduced by 1)"
} else {
    Write-Fail "Expected $([int]$h_off - 1) after toggle, got $h_on (was $h_off)"
}

# Test 6: Reset to off restores height
Write-Host "`n[Test 6] Reset to off restores height" -ForegroundColor Yellow
& $PSMUX set-option -g -t $S pane-border-status off 2>&1 | Out-Null
Start-Sleep -Seconds 1
$h_restored = (& $PSMUX display-message -t $S -p '#{pane_height}' 2>&1).Trim()
if ([int]$h_restored -eq [int]$h_off) {
    Write-Pass "Reset to off: height restored to $h_restored"
} else {
    Write-Fail "Expected $h_off after reset, got $h_restored"
}
Cleanup $S

# ============================================================
# Part B: TCP server path tests
# ============================================================
Write-Host "`n--- Part B: TCP Path ---" -ForegroundColor Yellow

Write-Host "`n[Test 7] TCP set-option + verify height" -ForegroundColor Yellow
$S = "t288_tcp"
Cleanup $S
Get-Process psmux,tmux,pmux -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Remove-Item "$psmuxDir\__warm__.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $S
Start-Sleep -Seconds 4
$port = (Get-Content "$psmuxDir\$S.port" -Raw).Trim()
$key = (Get-Content "$psmuxDir\$S.key" -Raw).Trim()

function Send-TcpCmd {
    param([string]$Port, [string]$Key, [string]$Cmd)
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$Port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $Key`n"); $writer.Flush()
    $auth = $reader.ReadLine()
    if ($auth -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Cmd`n"); $writer.Flush()
    $stream.ReadTimeout = 5000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

$resp = Send-TcpCmd -Port $port -Key $key -Cmd "set-option -g pane-border-status bottom"
if ($resp -match "OK|^$") { Write-Pass "TCP set-option returned: $resp" }
else { Write-Fail "TCP set-option unexpected: $resp" }
Start-Sleep -Seconds 1
$h = (& $PSMUX display-message -t $S -p '#{pane_height}' 2>&1).Trim()
$wh = (& $PSMUX display-message -t $S -p '#{window_height}' 2>&1).Trim()
if ([int]$h -lt [int]$wh) { Write-Pass "TCP: pane_height ($h) < window_height ($wh) after set" }
else { Write-Fail "TCP: pane_height ($h) should be < window_height ($wh)" }
Cleanup $S

# ============================================================
# Part C: Capture-pane verification
# ============================================================
Write-Host "`n--- Part C: Content Verification ---" -ForegroundColor Yellow

Write-Host "`n[Test 8] Captured content does not overlap border-status" -ForegroundColor Yellow
$S = "t288_capture"
$conf3 = "$env:TEMP\psmux_t288_cap.conf"
@"
set -g pane-border-status bottom
set -g pane-border-format "#{pane_index}: #{pane_title}"
"@ | Set-Content -Path $conf3 -Encoding UTF8
Cleanup $S
Get-Process psmux,tmux,pmux -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Remove-Item "$psmuxDir\__warm__.*" -Force -EA SilentlyContinue
$env:PSMUX_CONFIG_FILE = $conf3
& $PSMUX new-session -d -s $S
$env:PSMUX_CONFIG_FILE = $null
Start-Sleep -Seconds 4
$h = [int](& $PSMUX display-message -t $S -p '#{pane_height}' 2>&1).Trim()
& $PSMUX send-keys -t $S "clear" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$cap = & $PSMUX capture-pane -t $S -p 2>&1
if ($cap.Count -eq $h) { Write-Pass "Captured $($cap.Count) lines == pane_height $h" }
elseif ($cap.Count -le $h) { Write-Pass "Captured $($cap.Count) lines <= pane_height $h (trimmed blanks)" }
else { Write-Fail "Captured $($cap.Count) lines but pane_height is only $h" }
Cleanup $S

# ============================================================
# Part D: TUI Visual Verification
# ============================================================
Write-Host "`n--- Part D: TUI Visual Verification ---" -ForegroundColor Yellow

Write-Host "`n[Test 9] TUI session with border-status bottom" -ForegroundColor Yellow
$S = "t288_tui"
$conf4 = "$env:TEMP\psmux_t288_tui.conf"
@"
set -g pane-border-status bottom
set -g pane-border-format "#{pane_index}: #{pane_title}"
"@ | Set-Content -Path $conf4 -Encoding UTF8
Cleanup $S
Get-Process psmux,tmux,pmux -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Remove-Item "$psmuxDir\__warm__.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$S -PassThru -Environment @{PSMUX_CONFIG_FILE=$conf4}
Start-Sleep -Seconds 5
& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI session created" }
else { Write-Fail "TUI session not found"; exit 1 }

$h = [int](& $PSMUX display-message -t $S -p '#{pane_height}' 2>&1).Trim()
$wh = [int](& $PSMUX display-message -t $S -p '#{window_height}' 2>&1).Trim()
if ($h -lt $wh) { Write-Pass "TUI single pane: height ($h) < window ($wh)" }
else { Write-Fail "TUI single pane: height ($h) should be < window ($wh)" }

# Split and verify
& $PSMUX split-window -v -t $S 2>&1 | Out-Null
Start-Sleep -Seconds 2
$h0 = [int](& $PSMUX display-message -t "${S}:0.0" -p '#{pane_height}' 2>&1).Trim()
$h1 = [int](& $PSMUX display-message -t "${S}:0.1" -p '#{pane_height}' 2>&1).Trim()
$total = $h0 + $h1 + 1
if ($total -lt $wh) { Write-Pass "TUI split: h0=$h0 h1=$h1 total_with_sep=$total < window=$wh" }
else { Write-Fail "TUI split: total=$total should be < window=$wh" }

Cleanup $S
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# ============================================================
# Cleanup
# ============================================================
Remove-Item "$env:TEMP\psmux_t288_*.conf" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
