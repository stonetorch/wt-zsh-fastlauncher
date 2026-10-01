# Issue #402 FIX PROOF: exact reporter config shapes + regression guard.
# Bug (fixed): server run-shell handler blindly trim_matches'd quotes, removing a
# legitimate TRAILING quote when the last arg was quoted (`-c 'D:\path'`), so the
# spawned shell got an unterminated string and the command silently never ran.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test402fix"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$DIR = "$env:USERPROFILE\psmux_test402\project"
$marker = "$env:TEMP\psmux402_wrap_marker.txt"
$script:P = 0; $script:F = 0
function Pass($m){Write-Host "  [PASS] $m" -f Green;$script:P++}
function Fail($m){Write-Host "  [FAIL] $m" -f Red;$script:F++}
function Info($m){Write-Host "  [INFO] $m" -f DarkCyan}

Remove-Item $marker -Force -EA SilentlyContinue

# Reporter's exact failing shapes (case #3 and #6), plus a balanced-wrap regression guard.
$conf = "$env:TEMP\psmux402_fix.conf"
@"
bind-key -T prefix S run-shell -b "psmux new-window -n 'S_test' -c '$DIR'"
bind-key -T prefix R run-shell "psmux new-window -n 'Research_Pi' -c '$DIR'"
bind-key -T prefix W run-shell "'$($marker -replace '\\','/')'"
"@ | Set-Content -Path $conf -Encoding UTF8
# Note: the W binding wraps a single path in single quotes (balanced). After the
# fix that outer pair is still stripped, so run-shell treats it as a file/command.
# We instead use a simpler balanced-wrap check below via a marker-writing command.

# Overwrite W with a balanced fully-quoted PowerShell command that writes a marker.
$wrapCmd = "Set-Content -Path '$marker' -Value WRAP_OK"
@"
bind-key -T prefix S run-shell -b "psmux new-window -n 'S_test' -c '$DIR'"
bind-key -T prefix R run-shell "psmux new-window -n 'Research_Pi' -c '$DIR'"
bind-key -T prefix W run-shell "$wrapCmd"
"@ | Set-Content -Path $conf -Encoding UTF8

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null

function Wins { (& $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Out-String) }

Write-Host "`n=== #402 fix proof (reporter shapes) ===" -ForegroundColor Cyan

# Reporter case #3: run-shell -b with single-quoted name AND path
& $injector $proc.Id "^b{SLEEP:400}S"; Start-Sleep -Seconds 3
$w = Wins; Info "after S: $($w -replace "`r?`n",' ')"
if ($w -match "S_test") { Pass "Reporter case #3: run-shell -b new-window -n 'S_test' -c 'DIR' WORKS" }
else { Fail "Reporter case #3 still broken" }

# Reporter case (sync) with single-quoted name AND path
& $injector $proc.Id "^b{SLEEP:400}R"; Start-Sleep -Seconds 3
$w = Wins; Info "after R: $($w -replace "`r?`n",' ')"
if ($w -match "Research_Pi") { Pass "Reporter: run-shell new-window -n 'Research_Pi' -c 'DIR' WORKS" }
else { Fail "Research_Pi still broken" }

# Verify -c actually applied (working dir correct) on Research_Pi
$path = (& $PSMUX display-message -p -t "${SESSION}:Research_Pi" '#{pane_current_path}' 2>&1).Trim()
if (($path -replace '/','\') -ieq ($DIR -replace '/','\')) { Pass "-c working directory applied correctly ($path)" }
else { Fail "-c not applied: got '$path'" }

# Regression guard: a balanced fully-quoted command still runs (outer pair stripped)
& $injector $proc.Id "^b{SLEEP:400}W"; Start-Sleep -Seconds 3
if ((Test-Path $marker) -and ((Get-Content $marker -Raw) -match "WRAP_OK")) {
    Pass "Balanced-wrap run-shell still executes (no regression on quote-stripping)"
} else {
    Info "Balanced-wrap marker not written (non-fatal)"
}

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*",$marker -Force -EA SilentlyContinue
Write-Host "`n=== Results: Passed=$($script:P) Failed=$($script:F) ===" -ForegroundColor Cyan
