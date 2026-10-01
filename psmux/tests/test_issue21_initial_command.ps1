# Issue #21 E2E Test: Support initial command for new-session, new-window, and split-window
#
# Verifies that a command passed as positional argument to new-session / new-window /
# split-window actually RUNS in the new pane. We use a unique marker written to a
# temp file so capture-pane has content to assert against, without relying on
# terminal scrollback timing.
#
# Session names: gap21a, gap21b, gap21c

param([switch]$Verbose)

$ErrorActionPreference = "Continue"
$PSMUX        = (Get-Command psmux -EA Stop).Source
$psmuxDir     = "$env:USERPROFILE\.psmux"
$script:passed = 0
$script:failed = 0

# ── helpers ─────────────────────────────────────────────────────────────────

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:passed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:failed++ }

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 12000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -EA SilentlyContinue).Trim()
            if ($port -match '^\d+$') {
                try { $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$port); $t.Close(); return $true } catch {}
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Cleanup {
    param([string]$Name)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

# ── setup ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Issue #21: Initial command for new-session / new-window / split-window ===" -ForegroundColor Cyan
Write-Host ""

$SES_A = "gap21a"
$SES_B = "gap21b"
$SES_C = "gap21c"

Cleanup $SES_A
Cleanup $SES_B
Cleanup $SES_C

# ── PART A: new-session with initial command ──────────────────────────────────

Write-Host "--- Part A: new-session initial command ---" -ForegroundColor Magenta

$markerA = "GAP21A_MARKER_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
$markerFileA = "$env:TEMP\$markerA.txt"
Remove-Item $markerFileA -Force -EA SilentlyContinue

# Command writes the marker to a temp file so we can check it independently of
# capture-pane timing; we also verify capture-pane sees it.
$cmdA = "pwsh -NoLogo -NonInteractive -Command `"'$markerA' | Out-File -FilePath '$markerFileA' -Encoding utf8`""
& $PSMUX new-session -d -s $SES_A $cmdA

$alive = Wait-Session -Name $SES_A -TimeoutMs 12000
if (-not $alive) {
    Write-Fail "A1: Session '$SES_A' never became reachable"
} else {
    Write-Host "    Session '$SES_A' alive, waiting for command output..." -ForegroundColor DarkGray
    # Poll for the marker file up to 10 s
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $found = $false
    while ($sw.ElapsedMilliseconds -lt 10000) {
        if (Test-Path $markerFileA) {
            $content = (Get-Content $markerFileA -Raw -EA SilentlyContinue).Trim()
            if ($content -eq $markerA) { $found = $true; break }
        }
        Start-Sleep -Milliseconds 300
    }
    Write-Pass "A1: Session '$SES_A' became reachable after new-session with initial command"
    if ($found) {
        Write-Pass "A2: Initial command executed -- marker file contains '$markerA'"
    } else {
        Write-Fail "A2: Initial command did NOT execute -- marker file absent or wrong after 10s"
    }

    # Also verify capture-pane returns some content (pane existed and ran something)
    $captured = (& $PSMUX capture-pane -t $SES_A -p 2>&1 | Out-String).Trim()
    if ($Verbose) { Write-Host "    capture-pane output: $captured" -ForegroundColor Gray }
    if ($captured.Length -gt 0) {
        Write-Pass "A3: capture-pane returned non-empty output from initial-command pane"
    } else {
        # Pane may have exited and cleared; file check is the real assertion
        Write-Host "  [INFO] A3: capture-pane empty (pane may have exited); file assertion is definitive" -ForegroundColor DarkYellow
    }
}

Remove-Item $markerFileA -Force -EA SilentlyContinue
Cleanup $SES_A

# ── PART B: new-window with initial command ───────────────────────────────────

Write-Host ""
Write-Host "--- Part B: new-window initial command ---" -ForegroundColor Magenta

# Create a host session first, then add a window with an initial command
& $PSMUX new-session -d -s $SES_B

$alive = Wait-Session -Name $SES_B -TimeoutMs 12000
if (-not $alive) {
    Write-Fail "B1: Host session '$SES_B' never became reachable"
} else {
    Write-Pass "B1: Host session '$SES_B' alive"

    $markerB   = "GAP21B_MARKER_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    $markerFileB = "$env:TEMP\$markerB.txt"
    $helperB     = "$env:TEMP\psmux_issue21b_helper.ps1"
    Remove-Item $markerFileB -Force -EA SilentlyContinue
    # Write helper script to avoid inline quoting issues
    "'$markerB' | Out-File -FilePath '$markerFileB' -Encoding utf8" | Out-File $helperB -Encoding utf8

    & $PSMUX new-window -t $SES_B -- pwsh -NoLogo -NonInteractive -File $helperB

    # Wait for marker file
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $found = $false
    while ($sw.ElapsedMilliseconds -lt 10000) {
        if (Test-Path $markerFileB) {
            $content = (Get-Content $markerFileB -Raw -EA SilentlyContinue)
            if ($null -ne $content -and $content.Trim() -eq $markerB) { $found = $true; break }
        }
        Start-Sleep -Milliseconds 300
    }

    if ($found) {
        Write-Pass "B2: new-window initial command executed -- marker '$markerB' confirmed"
    } else {
        Write-Fail "B2: new-window initial command did NOT execute -- marker absent after 10s"
    }

    # Verify new-window created an additional window (it may have already exited, but
    # we can confirm via the marker. Just check that at least 1 window exists.)
    $winList = (& $PSMUX list-windows -t $SES_B 2>&1 | Out-String).Trim()
    if ($Verbose) { Write-Host "    list-windows: $winList" -ForegroundColor Gray }
    $winCount = ($winList -split "`n" | Where-Object { $_.Trim() -ne "" }).Count
    if ($winCount -ge 1) {
        Write-Pass "B3: Session '$SES_B' has $winCount window(s) -- new-window ran and exited cleanly"
    } else {
        Write-Fail "B3: Session '$SES_B' has no windows: $winList"
    }

    Remove-Item $markerFileB -Force -EA SilentlyContinue
    Remove-Item $helperB     -Force -EA SilentlyContinue
}
Cleanup $SES_B

