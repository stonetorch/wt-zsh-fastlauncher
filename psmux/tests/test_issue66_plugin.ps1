#!/usr/bin/env pwsh
# test_issue66_plugin.ps1
# Verify issue #66: @plugin loading mechanism works.
# A local plugin dir with a plugin.conf that sets a marker option must be applied
# when @plugin references it. This exercises the auto-source codepath.
# Uses a fully isolated temp dir — never touches ~/.psmux/plugins.

$ErrorActionPreference = "Continue"
$exe = (Get-Command psmux -ErrorAction SilentlyContinue).Source
if (-not $exe) { Write-Error "psmux not found in PATH"; exit 1 }

$pass = 0; $fail = 0
$SESSION = "gap66_$(Get-Random -Maximum 99999)"
$PSMUX_DIR = "$env:USERPROFILE\.psmux"
$PLUGINS_DIR = "$PSMUX_DIR\plugins"

function Pass($name) { Write-Host "  PASS: $name" -ForegroundColor Green; $script:pass++ }
function Fail($name) { Write-Host "  FAIL: $name" -ForegroundColor Red; $script:fail++ }
function Info($name) { Write-Host "  INFO: $name" -ForegroundColor Cyan }

function Wait-Port {
    param([string]$Sess, [int]$TimeoutSec = 12)
    $pf = "$PSMUX_DIR\$Sess.port"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $pf) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Kill-Server {
    Get-Process psmux -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
    Remove-Item "$PSMUX_DIR\*.port" -Force -ErrorAction SilentlyContinue
    Remove-Item "$PSMUX_DIR\*.key"  -Force -ErrorAction SilentlyContinue
}

function Get-Opt {
    param([string]$Opt, [string]$Sess)
    (& $exe show-options -g -v $Opt -t $Sess 2>&1 | Out-String).Trim()
}

Write-Host "`n=== Issue #66: @plugin auto-source ===" -ForegroundColor Cyan

# ---- Create an isolated test plugin in ~/.psmux/plugins ----
# Name it uniquely so it does not clash with anything real.
$pluginName = "gap66-test-plugin-$(Get-Random -Maximum 99999)"
$pluginDir  = "$PLUGINS_DIR\$pluginName"
New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null

$markerKey   = "@gap66-plugin-loaded"
$markerValue = "yes-gap66"
Set-Content -Path "$pluginDir\plugin.conf" -Value "set -g $markerKey `"$markerValue`"" -Encoding UTF8
Info "Created plugin at $pluginDir"
Info "plugin.conf sets: $markerKey = $markerValue"

# ---- Write config that references the plugin ----
$confFile = "$env:TEMP\gap66_$SESSION.conf"
Set-Content -Path $confFile -Value "set -g @plugin '$pluginName'" -Encoding UTF8
Info "Config: $confFile"

# ---- Start session with that config ----
Kill-Server
$env:PSMUX_CONFIG_FILE = $confFile
& $exe new-session -d -s $SESSION -x 120 -y 30 2>$null
$env:PSMUX_CONFIG_FILE = $null

if (-not (Wait-Port -Sess $SESSION)) {
    Write-Error "Server did not start within 12s"
    Remove-Item $pluginDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $confFile  -Force -ErrorAction SilentlyContinue
    exit 1
}
Start-Sleep -Milliseconds 800

# ---- Test 1: session started ----
$hasSession = & $exe has-session -t $SESSION 2>$null; $hasSession = ($LASTEXITCODE -eq 0)
if ($hasSession) { Pass "session started with @plugin config" }
else { Fail "session failed to start with @plugin config" }

# ---- Test 2: plugin marker option is applied ----
$val = Get-Opt $markerKey $SESSION
Info "$markerKey = '$val'"
if ($val -eq $markerValue) {
    Pass "@plugin auto-sourced plugin.conf (marker option applied)"
} else {
    Fail "@plugin did NOT apply plugin.conf — $markerKey='$val' expected '$markerValue' (issue #66)"
}

# ---- Test 3: session is functional after plugin load ----
& $exe send-keys -t $SESSION "echo PLUGIN_SESSION_OK" Enter
Start-Sleep -Milliseconds 800
$cap = & $exe capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "PLUGIN_SESSION_OK") { Pass "session is functional after plugin load" }
else { Fail "session not functional after plugin load" }

# ---- Test 4: plugin with org/name format also resolves ----
# Add a second uniquely-named plugin with org prefix style
$plugin2Name = "gap66-org-plugin-$(Get-Random -Maximum 99999)"
$plugin2Dir  = "$PLUGINS_DIR\$plugin2Name"
New-Item -ItemType Directory -Path $plugin2Dir -Force | Out-Null
$marker2Key   = "@gap66-org-loaded"
$marker2Value = "yes-org-gap66"
Set-Content -Path "$plugin2Dir\plugin.conf" -Value "set -g $marker2Key `"$marker2Value`"" -Encoding UTF8

Kill-Server
$conf2 = "$env:TEMP\gap66b_$SESSION.conf"
Set-Content -Path $conf2 -Value "set -g @plugin 'psmux-plugins/$plugin2Name'" -Encoding UTF8
$env:PSMUX_CONFIG_FILE = $conf2
$sess2 = "${SESSION}b"
& $exe new-session -d -s $sess2 -x 120 -y 30 2>$null
$env:PSMUX_CONFIG_FILE = $null

if (Wait-Port -Sess $sess2 -TimeoutSec 12) {
    Start-Sleep -Milliseconds 800
    $val2 = Get-Opt $marker2Key $sess2
    Info "org/name format: $marker2Key = '$val2'"
    if ($val2 -eq $marker2Value) { Pass "org/name @plugin format resolves and sources plugin.conf" }
    else { Fail "org/name @plugin format did not source plugin.conf ($marker2Key='$val2')" }
    & $exe kill-session -t $sess2 2>$null
} else {
    Fail "session with org/name @plugin did not start within 12s"
}

# Cleanup
& $exe kill-session -t $SESSION 2>$null
Kill-Server
Remove-Item $pluginDir  -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $plugin2Dir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $confFile   -Force -ErrorAction SilentlyContinue
Remove-Item $conf2      -Force -ErrorAction SilentlyContinue

Write-Host "`n=== RESULTS: $pass PASS, $fail FAIL ===" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
if ($fail -gt 0) { exit 1 } else { exit 0 }
