# Issue #402 DECISIVE: bind-key dispatch path via REAL keystroke injection
# Reporter's core claim: from a key binding,
#   - display-message  WORKS
#   - new-window       WORKS
#   - run-shell        DOES NOTHING (no window, no effect)
# This test binds all three, injects prefix+key for each, and checks the outcome.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test402bind"
$psmuxDir = "$env:USERPROFILE\.psmux"
$DIR = "$env:USERPROFILE\psmux_test402\project"
$injector = "$env:TEMP\psmux_injector.exe"
$injLog = "$env:TEMP\psmux_inject.log"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

if (-not (Test-Path $injector)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injector tests\injector.cs 2>&1 | Out-Null
}

# --- Build config with the three binding kinds ---
$conf = "$env:TEMP\psmux402_binds.conf"
$dirEsc = $DIR
@"
bind-key -T prefix M display-message "MFIRED402"
bind-key -T prefix D new-window -n BIND_NW -c "$dirEsc"
bind-key -T prefix S run-shell -b "psmux new-window -n BIND_RS -c '$dirEsc'"
bind-key -T prefix A run-shell "psmux new-window -n BIND_RSSYNC -c '$dirEsc'"
"@ | Set-Content -Path $conf -Encoding UTF8
Write-Info "config written to $conf"

# --- Cleanup + launch attached session ---
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "attached session did not start"; exit 1 }

# Confirm bindings registered
$keys = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
Write-Info "Registered S/D/M/A bindings:"
$keys -split "`n" | Where-Object { $_ -match "\b[SDMA]\b" -and ($_ -match "run-shell|new-window|display-message") } | ForEach-Object { Write-Host "      | $($_.Trim())" }

function WinNames { (& $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Out-String) }

Write-Host "`n=== Issue #402: bind-key dispatch via injection ===" -ForegroundColor Cyan

# --- CONTROL 1: prefix + M => display-message (reporter says works) ---
Write-Host "`n[Control M] prefix + M => display-message" -ForegroundColor Yellow
& $injector $proc.Id "^b{SLEEP:400}M"
Start-Sleep -Seconds 1
$statusCap = & $PSMUX capture-pane -p -t $SESSION 2>&1 | Out-String
$msgShown = (& $PSMUX display-message -p -t $SESSION '#{client_last_session}' 2>&1)  # just to ping
# display-message result shows in status line; capture full screen
$fullCap = & $PSMUX capture-pane -p -t $SESSION -S 0 -E 100 2>&1 | Out-String
if ($fullCap -match "MFIRED402" -or $statusCap -match "MFIRED402") { Write-Pass "Control: display-message binding fired (MFIRED402 on screen)" }
else { Write-Info "MFIRED402 not captured in pane (status line may not be in pane capture) - non-decisive" }

# --- CONTROL 2: prefix + D => new-window (reporter says works) ---
Write-Host "`n[Control D] prefix + D => new-window BIND_NW" -ForegroundColor Yellow
$before = WinNames
& $injector $proc.Id "^b{SLEEP:400}D"
Start-Sleep -Seconds 3
$after = WinNames
Write-Info "windows: $($after -replace "`r?`n"," ")"
if ($after -match "BIND_NW") { Write-Pass "Control: bind-key new-window created BIND_NW" }
else { Write-Fail "Control FAILED: bind-key new-window did NOT create BIND_NW (unexpected)" }

# --- SUSPECT: prefix + S => run-shell -b (reporter says does NOTHING) ---
Write-Host "`n[SUSPECT S] prefix + S => run-shell -b ""psmux new-window BIND_RS""" -ForegroundColor Yellow
$beforeS = WinNames
& $injector $proc.Id "^b{SLEEP:400}S"
Start-Sleep -Seconds 3
$afterS = WinNames
Write-Info "windows: $($afterS -replace "`r?`n"," ")"
if ($afterS -match "BIND_RS") { Write-Pass "bind-key run-shell -b created BIND_RS window (NO BUG)" }
else { Write-Fail "REPRODUCED #402: bind-key run-shell -b did NOTHING (no BIND_RS window)" }

# --- SUSPECT 2: prefix + A => run-shell sync ---
Write-Host "`n[SUSPECT A] prefix + A => run-shell (sync) ""psmux new-window BIND_RSSYNC""" -ForegroundColor Yellow
& $injector $proc.Id "^b{SLEEP:400}A"
Start-Sleep -Seconds 3
$afterA = WinNames
Write-Info "windows: $($afterA -replace "`r?`n"," ")"
if ($afterA -match "BIND_RSSYNC") { Write-Pass "bind-key run-shell (sync) created BIND_RSSYNC window (NO BUG)" }
else { Write-Fail "REPRODUCED #402: bind-key run-shell (sync) did NOTHING (no BIND_RSSYNC window)" }

Write-Info "injector log tail:"
if (Test-Path $injLog) { Get-Content $injLog -Tail 12 | ForEach-Object { Write-Host "      | $_" } }

# Cleanup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
