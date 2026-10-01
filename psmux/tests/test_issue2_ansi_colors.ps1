#!/usr/bin/env pwsh
# test_issue2_ansi_colors.ps1
# Verify issue #2: ANSI color sequences survive to capture-pane -e output.
# The red SGR sequence (ESC[31m...ESC[0m) must appear in -e capture.

$ErrorActionPreference = "Continue"
$exe = (Get-Command psmux -ErrorAction SilentlyContinue).Source
if (-not $exe) { Write-Error "psmux not found in PATH"; exit 1 }

$pass = 0; $fail = 0
$SESSION = "gap2_$(Get-Random -Maximum 99999)"
$PSMUX_DIR = "$env:USERPROFILE\.psmux"

function Pass($name) { Write-Host "  PASS: $name" -ForegroundColor Green; $script:pass++ }
function Fail($name) { Write-Host "  FAIL: $name" -ForegroundColor Red; $script:fail++ }

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

Write-Host "`n=== Issue #2: ANSI Color Preservation ===" -ForegroundColor Cyan

# Kill any stale session by that name
& $exe kill-session -t $SESSION 2>$null

# Start session
& $exe new-session -d -s $SESSION -x 120 -y 30 2>$null
if (-not (Wait-Port -Sess $SESSION)) {
    Write-Error "Server did not start (no .port file within 12s)"
    exit 1
}
Start-Sleep -Milliseconds 800

# Emit red ANSI text via Write-Host -ForegroundColor Red.
# This causes psmux to render and store ESC[0;91m (bright red) in the pane's cell attributes.
& $exe send-keys -t $SESSION 'Write-Host "REDTEXTISSUE2" -ForegroundColor Red' Enter
Start-Sleep -Seconds 1

# Collect output as arrays to avoid Out-String stripping ESC bytes
$plainLines = & $exe capture-pane -t $SESSION -p 2>&1
$escLines   = & $exe capture-pane -t $SESSION -p -e 2>&1
# Join preserving all bytes
[string]$plain = [string]::Join("`n", ($plainLines | ForEach-Object { [string]$_ }))
[string]$esc   = [string]::Join("`n", ($escLines   | ForEach-Object { [string]$_ }))

# Helper: check if a string contains the ESC byte (0x1B)
function Has-Esc([string]$s) { return ($s.ToCharArray() | Where-Object { [int]$_ -eq 27 }).Count -gt 0 }
# Helper: check if a string contains a specific byte sequence
function Has-SGR([string]$s, [string]$sgr) {
    [string]$needle = [string][char]27 + $sgr
    return $s.Contains($needle)
}

# ---- Test 1: plain capture-pane has no ESC codes (sanity) ----
if (-not (Has-Esc $plain)) { Pass "plain capture-pane has no ESC sequences" }
else { Fail "plain capture-pane unexpectedly contains ESC sequences" }

# ---- Test 2: capture-pane -e contains ESC sequences ----
if (Has-Esc $esc) { Pass "capture-pane -e contains ESC sequences" }
else { Fail "capture-pane -e has NO ESC sequences — colors are stripped (issue #2 not fixed)" }

# ---- Test 3: a red SGR code is present ----
# PowerShell Write-Host -ForegroundColor Red emits ESC[0;91m (bright red).
# Accept ESC[31m (standard red), ESC[91m (bright red), or ESC[0;91m (reset+bright red).
$hasRed = (Has-SGR $esc "[31m") -or (Has-SGR $esc "[91m") -or (Has-SGR $esc "[0;91m") -or (Has-SGR $esc "[0;31m")
if ($hasRed) { Pass "capture-pane -e contains red SGR code (ESC[31m or ESC[91m)" }
else { Fail "capture-pane -e missing red SGR code — color not preserved (issue #2)" }

# ---- Test 4: reset code ESC[0m is present ----
if (Has-SGR $esc "[0m") { Pass "capture-pane -e contains reset SGR code ESC[0m" }
else { Fail "capture-pane -e missing reset SGR code" }

# ---- Test 5: the actual text content is still readable ----
if ($esc.Contains("REDTEXTISSUE2")) { Pass "text content REDTEXTISSUE2 present in -e output" }
else { Fail "text content REDTEXTISSUE2 missing from -e output" }

# Also verify plain capture still has the visible text
if ($plain.Contains("REDTEXTISSUE2")) { Pass "text content also present in plain capture" }
else { Fail "text content REDTEXTISSUE2 missing from plain capture" }

# Cleanup
& $exe kill-session -t $SESSION 2>$null

Write-Host "`n=== RESULTS: $pass PASS, $fail FAIL ===" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
if ($fail -gt 0) { exit 1 } else { exit 0 }
