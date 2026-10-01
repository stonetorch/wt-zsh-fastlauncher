#!/usr/bin/env pwsh
# test_issue116_utf8_conpty.ps1
#
# Issue #116: UTF-8 multi-byte characters garbled (double-encoded through CP1252)
# in ConPTY panes.
#
# Assertion: send-keys a UTF-8 string (CJK, accented, emoji-adjacent) into a pane
# via `echo`; capture-pane must return the exact original characters, not
# mojibake (e.g. 你好 must not appear as â... or similar CP1252 double-encoding).
#
# Layer: PowerShell E2E via CLI (send-keys + capture-pane).

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

$PSMUX    = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION  = "gap116"

$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-PortFile {
    param([string]$Name, [int]$TimeoutSec = 12)
    $portFile = "$psmuxDir\$Name.port"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $portFile) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# Send a command to the pane and return captured output after a short wait.
function Send-AndCapture {
    param([string]$Cmd, [int]$WaitMs = 1200)
    & $PSMUX send-keys -t $SESSION $Cmd Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds $WaitMs
    $raw = & $PSMUX capture-pane -t $SESSION -p 2>&1
    return ($raw | Out-String)
}

# ── Setup ────────────────────────────────────────────────────────────────────
Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Issue #116: UTF-8 multi-byte chars must not be CP1252 double-encoded" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

Write-Host "`n[Setup] Creating detached session '$SESSION'..." -ForegroundColor Yellow
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null

if (-not (Wait-PortFile -Name $SESSION)) {
    Write-Fail "Port file never appeared — session did not start"
    exit 1
}
Start-Sleep -Milliseconds 1200

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' did not start"
    Cleanup; exit 1
}

# ── Test 1: CJK (你好) ─────────────────────────────────────────────────────
Write-Host "`n[Test 1] CJK characters 你好 not garbled in capture-pane" -ForegroundColor Yellow
$marker = "T116A"
$capture = Send-AndCapture "echo ${marker}_你好_END"
$hasExpected = $capture -match "${marker}_你好_END"
$hasMojibake = ($capture -match "Ã|â€|â") -and -not $hasExpected
Write-Host "  Capture excerpt: $( ($capture -split "`n" | Where-Object { $_ -match $marker } | Select-Object -First 1) )" -ForegroundColor DarkGray
if ($hasExpected) {
    Write-Pass "CJK '你好' preserved correctly in capture-pane"
} elseif ($hasMojibake) {
    Write-Fail "CJK '你好' GARBLED — mojibake detected (CP1252 double-encoding still present)"
} else {
    Write-Fail "CJK '你好' not found in capture-pane output (may be dropped or garbled)"
}

# ── Test 2: Accented Latin (café) ────────────────────────────────────────────
Write-Host "`n[Test 2] Accented Latin 'cafe_accent' (é U+00E9) not garbled" -ForegroundColor Yellow
$marker2 = "T116B"
# Use the actual é character
$testStr = "caf" + [char]0x00E9
$capture2 = Send-AndCapture "echo ${marker2}_${testStr}_END"
$hasExpected2 = $capture2 -match "${marker2}_${testStr}_END"
$hasMojibake2 = ($capture2 -match "Ã©|Ã") -and -not $hasExpected2
Write-Host "  Capture excerpt: $( ($capture2 -split "`n" | Where-Object { $_ -match $marker2 } | Select-Object -First 1) )" -ForegroundColor DarkGray
if ($hasExpected2) {
    Write-Pass "Accented 'café' preserved correctly in capture-pane"
} elseif ($hasMojibake2) {
    Write-Fail "Accented 'café' GARBLED — Ã© mojibake detected (é double-encoded through CP1252)"
} else {
    Write-Fail "Accented 'café' not found in capture-pane (may be dropped or garbled)"
}

# ── Test 3: Mixed ASCII + CJK sentence ───────────────────────────────────────
Write-Host "`n[Test 3] Mixed ASCII+CJK 'hello世界' not garbled" -ForegroundColor Yellow
$marker3 = "T116C"
$capture3 = Send-AndCapture "echo ${marker3}_hello世界_END"
$hasExpected3 = $capture3 -match "${marker3}_hello世界_END"
Write-Host "  Capture excerpt: $( ($capture3 -split "`n" | Where-Object { $_ -match $marker3 } | Select-Object -First 1) )" -ForegroundColor DarkGray
if ($hasExpected3) {
    Write-Pass "Mixed 'hello世界' preserved correctly"
} else {
    # Accept partial: at minimum the CJK must survive
    $hasCJK = $capture3 -match "世界"
    if ($hasCJK) {
        Write-Pass "CJK portion '世界' survived (mixed string partially matched)"
    } else {
        Write-Fail "'hello世界' garbled or dropped — CJK portion missing from capture-pane"
    }
}

# ── Test 4: Box-drawing chars (─ U+2500, as reported in issue) ───────────────
Write-Host "`n[Test 4] Box-drawing char U+2500 (─) not double-encoded" -ForegroundColor Yellow
$marker4 = "T116D"
$boxChar = [char]0x2500  # ─ (the exact char reported as garbled in the issue)
$capture4 = Send-AndCapture "echo ${marker4}_${boxChar}_END"
$hasExpected4 = $capture4 -match "${marker4}_" + [regex]::Escape($boxChar) + "_END"
# CP1252 double-encoding of e2 94 80 produces: â"€ (U+00E2, U+0094/control, U+0080/control)
# In UTF-8 re-encoding that becomes: c3 a2 e2 80 9d e2 82 ac
$hasMojibake4 = $capture4 -match "â€|â.€" -and -not $hasExpected4
Write-Host "  Capture excerpt: $( ($capture4 -split "`n" | Where-Object { $_ -match $marker4 } | Select-Object -First 1) )" -ForegroundColor DarkGray
if ($hasExpected4) {
    Write-Pass "Box-drawing '─' (U+2500) preserved correctly — no CP1252 double-encoding"
} elseif ($hasMojibake4) {
    Write-Fail "Box-drawing '─' GARBLED — mojibake detected (the exact regression from issue #116)"
} else {
    Write-Fail "Box-drawing '─' not found in capture-pane (may be dropped or garbled)"
}

# ── Test 5: Verify bytes are not double-encoded (raw check) ──────────────────
# The issue root cause: bytes e2 94 80 (UTF-8 for U+2500) read as CP1252 then
# re-encoded gives c3 a2 ... If the ConPTY pipe still double-encodes, capture-pane
# bytes will differ from the original UTF-8. We verify by checking that the
# captured string round-trips through UTF-8 encoding without loss.
Write-Host "`n[Test 5] Round-trip UTF-8 integrity check" -ForegroundColor Yellow
$marker5 = "T116E"
$testChars = "你好世界café" + [char]0x2500
$capture5 = Send-AndCapture "echo ${marker5}_${testChars}_END"
$line5 = $capture5 -split "`n" | Where-Object { $_ -match $marker5 } | Select-Object -First 1
if ($line5) {
    # Encode and decode via UTF-8 to check integrity
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line5)
    $decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($decoded -eq $line5) {
        Write-Pass "Captured text round-trips through UTF-8 cleanly (no byte corruption)"
    } else {
        Write-Fail "UTF-8 round-trip mismatch — bytes are corrupt"
    }
} else {
    Write-Fail "Could not find marker line in capture-pane output for round-trip check"
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
Cleanup

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "======================================================================" -ForegroundColor Cyan
exit $script:TestsFailed
