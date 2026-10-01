# PR #207 Focused Retest: Claims 2, 4, 6
# Fixes test design issues from first pass

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup {
    param([string]$Name)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host " FOCUSED RETEST: Claims 2, 4, 6" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

# =====================================================================
# CLAIM 2 RETEST: Concatenated -F#{} vs space-separated -F #{}
# Key finding from first test:
#   concat:  new-session -P "-F#{session_id}"  =>  "pr207_c2_concat:" (WRONG, should be $0 or similar)
#   space:   new-session -P -F '#{session_id}'  =>  "$0" (CORRECT)
# First test incorrectly said "both formatted" - concat DID return wrong value
# =====================================================================
Write-Host "`n=== CLAIM 2 RETEST ===" -ForegroundColor Yellow

$S_CA = "pr207r_concat"
$S_SP = "pr207r_space"

Cleanup $S_CA; Cleanup $S_SP

# Concatenated form: pass -F and format as ONE argument
$concat_out = & $PSMUX new-session -d -s $S_CA -P "-F#{session_id}" 2>&1
Start-Sleep -Milliseconds 500
Write-Info "Concat  '-F#{session_id}' output: '$concat_out'"

$space_out = & $PSMUX new-session -d -s $S_SP -P -F '#{session_id}' 2>&1
Start-Sleep -Milliseconds 500
Write-Info "Space   '-F' '#{session_id}' output: '$space_out'"

# A correctly formatted session_id in tmux looks like: $0, $1, $2, etc.
# Or psmux may use numeric IDs. Key point: it should NOT be "sessionname:"
$concat_is_session_name = ($concat_out -match "^pr207r_concat:")
$space_is_session_id    = ($space_out  -match '^\$\d+$' -or $space_out -match '^\d+$')

Write-Info ""
Write-Info "Concat output looks like 'sessionname:' (wrong): $concat_is_session_name"
Write-Info "Space output looks like session ID (correct):    $space_is_session_id"

if ($concat_is_session_name -and $space_is_session_id) {
    Write-Fail "CLAIM 2 CONFIRMED: Concatenated -F#{} returns session-name format instead of formatted value"
    Write-Info "  Expected (from tmux): a session ID like '`$0'"
    Write-Info "  Got (concat):         '$concat_out'"
    Write-Info "  Got (space):          '$space_out'"
} elseif (-not $concat_is_session_name -and $space_is_session_id) {
    Write-Pass "CLAIM 2 DISPROVED: Both forms work - concat='$concat_out' space='$space_out'"
} else {
    Write-Info "CLAIM 2 UNCLEAR: concat='$concat_out' space='$space_out'"
}

# Also test list-sessions with concatenated vs space -F
$ls_concat = & $PSMUX list-sessions "-F#{session_name}" 2>&1
$ls_space  = & $PSMUX list-sessions -F '#{session_name}' 2>&1
Write-Info ""
Write-Info "list-sessions -F'#{session_name}' (concat): '$ls_concat'"
Write-Info "list-sessions -F '#{session_name}' (space): '$ls_space'"
$ls_concat_is_default = ($ls_concat -match "windows \(created")
$ls_space_is_default  = ($ls_space  -match "windows \(created")

if ($ls_concat_is_default -and -not $ls_space_is_default) {
    Write-Fail "list-sessions also: concat -F#{} ignored (default format), space works"
} elseif (-not $ls_concat_is_default -and -not $ls_space_is_default) {
    Write-Pass "list-sessions: both forms work for -F"
}

Cleanup $S_CA; Cleanup $S_SP

# =====================================================================
# CLAIM 4 RETEST: -e KEY=VAL env propagation
# First test had PowerShell variable expansion issue - $VAR was expanded by PS
# Fix: use cmd.exe style quoting OR use ps escape `$ to pass literal $
# =====================================================================
Write-Host "`n=== CLAIM 4 RETEST ===" -ForegroundColor Yellow

$S4 = "pr207r_env"
Cleanup $S4

& $PSMUX new-session -d -s $S4 -e "CAO_TEST_VAR=PSMUX_TEST_VALUE_12345"
Start-Sleep -Seconds 3

# IMPORTANT: Use backtick to escape $ so PowerShell doesn't expand it
# This sends the literal string: echo CAO_RESULT=$CAO_TEST_VAR
& $PSMUX send-keys -t $S4 'echo CAO_RESULT=$env:CAO_TEST_VAR' Enter
Start-Sleep -Seconds 2

$captured4 = & $PSMUX capture-pane -t $S4 -p 2>&1 | Out-String
Write-Info "Pane output (PowerShell env var access):"
$shortCap = $captured4.Trim() -split "`n" | Select-Object -First 5
$shortCap | ForEach-Object { Write-Info "  $_" }

# PowerShell uses $env:VAR syntax
if ($captured4 -match "CAO_RESULT=PSMUX_TEST_VALUE_12345") {
    Write-Pass "CLAIM 4 DISPROVED: -e KEY=VAL IS propagated (via `$env:VAR syntax)"
    $envWorksPS = $true
} else {
    Write-Info "Not found via `$env:VAR, trying cmd-style echo %VAR%..."
    $envWorksPS = $false
}

# Also try with PowerShell direct: [System.Environment]::GetEnvironmentVariable
& $PSMUX send-keys -t $S4 '[System.Environment]::GetEnvironmentVariable(''CAO_TEST_VAR'')' Enter
Start-Sleep -Seconds 2
$captured4b = & $PSMUX capture-pane -t $S4 -p 2>&1 | Out-String
$shortCapB = $captured4b.Trim() -split "`n" | Select-Object -First 5
$shortCapB | ForEach-Object { Write-Info "  $_" }

if ($captured4b -match "PSMUX_TEST_VALUE_12345") {
    Write-Pass "CLAIM 4 DISPROVED: -e KEY=VAL IS propagated (via GetEnvironmentVariable)"
} else {
    Write-Fail "CLAIM 4 CONFIRMED: -e KEY=VAL env var NOT found in spawned shell"
    Write-Info "Var appears empty via both `$env:VAR and GetEnvironmentVariable()"
}

Cleanup $S4

# =====================================================================
# CLAIM 6 RETEST: paste-buffer -p (and without -p)
# First test: NEITHER with nor without -p pasted. Investigate why.
# =====================================================================
Write-Host "`n=== CLAIM 6 RETEST ===" -ForegroundColor Yellow

$S6 = "pr207r_paste"
Cleanup $S6

& $PSMUX new-session -d -s $S6
Start-Sleep -Seconds 3

# First verify the session is working by sending a known command
& $PSMUX send-keys -t $S6 "echo ALIVE_MARKER" Enter
Start-Sleep -Seconds 1
$alive = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
Write-Info "Sanity check - send-keys works: $($alive -match 'ALIVE_MARKER')"

# Set buffer using the most basic form (no -b flag)
& $PSMUX set-buffer "PASTE_TEST_MARKER_ABC" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Verify the buffer was set
$bufContent = & $PSMUX show-buffer 2>&1
Write-Info "show-buffer (no args): '$bufContent'"

# Clear pane and paste
& $PSMUX send-keys -t $S6 "clear" Enter
Start-Sleep -Milliseconds 500

# Paste without -p
& $PSMUX paste-buffer -t $S6 2>&1 | Out-Null
Start-Sleep -Seconds 1

$cap_nop = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
Write-Info "After paste-buffer (no -p):"
($cap_nop.Trim() -split "`n" | Select-Object -First 3) | ForEach-Object { Write-Info "  $_" }

if ($cap_nop -match "PASTE_TEST_MARKER_ABC") {
    Write-Pass "paste-buffer (no -p) worked - content pasted"
    $pasteBasicWorks = $true
} else {
    Write-Fail "paste-buffer (no -p) FAILED - nothing pasted"
    $pasteBasicWorks = $false
}

# Now test paste-buffer -p (bracketed paste)
& $PSMUX send-keys -t $S6 "clear" Enter
Start-Sleep -Milliseconds 500

& $PSMUX paste-buffer -p -t $S6 2>&1 | Out-Null
Start-Sleep -Seconds 1

$cap_p = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
Write-Info "After paste-buffer -p:"
($cap_p.Trim() -split "`n" | Select-Object -First 3) | ForEach-Object { Write-Info "  $_" }

if ($cap_p -match "PASTE_TEST_MARKER_ABC") {
    Write-Pass "paste-buffer -p also pasted content"
    Write-Info "NOTE: bracketed paste sequences (ESC[200~/201~) cannot be verified via capture-pane"
    Write-Info "      This claim requires source code inspection to confirm -p handling"
} else {
    Write-Fail "paste-buffer -p FAILED - nothing pasted"
}

# Additional: what does paste-buffer actually need? Try with explicit -b
& $PSMUX set-buffer -b 0 "NAMED_SLOT_ZERO_XYZ" 2>&1 | Out-Null
Start-Sleep -Milliseconds 200
& $PSMUX send-keys -t $S6 "clear" Enter
Start-Sleep -Milliseconds 300
& $PSMUX paste-buffer -b 0 -t $S6 2>&1 | Out-Null
Start-Sleep -Seconds 1
$cap_b0 = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
Write-Info "After paste-buffer -b 0:"
($cap_b0.Trim() -split "`n" | Select-Object -First 3) | ForEach-Object { Write-Info "  $_" }
if ($cap_b0 -match "NAMED_SLOT_ZERO_XYZ") {
    Write-Pass "paste-buffer -b 0 works"
} else {
    Write-Info "paste-buffer -b 0: content not found"
}

Cleanup $S6

Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
exit 0
