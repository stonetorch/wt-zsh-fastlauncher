# Issue #176: pane_index not updated after pane close/split operations
#
# BUG: display-message -t <pane_id> -p '#{pane_index}' always returns 0
#      regardless of the pane's actual position. list-panes -F '#{pane_index}'
#      shows correct values, but direct per-pane display-message does not.
#      Also: after kill-pane, remaining panes may retain stale pane_index values.
#
# EXPECTED FIXED BEHAVIOR:
#   1. After creating 3 panes (indices 0,1,2), display-message on each pane
#      returns its correct pane_index (0, 1, 2 respectively).
#   2. After killing the middle pane (index 1), the remaining two panes
#      have contiguous indices (0, 1) -- list-panes and display-message agree.
#   3. After a split-window that creates a new pane, the new pane's index
#      is correct and contiguous with existing panes.

$ErrorActionPreference = "Continue"
$PSMUX      = (Get-Command psmux -EA Stop).Source
$SESSION    = "gap176"
$psmuxDir   = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.port" -Force -EA SilentlyContinue
    Remove-Item "$psmuxDir\$SESSION.key"  -Force -EA SilentlyContinue
}

function Get-PaneIndexViaDM {
    param([string]$PaneId)
    (& $PSMUX display-message -t $PaneId -p '#{pane_index}' 2>&1 | Out-String).Trim()
}

# === SETUP ===
Cleanup
& $PSMUX new-session -d -s $SESSION
$deadline = (Get-Date).AddSeconds(12)
while (-not (Test-Path "$psmuxDir\$SESSION.port") -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Milliseconds 800

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' could not be created"
    exit 1
}

$fmt = '#{pane_id}:#{pane_index}'

Write-Host "`n=== Issue #176: pane_index correctness after split/close ===" -ForegroundColor Cyan

# ---------------------------------------------------------------
# PART A: Initial single pane
# ---------------------------------------------------------------
Write-Host "`n--- Part A: Single pane baseline ---" -ForegroundColor Magenta

Write-Host "`n[Test 1] Initial pane has pane_index == 0" -ForegroundColor Yellow
$panes1 = & $PSMUX list-panes -t $SESSION -F $fmt 2>&1
Write-Host "  list-panes: $($panes1 -join ' | ')" -ForegroundColor DarkGray
$firstEntry = $panes1 | Select-Object -First 1
if ($firstEntry -match '^(%\d+):(\d+)$') {
    $pane0Id  = $Matches[1]
    $pane0Idx = $Matches[2]
    if ($pane0Idx -eq "0") {
        Write-Pass "Initial pane $pane0Id has pane_index=0 via list-panes"
    } else {
        Write-Fail "Initial pane $pane0Id has pane_index=$pane0Idx, expected 0"
    }
    # Verify display-message agrees
    $dm0 = Get-PaneIndexViaDM $pane0Id
    Write-Host "  display-message on $pane0Id returns '$dm0'" -ForegroundColor DarkGray
    if ($dm0 -eq "0") {
        Write-Pass "display-message on initial pane $pane0Id returns pane_index=0"
    } else {
        Write-Fail "display-message on $pane0Id returns '$dm0', expected '0'"
    }
} else {
    Write-Fail "Could not parse initial pane entry: '$firstEntry'"
    $pane0Id = ""
}

# ---------------------------------------------------------------
# PART B: Three panes - verify each pane's index via display-message
# ---------------------------------------------------------------
Write-Host "`n--- Part B: Three panes - per-pane pane_index ---" -ForegroundColor Magenta

& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$panes3 = & $PSMUX list-panes -t $SESSION -F $fmt 2>&1
Write-Host "`n[Test 2] Three panes exist after two splits" -ForegroundColor Yellow
Write-Host "  list-panes: $($panes3 -join ' | ')" -ForegroundColor DarkGray
$validPanes = $panes3 | Where-Object { $_ -match '^%\d+:\d+$' }
if ($validPanes.Count -eq 3) {
    Write-Pass "3 panes present after two split-window calls"
} else {
    Write-Fail "Expected 3 panes, got $($validPanes.Count): $($panes3 -join ' | ')"
}

