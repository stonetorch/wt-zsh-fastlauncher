# Issue #218: list-panes -s only returns panes from one window instead of all windows
#
# The fix makes list-panes -s -t <session> iterate ALL windows and return
# every pane across the entire session, not just one window's panes.
#
# Assertion: with a session having 3 windows (1 pane each), list-panes -s
# returns exactly 3 pane lines, not 1.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "gap218"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-ForSession {
    param($name, $timeoutSec = 12)
    $portFile = "$psmuxDir\$name.port"
    for ($i = 0; $i -lt ($timeoutSec * 4); $i++) {
        if (Test-Path $portFile) {
            $rawPort = (Get-Content $portFile -Raw -EA SilentlyContinue).Trim()
            if ($rawPort -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$rawPort)
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Count-NonEmptyLines($text) {
    return ($text -split "`n" | Where-Object { $_.Trim() -ne "" }).Count
}

Write-Host "`n=== Issue #218: list-panes -s returns all windows' panes ===" -ForegroundColor Cyan

# ================================================================
# SETUP: session with 3 windows, 1 pane each (total: 3 panes)
# ================================================================
Cleanup

Start-Process -FilePath $PSMUX -ArgumentList "new-session","-d","-s",$SESSION,"-n","win0" -WindowStyle Hidden

if (-not (Wait-ForSession $SESSION)) {
    Write-Fail "Session '$SESSION' did not start within 12 seconds"
    exit 1
}
Write-Host "  [OK] Session '$SESSION' started" -ForegroundColor DarkGray

# Create windows 1 and 2 (session already has window 0)
& $PSMUX new-window -t $SESSION -n "win1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX new-window -t $SESSION -n "win2" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

# Verify 3 windows exist
$winLines = & $PSMUX list-windows -t $SESSION 2>&1 | Out-String
$winCount = Count-NonEmptyLines $winLines
Write-Host "  [INFO] Windows ($winCount): $($winLines.Trim() -replace "`n"," | ")" -ForegroundColor DarkGray
if ($winCount -ne 3) {
    Write-Fail "Expected 3 windows, got $winCount"
    Cleanup
    exit 1
}

# Verify per-window pane counts (each should be 1)
$baseIdx = $null
$winList = & $PSMUX list-windows -t $SESSION 2>&1
foreach ($line in $winList) {
    if ($line -match '^(\d+):') {
        if ($null -eq $baseIdx) { $baseIdx = [int]$matches[1] }
    }
}
if ($null -eq $baseIdx) { $baseIdx = 0 }

Write-Host "  [INFO] Window base index: $baseIdx" -ForegroundColor DarkGray

# Count per-window panes to establish the expected total
$perWindowCounts = @()
$totalExpected = 0
foreach ($line in $winList) {
    if ($line -match '^(\d+):') {
        $wIdx = $matches[1]
        $wPanes = & $PSMUX list-panes -t "${SESSION}:${wIdx}" 2>&1 | Out-String
        $cnt = Count-NonEmptyLines $wPanes
        $perWindowCounts += $cnt
        $totalExpected += $cnt
        Write-Host "  [INFO] Window ${wIdx}: $cnt pane(s)" -ForegroundColor DarkGray
    }
}
Write-Host "  [INFO] Total expected panes (sum per window): $totalExpected" -ForegroundColor DarkGray

# ================================================================
# Part A: Core assertion - list-panes -s returns all panes
# ================================================================
Write-Host "`n--- Part A: list-panes -s returns total across all windows ---" -ForegroundColor Magenta

# Test 1: Basic count
Write-Host "`n[Test 1] list-panes -s -t $SESSION returns $totalExpected panes" -ForegroundColor Yellow
$allPanes = & $PSMUX list-panes -s -t $SESSION 2>&1 | Out-String
$allPanesCount = Count-NonEmptyLines $allPanes
Write-Host "  [INFO] list-panes -s output ($allPanesCount lines):" -ForegroundColor DarkGray
foreach ($line in ($allPanes -split "`n" | Where-Object { $_.Trim() -ne "" })) {
    Write-Host "    $line" -ForegroundColor DarkGray
}

if ($allPanesCount -eq $totalExpected) {
    Write-Pass "list-panes -s returned $allPanesCount panes (expected $totalExpected)"
} else {
    Write-Fail "list-panes -s returned $allPanesCount panes but expected $totalExpected -- only one window's panes returned (bug #218)"
}

# Test 2: Count is greater than single-window count (proves cross-window aggregation)
Write-Host "`n[Test 2] list-panes -s count exceeds any single window's pane count" -ForegroundColor Yellow
$maxSingleWindow = ($perWindowCounts | Measure-Object -Maximum).Maximum
if ($allPanesCount -gt $maxSingleWindow) {
    Write-Pass "list-panes -s ($allPanesCount) > max single-window panes ($maxSingleWindow): aggregation confirmed"
} else {
    Write-Fail "list-panes -s ($allPanesCount) <= max single-window panes ($maxSingleWindow): looks like only one window was counted"
}

# Test 3: With -F flag, each pane line includes the correct window_index
Write-Host "`n[Test 3] list-panes -s -F includes window_index for each pane" -ForegroundColor Yellow
$allPanesF = & $PSMUX list-panes -s -t $SESSION -F "#{window_index}:#{pane_index}" 2>&1
$fLines = $allPanesF | Where-Object { $_.Trim() -ne "" }
Write-Host "  [INFO] Formatted output:" -ForegroundColor DarkGray
foreach ($line in $fLines) { Write-Host "    $line" -ForegroundColor DarkGray }

$uniqueWindowIndices = $fLines | ForEach-Object { ($_ -split ':')[0] } | Select-Object -Unique
Write-Host "  [INFO] Unique window indices seen: $($uniqueWindowIndices -join ', ')" -ForegroundColor DarkGray

if ($uniqueWindowIndices.Count -ge 2) {
    Write-Pass "list-panes -s -F shows panes from $($uniqueWindowIndices.Count) distinct windows"
} else {
    Write-Fail "list-panes -s -F only shows window index(es): $($uniqueWindowIndices -join ', ') -- should span multiple windows"
}

# ================================================================
# Part B: Regression - list-panes WITHOUT -s still targets one window
# ================================================================
Write-Host "`n--- Part B: list-panes without -s still scopes to one window ---" -ForegroundColor Magenta

Write-Host "`n[Test 4] list-panes -t session:win0 (no -s) returns only win0 panes" -ForegroundColor Yellow
$win0Panes = & $PSMUX list-panes -t "${SESSION}:win0" 2>&1 | Out-String
$win0Count = Count-NonEmptyLines $win0Panes
Write-Host "  [INFO] win0 pane count: $win0Count" -ForegroundColor DarkGray

if ($win0Count -eq 1) {
    Write-Pass "list-panes without -s returns only $win0Count pane for win0 (correct scope)"
} else {
    Write-Fail "list-panes without -s returned $win0Count panes for win0 (expected 1)"
}

# ================================================================
# Part C: Scaled test - 4 windows with mixed pane counts
# ================================================================
Write-Host "`n--- Part C: Scaled test with 4 windows ---" -ForegroundColor Magenta

$SESSION2 = "gap218b"
& $PSMUX kill-session -t $SESSION2 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
Remove-Item "$psmuxDir\$SESSION2.*" -Force -EA SilentlyContinue

Start-Process -FilePath $PSMUX -ArgumentList "new-session","-d","-s",$SESSION2 -WindowStyle Hidden

if (-not (Wait-ForSession $SESSION2)) {
    Write-Host "  [SKIP] Secondary session did not start, skipping scaled test" -ForegroundColor Yellow
} else {
    # Add 3 more windows (total: 4)
    & $PSMUX new-window -t $SESSION2 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    & $PSMUX new-window -t $SESSION2 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    & $PSMUX new-window -t $SESSION2 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300

    $w2Lines = & $PSMUX list-windows -t $SESSION2 2>&1
    $w2Count = Count-NonEmptyLines ($w2Lines | Out-String)
    Write-Host "  [INFO] Session2 window count: $w2Count" -ForegroundColor DarkGray

    # Compute expected total for session2
    $totalExpected2 = 0
    foreach ($line in $w2Lines) {
        if ($line -match '^(\d+):') {
            $wIdx = $matches[1]
            $wp = & $PSMUX list-panes -t "${SESSION2}:${wIdx}" 2>&1 | Out-String
            $totalExpected2 += Count-NonEmptyLines $wp
        }
    }

    Write-Host "`n[Test 5] list-panes -s on $w2Count-window session returns $totalExpected2 total panes" -ForegroundColor Yellow
    $allPanes2 = & $PSMUX list-panes -s -t $SESSION2 2>&1 | Out-String
    $allPanes2Count = Count-NonEmptyLines $allPanes2
    Write-Host "  [INFO] list-panes -s returned: $allPanes2Count panes" -ForegroundColor DarkGray

    if ($allPanes2Count -eq $totalExpected2) {
        Write-Pass "Scaled: list-panes -s returned $allPanes2Count/$totalExpected2 panes across $w2Count windows"
    } else {
        Write-Fail "Scaled: list-panes -s returned $allPanes2Count but expected $totalExpected2 across $w2Count windows"
    }

    & $PSMUX kill-session -t $SESSION2 2>&1 | Out-Null
    Remove-Item "$psmuxDir\$SESSION2.*" -Force -EA SilentlyContinue
}

# ================================================================
# TEARDOWN
# ================================================================
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

exit $script:TestsFailed
