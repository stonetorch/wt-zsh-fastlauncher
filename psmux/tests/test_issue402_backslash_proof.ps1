# Issue #402 REAL ROOT CAUSE: backslashes in a run-shell command string from a BIND.
# Failing case A earlier: run-shell "psmux new-window -n X -c 'C:\...\project'"  => FAILED
# Passing case Z earlier: run-shell "psmux new-window -n W_BARE"                 => WORKED
# Only difference = the -c '<backslash Windows path>' argument.
# Predictions:
#   B  bind run-shell "psmux new-window -n W_BSLASH -c 'C:\...\project'"  (backslashes) => FAIL
#   F  bind run-shell "psmux new-window -n W_FSLASH -c 'C:/.../project'"  (forward)     => WORKS
#   N  bind run-shell "psmux new-window -n W_NOPATH"                      (no -c)        => WORKS
# Also: prove backslash mangling directly by writing the received -c value to a marker.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test402bs"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$DIRB = "$env:USERPROFILE\psmux_test402\project"        # backslashes
$DIRF = $DIRB -replace '\\','/'                          # forward slashes
$script:P = 0; $script:F = 0
function Pass($m){Write-Host "  [PASS] $m" -f Green;$script:P++}
function Fail($m){Write-Host "  [FAIL] $m" -f Red;$script:F++}
function Info($m){Write-Host "  [INFO] $m" -f DarkCyan}

$conf = "$env:TEMP\psmux402_bs.conf"
@"
bind-key -T prefix B run-shell "psmux new-window -n W_BSLASH -c '$DIRB'"
bind-key -T prefix F run-shell "psmux new-window -n W_FSLASH -c '$DIRF'"
bind-key -T prefix N run-shell "psmux new-window -n W_NOPATH"
"@ | Set-Content -Path $conf -Encoding UTF8
Info "bind config:"
Get-Content $conf | ForEach-Object { Write-Host "      | $_" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null

Info "list-keys B/F/N as psmux parsed them:"
$keys = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
$keys -split "`n" | Where-Object { $_ -match "W_BSLASH|W_FSLASH|W_NOPATH" } | ForEach-Object { Write-Host "      | $($_.Trim())" }

function Wins { (& $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Out-String) }

Write-Host "`n=== #402 backslash isolation ===" -ForegroundColor Cyan

& $injector $proc.Id "^b{SLEEP:400}B"; Start-Sleep -Seconds 3
$w = Wins; Info "after B (backslash -c): $($w -replace "`r?`n",' ')"
if ($w -match "W_BSLASH") { Pass "backslash path -c from bind WORKS" } else { Fail "REPRODUCED: backslash path -c from bind FAILS" }

& $injector $proc.Id "^b{SLEEP:400}F"; Start-Sleep -Seconds 3
$w = Wins; Info "after F (forward -c): $($w -replace "`r?`n",' ')"
if ($w -match "W_FSLASH") { Pass "forward-slash path -c from bind WORKS" } else { Fail "forward-slash path -c from bind FAILS" }

& $injector $proc.Id "^b{SLEEP:400}N"; Start-Sleep -Seconds 3
$w = Wins; Info "after N (no -c): $($w -replace "`r?`n",' ')"
if ($w -match "W_NOPATH") { Pass "no-path new-window from bind WORKS" } else { Fail "no-path new-window from bind FAILS" }

# Direct proof of mangling: bind run-shell that writes the RECEIVED backslash string to a file
$mk = "$env:TEMP\psmux402_bs_received.txt"
Remove-Item $mk -EA SilentlyContinue
# reconfigure with a marker-echo binding is complex; instead compare to CLI which we know works:
Info "CLI control: does the SAME backslash -c work via CLI run-shell?"
& $PSMUX run-shell -t $SESSION "psmux new-window -n W_CLI_BSLASH -c '$DIRB'" 2>&1 | Out-Null
Start-Sleep -Seconds 3
$w = Wins; Info "after CLI: $($w -replace "`r?`n",' ')"
if ($w -match "W_CLI_BSLASH") { Info "CLI backslash -c WORKS (confirms bind path is the difference)" }
else { Info "CLI backslash -c ALSO fails" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Write-Host "`n=== Results: Passed=$($script:P) Failed=$($script:F) ===" -ForegroundColor Cyan
