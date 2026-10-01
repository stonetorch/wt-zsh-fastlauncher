# Issue #370 follow-up: surface warnings for unknown / malformed config
# directives instead of silently ignoring them.
#
# Proves end-to-end that:
#   - a bogus ~/.psmux.conf no longer loads silently: the warnings reach the
#     client's terminal (stderr) AND ~/.psmux/config-warnings.log
#   - good directives in the same file still apply (non-fatal)
#   - a clean config produces NO warnings and removes any stale log
#   - runtime `source-file` surfaces warnings via the status message
#   - the TUI session stays functional

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$env:PSMUX_NO_WARM = "1"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Test-PortAlive($name) {
    $pf = "$psmuxDir\$name.port"
    if (-not (Test-Path $pf)) { return $false }
    $port = (Get-Content $pf -Raw -EA SilentlyContinue).Trim()
    if ($port -notmatch '^\d+$') { return $false }
    try { $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $t.Close(); return $true } catch { return $false }
}
function Cleanup($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    for ($i = 0; $i -lt 40; $i++) { if (-not (Test-PortAlive $name)) { break }; Start-Sleep -Milliseconds 150 }
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 150
}

# Run a detached new-session with a config and capture exact stdout/stderr/exit.
function Invoke-NewSession {
    param([string]$ConfigContent, [string]$Name)
    $conf = "$env:TEMP\$Name.conf"
    $ConfigContent | Set-Content -Path $conf -Encoding UTF8
    Cleanup $Name
    Remove-Item "$psmuxDir\config-warnings.log","$psmuxDir\server-startup.log" -Force -EA SilentlyContinue
    $outFile = "$env:TEMP\$Name.out"; $errFile = "$env:TEMP\$Name.err"
    $env:PSMUX_CONFIG_FILE = $conf
    $p = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-d","-s",$Name `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $p.WaitForExit(30000) | Out-Null
    $env:PSMUX_CONFIG_FILE = $null
    return @{ Exit=$p.ExitCode; Stdout=(Get-Content $outFile -Raw -EA SilentlyContinue); Stderr=(Get-Content $errFile -Raw -EA SilentlyContinue) }
}

# Initial settle
& $PSMUX kill-server 2>&1 | Out-Null
foreach ($n in @("cw_bad","cw_clean","cw_src","cw_tui","__warm__")) { Cleanup $n }
Start-Sleep -Seconds 2

Write-Host "`n=== Issue #370 follow-up: config directive warnings ===" -ForegroundColor Cyan

# --- TEST 1: bogus config surfaces warnings to client stderr (non-fatal) ---
Write-Host "`n[Test 1] Bogus directives surface to client terminal" -ForegroundColor Yellow
$cfg = @'
set -g escape-time 123
totally-bogus-command foo
set -g not-a-real-option hello
set -g escape-time notanumber
set -g status-left "[GOOD]"
set -g mouse maybe
'@
$r = Invoke-NewSession $cfg "cw_bad"
Write-Host "  exit=$($r.Exit)"
Write-Host "  stderr:`n$("$($r.Stderr)".Trim())"
if ($r.Exit -eq 0) { Write-Pass "Non-fatal: session still created (exit 0)" } else { Write-Fail "Expected exit 0 (warnings are non-fatal), got $($r.Exit)" }
if ($r.Stderr -match "config warning") { Write-Pass "Client announces config warnings" } else { Write-Fail "No 'config warning' header on stderr" }
if ($r.Stderr -match "unknown command: totally-bogus-command") { Write-Pass "Unknown command surfaced" } else { Write-Fail "Unknown command not surfaced" }
if ($r.Stderr -match "unknown option 'not-a-real-option'") { Write-Pass "Unknown option surfaced" } else { Write-Fail "Unknown option not surfaced" }
if ($r.Stderr -match "invalid value 'notanumber' for option 'escape-time'") { Write-Pass "Malformed number surfaced" } else { Write-Fail "Malformed number not surfaced" }
if ($r.Stderr -match "invalid value 'maybe' for option 'mouse'") { Write-Pass "Malformed boolean surfaced" } else { Write-Fail "Malformed boolean not surfaced" }
if ($r.Stderr -match ":\d+:") { Write-Pass "Warnings carry file:line location" } else { Write-Fail "No file:line in warnings" }

# --- TEST 2: good directives still applied; log written ---
Write-Host "`n[Test 2] Good directives apply despite bad ones; log written" -ForegroundColor Yellow
$sl = (& $PSMUX show-options -g -v status-left -t cw_bad 2>&1 | Out-String).Trim()
if ($sl -match "GOOD") { Write-Pass "Good option (status-left) applied" } else { Write-Fail "Good option not applied, got: $sl" }
$et = (& $PSMUX show-options -g -v escape-time -t cw_bad 2>&1 | Out-String).Trim()
if ($et -eq "123") { Write-Pass "Bad value did not clobber good escape-time (123)" } else { Write-Fail "escape-time expected 123, got: $et" }
if (Test-Path "$psmuxDir\config-warnings.log") { Write-Pass "config-warnings.log written" } else { Write-Fail "config-warnings.log missing" }
Cleanup "cw_bad"

