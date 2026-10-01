# Issue #402: isolate how the BIND run-shell tokenizes a simple command with a quoted -c arg.
# Test three quoting forms of the SAME new-window command from a bind, check window creation
# AND whether -c actually took effect (pane_current_path).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test402q"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$DIR = "$env:USERPROFILE\psmux_test402\project"
$script:P = 0; $script:F = 0
function Pass($m){Write-Host "  [PASS] $m" -f Green;$script:P++}
function Fail($m){Write-Host "  [FAIL] $m" -f Red;$script:F++}
function Info($m){Write-Host "  [INFO] $m" -f DarkCyan}

# Note: config parsing itself may consume quotes. We write the config with different inner quoting.
$conf = "$env:TEMP\psmux402_q.conf"
$lines = @()
# 1 = single-quoted path inside double-quoted run-shell arg
$lines += "bind-key -T prefix 1 run-shell ""psmux new-window -n W_SQ -c '$DIR'"""
# 2 = unquoted path (no spaces so should be one token)
$lines += "bind-key -T prefix 2 run-shell ""psmux new-window -n W_UQ -c $DIR"""
# 3 = wrap whole thing in pwsh -Command explicitly
$lines += "bind-key -T prefix 3 run-shell ""pwsh -NoProfile -Command \""psmux new-window -n W_PW -c '$DIR'\"""""
$lines -join "`r`n" | Set-Content -Path $conf -Encoding UTF8
Info "config:"
Get-Content $conf | ForEach-Object { Write-Host "      | $_" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null

Info "list-keys as parsed:"
$keys = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
$keys -split "`n" | Where-Object { $_ -match "W_SQ|W_UQ|W_PW" } | ForEach-Object { Write-Host "      | $($_.Trim())" }

function CheckWin($name, $key) {
    & $injector $proc.Id "^b{SLEEP:400}$key"
    Start-Sleep -Seconds 3
    $wins = (& $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Out-String)
    if ($wins -match [regex]::Escape($name)) {
        $path = (& $PSMUX display-message -p -t "${SESSION}:${name}" '#{pane_current_path}' 2>&1).Trim()
        $cok = ($path -replace '/','\') -ieq ($DIR -replace '/','\')
        if ($cok) { Pass "$name created AND -c path applied ($path)" }
        else { Fail "$name created but -c path WRONG (got '$path', wanted '$DIR')" }
    } else {
        Fail "$name NOT created (command malformed by bind tokenizer)"
    }
}

Write-Host "`n=== #402 quote-form isolation ===" -ForegroundColor Cyan
Info "[1] single-quoted -c"; CheckWin "W_SQ" "1"
Info "[2] unquoted -c";      CheckWin "W_UQ" "2"
Info "[3] explicit pwsh -Command wrapper"; CheckWin "W_PW" "3"

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Write-Host "`n=== Results: Passed=$($script:P) Failed=$($script:F) ===" -ForegroundColor Cyan
