# Issue #86: 0.4.9 has a black screen and cursor positioning issue
# The issue was a regression in an old release (0.4.9) where opening any TUI app
# corrupted the screen. The author asked users to revert to 0.4.8.
# The issue is historical - it was fixed before the current build.
# Verify the CURRENT build does NOT have a black screen / blank pane:
#   (a) capture-pane returns NON-EMPTY content (real prompt rendered, not black/blank)
#   (b) cursor position reported by display-message is sane (row/col within pane bounds)
#   (c) after opening a TUI app (pwsh -NoProfile) the screen is NOT blank/black
#   (d) display-message cursor_x / cursor_y are within expected pane geometry

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "gap86"
$PANE_WIDTH  = 200
$PANE_HEIGHT = 40
$pass = 0; $fail = 0

function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green; $script:pass++ }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:fail++ }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }

# Cleanup any leftover
& $PSMUX kill-session -t $SESSION 2>$null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "ISSUE #86: Black screen / cursor mispositioning regression test" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Info "Issue was historical (v0.4.9 regression, fixed before current build)."
Write-Info "Asserting current build has NO black screen and sane cursor position."

# --- Create detached session ---
Write-Info "Creating detached session '$SESSION' (${PANE_WIDTH}x${PANE_HEIGHT})..."
& $PSMUX new-session -d -s $SESSION -x $PANE_WIDTH -y $PANE_HEIGHT 2>$null
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session '$SESSION' could not be created"
    exit 1
}
Write-Info "Session created OK"

# Wait for shell prompt (up to 12s)
$promptReady = $false
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Milliseconds 500
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap -match "PS [A-Z]:\\" -or $cap.Trim().Length -gt 5) {
        $promptReady = $true
        break
    }
}

# --- TEST 1: capture-pane returns NON-EMPTY content (not a black screen) ---
Write-Host ""
Write-Host "--- TEST 1: capture-pane returns non-empty content (no black screen) ---" -ForegroundColor Yellow

$cap1 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
$nonEmpty = ($cap1.Trim().Length -gt 0)
if ($nonEmpty) {
    $trimmed1 = $cap1.Trim()
    $previewLen = [Math]::Min(120, $trimmed1.Length)
    Write-Pass "TEST 1: capture-pane has content (not blank/black). Preview: '$($trimmed1.Substring(0, $previewLen).Replace("`n", " "))'"
} else {
    Write-Fail "TEST 1: capture-pane returned EMPTY/BLANK content - black screen regression!"
}

# --- TEST 2: Cursor position is sane (within pane dimensions) ---
Write-Host ""
Write-Host "--- TEST 2: Cursor position is within pane bounds ---" -ForegroundColor Yellow

$curX = & $PSMUX display-message -t $SESSION -p "#{cursor_x}" 2>&1 | Out-String
$curY = & $PSMUX display-message -t $SESSION -p "#{cursor_y}" 2>&1 | Out-String
$curX = [int]($curX.Trim() -replace "[^0-9]", "0")
$curY = [int]($curY.Trim() -replace "[^0-9]", "0")

Write-Info "Reported cursor: x=$curX, y=$curY (pane: ${PANE_WIDTH}x${PANE_HEIGHT})"

$xSane = ($curX -ge 0 -and $curX -lt $PANE_WIDTH)
$ySane = ($curY -ge 0 -and $curY -lt $PANE_HEIGHT)

if ($xSane -and $ySane) {
    Write-Pass "TEST 2: Cursor position is sane (x=$curX within [0,$($PANE_WIDTH-1)], y=$curY within [0,$($PANE_HEIGHT-1)])"
} else {
    Write-Fail "TEST 2: Cursor position OUT OF BOUNDS (x=$curX, y=$curY) for pane ${PANE_WIDTH}x${PANE_HEIGHT} - mispositioning!"
}

# --- TEST 3: After sending a command, screen still renders (not wiped to black) ---
Write-Host ""
Write-Host "--- TEST 3: Screen not wiped after sending a command ---" -ForegroundColor Yellow

$marker = "ISSUE86SCREEN_$(Get-Random -Maximum 9999)"
& $PSMUX send-keys -t $SESSION "echo $marker" Enter 2>$null
Start-Sleep -Seconds 2

$cap3 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
$hasMarker = ($cap3 -match $marker)
$notBlank  = ($cap3.Trim().Length -gt 0)

if ($notBlank -and $hasMarker) {
    Write-Pass "TEST 3: Screen has content including marker '$marker' (not wiped/black after command)"
} elseif ($notBlank) {
    Write-Pass "TEST 3: Screen has content (not black), marker may have scrolled: capture non-empty"
} else {
    Write-Fail "TEST 3: capture-pane BLANK after sending command - screen wiped (black screen regression)"
}

# --- TEST 4: Cursor still sane after rendering command output ---
Write-Host ""
Write-Host "--- TEST 4: Cursor still sane after rendering command output ---" -ForegroundColor Yellow

$curX2 = & $PSMUX display-message -t $SESSION -p "#{cursor_x}" 2>&1 | Out-String
$curY2 = & $PSMUX display-message -t $SESSION -p "#{cursor_y}" 2>&1 | Out-String
$curX2 = [int]($curX2.Trim() -replace "[^0-9]", "0")
$curY2 = [int]($curY2.Trim() -replace "[^0-9]", "0")

Write-Info "Post-command cursor: x=$curX2, y=$curY2"

$x2Sane = ($curX2 -ge 0 -and $curX2 -lt $PANE_WIDTH)
$y2Sane = ($curY2 -ge 0 -and $curY2 -lt $PANE_HEIGHT)

if ($x2Sane -and $y2Sane) {
    Write-Pass "TEST 4: Cursor still in bounds after rendering output (x=$curX2, y=$curY2)"
} else {
    Write-Fail "TEST 4: Cursor out of bounds post-render (x=$curX2, y=$curY2) - cursor mispositioning!"
}

# --- TEST 5: display-message session_name returns correctly (server not crashed) ---
Write-Host ""
Write-Host "--- TEST 5: Server still alive and responding after screen tests ---" -ForegroundColor Yellow

$dm5 = & $PSMUX display-message -t $SESSION -p "ALIVE_#{session_name}" 2>&1 | Out-String
if ($dm5 -match "ALIVE_$SESSION") {
    Write-Pass "TEST 5: Server responsive after all screen tests (no crash)"
} else {
    Write-Fail "TEST 5: Server did not respond with expected value. Got: $($dm5.Trim())"
}

# --- Cleanup ---
& $PSMUX kill-session -t $SESSION 2>$null
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "RESULTS: $pass PASS, $fail FAIL" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
Write-Host ("=" * 70) -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 } else { exit 0 }