# --- TEST 3: clean config => no warnings, no stale log ---
Write-Host "`n[Test 3] Clean config produces no warnings and no log" -ForegroundColor Yellow
# Pre-seed a stale log to prove a clean load removes it.
"when (epoch s): 1`nstale warning" | Set-Content "$psmuxDir\config-warnings.log" -Encoding UTF8
$r3 = Invoke-NewSession "set -g escape-time 200`nset -g status-left `"[CLEAN]`"`nset -g mouse on" "cw_clean"
Write-Host "  stderr: $("$($r3.Stderr)".Trim())"
if (-not ($r3.Stderr -match "config warning")) { Write-Pass "No warnings for a clean config" } else { Write-Fail "Clean config wrongly warned" }
if (-not (Test-Path "$psmuxDir\config-warnings.log")) { Write-Pass "Stale log removed on clean load" } else { Write-Fail "Stale log not removed" }
Cleanup "cw_clean"

# --- TEST 4: runtime source-file surfaces via status message ---
# The status message is observable in dump-state (the status line); the CLI
# `display-message` without -p does NOT echo it, so verify via dump-state.
function Get-StatusMessage($name) {
    $port = (Get-Content "$psmuxDir\$name.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$name.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 4000
    $s = $tcp.GetStream(); $w = [System.IO.StreamWriter]::new($s); $r = [System.IO.StreamReader]::new($s)
    $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
    $w.Write("dump-state`n"); $w.Flush()
    $best = $null
    for ($j = 0; $j -lt 80; $j++) { try { $line = $r.ReadLine() } catch { break }; if ($null -eq $line) { break }; if ($line.Length -gt 100) { $best = $line; break } }
    $tcp.Close()
    if ($best -match '"status_message":"([^"]*)"') { return $Matches[1] }
    return ""
}

Write-Host "`n[Test 4] Runtime source-file surfaces warnings via status message" -ForegroundColor Yellow
& $PSMUX new-session -d -s cw_src 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t cw_src 2>$null
if ($LASTEXITCODE -eq 0) {
    $bad = "$env:TEMP\cw_src_bad.conf"
    "set -g status-right `"[SR]`"`nbogus-runtime-cmd x`nset -g another-bad-option y" | Set-Content $bad -Encoding UTF8
    & $PSMUX source-file -t cw_src $bad 2>&1 | Out-Null
    $msg = ""
    for ($i = 0; $i -lt 10; $i++) {
        $msg = Get-StatusMessage "cw_src"
        if ($msg -match "config warning") { break }
        Start-Sleep -Milliseconds 200
    }
    Write-Host "  status message: [$msg]"
    if ($msg -match "config warning") { Write-Pass "source-file set a config-warning status message" } else { Write-Fail "No config-warning status message, got: [$msg]" }
    $sr = (& $PSMUX show-options -g -v status-right -t cw_src 2>&1 | Out-String).Trim()
    if ($sr -match "SR") { Write-Pass "source-file applied the good option too" } else { Write-Fail "good option from source-file not applied: $sr" }
} else { Write-Fail "cw_src session did not start" }
Cleanup "cw_src"

# === Win32 TUI VISUAL VERIFICATION (Strategy A) ===
Write-Host ("`n" + ("=" * 60)) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
$cfgTui = "$env:TEMP\cw_tui.conf"
"set -g status-left `"[TUI]`"`nbogus-tui-directive z" | Set-Content $cfgTui -Encoding UTF8
Cleanup "cw_tui"
$env:PSMUX_CONFIG_FILE = $cfgTui
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","cw_tui" -PassThru
$env:PSMUX_CONFIG_FILE = $null
$tuiLive = $false
for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 300; & $PSMUX has-session -t cw_tui 2>$null; if ($LASTEXITCODE -eq 0) { $tuiLive = $true; break } }
if ($tuiLive) { Write-Pass "TUI: session with a bogus directive still launches (non-fatal)" } else { Write-Fail "TUI: session not live" }
& $PSMUX split-window -v -t cw_tui 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$panes = (& $PSMUX display-message -t cw_tui -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window works (session functional)" } else { Write-Fail "TUI: expected 2 panes, got $panes" }
$slTui = (& $PSMUX show-options -g -v status-left -t cw_tui 2>&1 | Out-String).Trim()
if ($slTui -match "TUI") { Write-Pass "TUI: good option from config applied" } else { Write-Fail "TUI: good option not applied: $slTui" }
Cleanup "cw_tui"
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
