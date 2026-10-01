# Issue #362: `new-session` in psmux.conf should let `attach-session` create and
# attach to a session when no server is running (tmux behaviour: new-session runs
# from the config at server start).
#
# attach-session takes over the console, so we launch it via Start-Process and
# then verify externally (has-session / port file) that the configured session
# was created.
$ErrorActionPreference="Continue"
$PSMUX=(Get-Command psmux -EA Stop).Source
$psmuxDir="$env:USERPROFILE\.psmux"
$script:Pass=0; $script:Fail=0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

function Kill-All {
    & $PSMUX kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    # Hard-kill every psmux process for true test isolation (attach clients,
    # spawned new-session children, warm servers from a prior test).
    Get-Process psmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 600
    # remove any stale session/warm port+key files so a bare new-session
    # deterministically gets the default name "0"
    Remove-Item "$psmuxDir\0.*","$psmuxDir\sess362.*","$psmuxDir\__warm__.*" -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 400
}
function Wait-Session($name, $timeoutMs=18000) {
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        & $PSMUX has-session -t $name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

Write-Host "=== Issue #362: new-session in config bootstraps attach-session ===" -ForegroundColor Cyan

# --- Test 1: named new-session in config -> attach creates that session ---
Write-Host "[Test 1] config 'new-session -s sess362' + attach-session (no server)" -ForegroundColor Yellow
Kill-All
& $PSMUX kill-session -t sess362 2>&1 | Out-Null
$conf1="$env:TEMP\psmux_362_named.conf"
"set -g mouse on`nnew-session -s sess362" | Set-Content -Path $conf1 -Encoding UTF8
$env:PSMUX_CONFIG_FILE=$conf1
$p1=Start-Process -FilePath $PSMUX -ArgumentList "attach-session" -PassThru -WindowStyle Minimized
if (Wait-Session "sess362") { Write-Pass "attach-session created+started 'sess362' from config new-session" }
else { Write-Fail "session 'sess362' was not created (bug #362 present)" }
$env:PSMUX_CONFIG_FILE=$null
& $PSMUX kill-session -t sess362 2>&1 | Out-Null
try { Stop-Process -Id $p1.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep -Milliseconds 500

# --- Test 2: bare new-session in config -> creates default session "0" ---
Write-Host "[Test 2] config bare 'new-session' + attach-session -> session '0'" -ForegroundColor Yellow
Kill-All
& $PSMUX kill-session -t 0 2>&1 | Out-Null
$conf2="$env:TEMP\psmux_362_bare.conf"
"new-session" | Set-Content -Path $conf2 -Encoding UTF8
$env:PSMUX_CONFIG_FILE=$conf2
$p2=Start-Process -FilePath $PSMUX -ArgumentList "attach-session" -PassThru -WindowStyle Minimized
if (Wait-Session "0") { Write-Pass "bare new-session created+started default session '0'" }
else {
    Write-Fail "default session '0' was not created"
    Write-Host "    DIAG list-sessions: $((& $PSMUX list-sessions 2>&1 | Out-String).Trim())"
    Write-Host "    DIAG port files: $((Get-ChildItem "$psmuxDir\*.port" -EA SilentlyContinue | ForEach-Object { $_.Name }) -join ', ')"
    Write-Host "    DIAG psmux procs: $((Get-Process psmux -EA SilentlyContinue).Count)"
}
$env:PSMUX_CONFIG_FILE=$null
& $PSMUX kill-session -t 0 2>&1 | Out-Null
try { Stop-Process -Id $p2.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep -Milliseconds 500

# --- Test 3: NO new-session in config -> attach still errors (no silent session) ---
Write-Host "[Test 3] config without new-session + attach-session -> no session created" -ForegroundColor Yellow
Kill-All
$conf3="$env:TEMP\psmux_362_none.conf"
"set -g mouse on" | Set-Content -Path $conf3 -Encoding UTF8
$env:PSMUX_CONFIG_FILE=$conf3
$out3 = & $PSMUX attach-session 2>&1 | Out-String
Start-Sleep -Milliseconds 1500
& $PSMUX has-session -t 0 2>$null
$created = ($LASTEXITCODE -eq 0)
$env:PSMUX_CONFIG_FILE=$null
if (-not $created) { Write-Pass "no new-session in config -> attach did not fabricate a session" }
else { Write-Fail "a session was created without a new-session directive" }

# cleanup
Kill-All
Remove-Item "$env:TEMP\psmux_362_*.conf" -Force -EA SilentlyContinue
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