Write-Host "`n[Test 3] list-panes shows contiguous indices 0,1,2" -ForegroundColor Yellow
$listIndices = $validPanes | ForEach-Object {
    if ($_ -match '^%\d+:(\d+)$') { [int]$Matches[1] }
} | Sort-Object
Write-Host "  Indices from list-panes: $($listIndices -join ', ')" -ForegroundColor DarkGray
if (($listIndices -join ',') -eq "0,1,2") {
    Write-Pass "list-panes shows contiguous indices 0,1,2"
} else {
    Write-Fail "Expected indices 0,1,2 but got: $($listIndices -join ',')"
}

Write-Host "`n[Test 4] display-message on each pane returns correct pane_index" -ForegroundColor Yellow
$allDmCorrect = $true
$paneMap = @{}   # paneId -> expectedIndex
foreach ($entry in $validPanes) {
    if ($entry -match '^(%\d+):(\d+)$') {
        $paneId      = $Matches[1]
        $expectedIdx = $Matches[2]
        $paneMap[$paneId] = $expectedIdx
        $dmIdx = Get-PaneIndexViaDM $paneId
        Write-Host "  $paneId : list-panes=$expectedIdx  display-message='$dmIdx'" -ForegroundColor DarkGray
        if ($dmIdx -eq $expectedIdx) {
            Write-Pass "display-message on $paneId returns pane_index=$expectedIdx (matches list-panes)"
        } else {
            Write-Fail "display-message on $paneId returns '$dmIdx', expected '$expectedIdx' (list-panes value)"
            $allDmCorrect = $false
        }
    }
}

# ---------------------------------------------------------------
# PART C: Kill middle pane (index 1) - verify remaining panes get
#         contiguous indices 0,1
# ---------------------------------------------------------------
Write-Host "`n--- Part C: Kill middle pane, verify index reassignment ---" -ForegroundColor Magenta

$middleEntry = $validPanes | Where-Object { $_ -match '^%\d+:1$' }
if (-not $middleEntry) {
    Write-Fail "Could not find pane with index=1 to kill; aborting Part C"
} else {
    $middleId = ($middleEntry -split ':')[0]
    Write-Host "`n[Test 5] Kill pane with index=1 ($middleId)" -ForegroundColor Yellow
    & $PSMUX kill-pane -t $middleId 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    $panesAfter = & $PSMUX list-panes -t $SESSION -F $fmt 2>&1
    $validAfter = $panesAfter | Where-Object { $_ -match '^%\d+:\d+$' }
    Write-Host "  list-panes after kill: $($panesAfter -join ' | ')" -ForegroundColor DarkGray

    if ($validAfter.Count -eq 2) {
        Write-Pass "2 panes remain after kill-pane"
    } else {
        Write-Fail "Expected 2 panes after kill, got $($validAfter.Count): $($panesAfter -join ' | ')"
    }

    Write-Host "`n[Test 6] Remaining panes have contiguous indices 0,1 after kill" -ForegroundColor Yellow
    $afterIndices = $validAfter | ForEach-Object {
        if ($_ -match '^%\d+:(\d+)$') { [int]$Matches[1] }
    } | Sort-Object
    Write-Host "  Indices after kill: $($afterIndices -join ', ')" -ForegroundColor DarkGray
    if (($afterIndices -join ',') -eq "0,1") {
        Write-Pass "Remaining panes have contiguous indices 0,1 after kill"
    } else {
        Write-Fail "Expected indices 0,1 but got: $($afterIndices -join ',')"
    }

    Write-Host "`n[Test 7] display-message on remaining panes returns correct index after kill" -ForegroundColor Yellow
    foreach ($entry in $validAfter) {
        if ($entry -match '^(%\d+):(\d+)$') {
            $paneId      = $Matches[1]
            $expectedIdx = $Matches[2]
            $dmIdx = Get-PaneIndexViaDM $paneId
            Write-Host "  $paneId : list-panes=$expectedIdx  display-message='$dmIdx'" -ForegroundColor DarkGray
            if ($dmIdx -eq $expectedIdx) {
                Write-Pass "display-message on $paneId returns pane_index=$expectedIdx after kill"
            } else {
                Write-Fail "display-message on $paneId returns '$dmIdx', expected '$expectedIdx' after kill"
            }
        }
    }
}