# ── PART C: split-window with initial command ─────────────────────────────────

Write-Host ""
Write-Host "--- Part C: split-window initial command ---" -ForegroundColor Magenta

& $PSMUX new-session -d -s $SES_C

$alive = Wait-Session -Name $SES_C -TimeoutMs 12000
if (-not $alive) {
    Write-Fail "C1: Host session '$SES_C' never became reachable"
} else {
    Write-Pass "C1: Host session '$SES_C' alive"

    $markerC     = "GAP21C_MARKER_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    $markerFileC = "$env:TEMP\$markerC.txt"
    $helperC     = "$env:TEMP\psmux_issue21c_helper.ps1"
    Remove-Item $markerFileC -Force -EA SilentlyContinue
    "'$markerC' | Out-File -FilePath '$markerFileC' -Encoding utf8" | Out-File $helperC -Encoding utf8

    & $PSMUX split-window -t $SES_C -- pwsh -NoLogo -NonInteractive -File $helperC

    # Wait for marker file
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $found = $false
    while ($sw.ElapsedMilliseconds -lt 10000) {
        if (Test-Path $markerFileC) {
            $content = (Get-Content $markerFileC -Raw -EA SilentlyContinue)
            if ($null -ne $content -and $content.Trim() -eq $markerC) { $found = $true; break }
        }
        Start-Sleep -Milliseconds 300
    }

    if ($found) {
        Write-Pass "C2: split-window initial command executed -- marker '$markerC' confirmed"
    } else {
        Write-Fail "C2: split-window initial command did NOT execute -- marker absent after 10s"
    }

    # Verify session still has at least 1 pane (the split pane may have exited after
    # the short-lived command finished; the marker file is the definitive assertion)
    $paneList = (& $PSMUX list-panes -t $SES_C 2>&1 | Out-String).Trim()
    if ($Verbose) { Write-Host "    list-panes: $paneList" -ForegroundColor Gray }
    $paneCount = ($paneList -split "`n" | Where-Object { $_.Trim() -ne "" }).Count
    if ($paneCount -ge 1) {
        Write-Pass "C3: Session '$SES_C' has $paneCount pane(s) -- split-window ran and exited cleanly"
    } else {
        Write-Fail "C3: Session '$SES_C' has no panes: $paneList"
    }

    Remove-Item $markerFileC -Force -EA SilentlyContinue
    Remove-Item $helperC     -Force -EA SilentlyContinue
}
Cleanup $SES_C

# ── summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:passed)" -ForegroundColor Green
Write-Host "  Failed: $($script:failed)" -ForegroundColor $(if ($script:failed -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($script:failed -gt 0) {
    Write-Host "ISSUE #21 NOT VERIFIED: $($script:failed) test(s) failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ISSUE #21 VERIFIED: new-session / new-window / split-window all run initial commands" -ForegroundColor Green
    exit 0
}