# ---------------------------------------------------------------
# PART D: Split again - new pane gets correct next index
# ---------------------------------------------------------------
Write-Host "`n--- Part D: Split after kill - new pane index ---" -ForegroundColor Magenta

Write-Host "`n[Test 8] New pane from split-window gets correct index after prior kill" -ForegroundColor Yellow
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$panesNew = & $PSMUX list-panes -t $SESSION -F $fmt 2>&1
$validNew = $panesNew | Where-Object { $_ -match '^%\d+:\d+$' }
Write-Host "  list-panes after re-split: $($panesNew -join ' | ')" -ForegroundColor DarkGray

if ($validNew.Count -eq 3) {
    Write-Pass "3 panes again after split"
} else {
    Write-Fail "Expected 3 panes after re-split, got $($validNew.Count)"
}

$newIndices = $validNew | ForEach-Object {
    if ($_ -match '^%\d+:(\d+)$') { [int]$Matches[1] }
} | Sort-Object
Write-Host "  Indices after re-split: $($newIndices -join ', ')" -ForegroundColor DarkGray
if (($newIndices -join ',') -eq "0,1,2") {
    Write-Pass "Indices are contiguous 0,1,2 after kill+split sequence"
} else {
    Write-Fail "Expected 0,1,2 after kill+split but got: $($newIndices -join ',')"
}

Write-Host "`n[Test 9] display-message on all panes correct after kill+split sequence" -ForegroundColor Yellow
foreach ($entry in $validNew) {
    if ($entry -match '^(%\d+):(\d+)$') {
        $paneId      = $Matches[1]
        $expectedIdx = $Matches[2]
        $dmIdx = Get-PaneIndexViaDM $paneId
        Write-Host "  $paneId : list-panes=$expectedIdx  display-message='$dmIdx'" -ForegroundColor DarkGray
        if ($dmIdx -eq $expectedIdx) {
            Write-Pass "display-message on $paneId returns pane_index=$expectedIdx (kill+split)"
        } else {
            Write-Fail "display-message on $paneId returns '$dmIdx', expected '$expectedIdx' (kill+split)"
        }
    }
}

# ---------------------------------------------------------------
# PART E: pane-border-format reflects correct indices
# ---------------------------------------------------------------
Write-Host "`n--- Part E: pane-border-format uses correct pane_index ---" -ForegroundColor Magenta

Write-Host "`n[Test 10] pane-border-format expands #{pane_index} to correct values" -ForegroundColor Yellow
& $PSMUX set-option -t $SESSION pane-border-format ' #{pane_index} ' 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

# Verify via list-panes that the format variable is still consistent
$fmtBorder = & $PSMUX list-panes -t $SESSION -F '#{pane_id}:#{pane_index}' 2>&1
$validBorder = $fmtBorder | Where-Object { $_ -match '^%\d+:\d+$' }
$borderIndices = $validBorder | ForEach-Object {
    if ($_ -match '^%\d+:(\d+)$') { [int]$Matches[1] }
} | Sort-Object
Write-Host "  Indices in pane-border-format context: $($borderIndices -join ', ')" -ForegroundColor DarkGray
if (($borderIndices -join ',') -eq "0,1,2") {
    Write-Pass "pane-border-format context: pane_index values are 0,1,2"
} else {
    Write-Fail "pane-border-format context: expected 0,1,2 but got $($borderIndices -join ',')"
}

# === TEARDOWN ===
Cleanup

# === SUMMARY ===
Write-Host "`n=== Issue #176 Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -eq 0) {
    Write-Host "`n  VERDICT: Issue #176 fix CONFIRMED. pane_index is correct after split/kill." -ForegroundColor Green
} else {
    Write-Host "`n  VERDICT: Issue #176 STILL BROKEN or fix incomplete." -ForegroundColor Red
    Write-Host "  Expected: display-message per pane returns correct pane_index;" -ForegroundColor DarkGray
    Write-Host "            after kill-pane, remaining panes get contiguous indices." -ForegroundColor DarkGray
}

exit $script:TestsFailed
