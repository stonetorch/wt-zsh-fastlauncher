# PR #207 Claims Verification Test
# Tests 6 claimed psmux behavioural deltas vs tmux reported by marcfargas
# MUST PROVE OR DISPROVE each claim with tangible evidence

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "pr207_test"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:Results = @{}

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup {
    param([string]$Name = $SESSION)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 10000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        & $PSMUX has-session -t $Name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# =====================================================================
Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host " PR #207 CLAIMS VERIFICATION - psmux vs tmux compat" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "psmux binary: $PSMUX`n"

# Setup base session
Cleanup
& $PSMUX new-session -d -s $SESSION
if (-not (Wait-Session $SESSION)) {
    Write-Host "FATAL: Cannot create base session. Aborting." -ForegroundColor Red
    exit 1
}
Write-Host "Base session '$SESSION' ready.`n"

# =====================================================================
# CLAIM 1: list-sessions ignores -F
# Expected psmux behaviour if claim is TRUE: returns default format regardless
# Expected if claim is FALSE: returns formatted output matching the -F spec
# =====================================================================
Write-Host "=== CLAIM 1: list-sessions ignores -F ===" -ForegroundColor Yellow

$claim1_spaceF = & $PSMUX list-sessions -F '#{session_name}' 2>&1
$claim1_concat = & $PSMUX list-sessions -F'#{session_name}' 2>&1

Write-Info "list-sessions -F '#{session_name}' (space-separated): '$claim1_spaceF'"
Write-Info "list-sessions -F'#{session_name}' (concatenated): '$claim1_concat'"

# Check if output is JUST the session name (claim is false = format works)
# vs default format like "pr207_test: 1 windows (created ...)"
$isSpaceFormatted = ($claim1_spaceF -match "^$SESSION$" -or $claim1_spaceF.Trim() -eq $SESSION)
$isDefaultFormat = ($claim1_spaceF -match "windows \(created")

if ($isDefaultFormat) {
    Write-Fail "CLAIM 1 CONFIRMED: list-sessions with -F returns default text, not formatted output"
    Write-Info "Got: $claim1_spaceF"
    $script:Results["claim1"] = "CONFIRMED"
} elseif ($isSpaceFormatted) {
    Write-Pass "CLAIM 1 DISPROVED: list-sessions -F correctly returns '#{session_name}' = '$claim1_spaceF'"
    $script:Results["claim1"] = "DISPROVED"
} else {
    Write-Info "CLAIM 1 AMBIGUOUS: output = '$claim1_spaceF'"
    $script:Results["claim1"] = "AMBIGUOUS"
}

# =====================================================================
# CLAIM 2: -F is only honoured when space-separated from format token
# Test: new-session -P -F#{session_id} vs new-session -P -F #{session_id}
# =====================================================================
Write-Host "`n=== CLAIM 2: -F concatenated vs space-separated ===" -ForegroundColor Yellow

$S2_CONCAT = "pr207_c2_concat"
$S2_SPACE  = "pr207_c2_space"
Cleanup $S2_CONCAT
Cleanup $S2_SPACE

# Test concatenated: new-session -P -F#{session_id}
$output_concat = & $PSMUX new-session -d -s $S2_CONCAT -P "-F#{session_id}" 2>&1
Start-Sleep -Milliseconds 800
Write-Info "new-session -P -F#{session_id} (concatenated) output: '$output_concat'"

# Test space-separated: new-session -P -F '#{session_id}'
$output_space = & $PSMUX new-session -d -s $S2_SPACE -P -F '#{session_id}' 2>&1
Start-Sleep -Milliseconds 800
Write-Info "new-session -P -F '#{session_id}' (space) output: '$output_space'"

# session_id should look like $0, $1, $2 etc in tmux; in psmux may differ
# Key check: does space-form give a different (more structured) result than concat form?
$concatLooksFormatted = ($output_concat -match '^\$\d+$' -or $output_concat -match '^[0-9]+$')
$spaceLooksFormatted  = ($output_space  -match '^\$\d+$' -or $output_space  -match '^[0-9]+$')
$concatLooksDefault   = ($output_concat -match "windows \(created" -or $output_concat -match "-s")
$spaceLooksDefault    = ($output_space  -match "windows \(created" -or $output_space  -match "-s")

if ($concatLooksDefault -and -not $spaceLooksDefault) {
    Write-Fail "CLAIM 2 CONFIRMED: Concatenated -F#{} ignored (got default/arg text), space-separated works"
    $script:Results["claim2"] = "CONFIRMED"
} elseif (-not $concatLooksDefault -and -not $spaceLooksDefault) {
    Write-Pass "CLAIM 2 DISPROVED: Both forms return formatted output"
    Write-Info "  Concat: $output_concat"
    Write-Info "  Space:  $output_space"
    $script:Results["claim2"] = "DISPROVED"
} elseif ($concatLooksDefault -and $spaceLooksDefault) {
    Write-Fail "BOTH forms ignored -F (both returned default text)"
    Write-Info "  Concat: $output_concat"
    Write-Info "  Space:  $output_space"
    $script:Results["claim2"] = "BOTH_BROKEN"
} else {
    Write-Info "CLAIM 2 AMBIGUOUS"
    Write-Info "  Concat: $output_concat"
    Write-Info "  Space:  $output_space"
    $script:Results["claim2"] = "AMBIGUOUS"
}

Cleanup $S2_CONCAT
Cleanup $S2_SPACE

# =====================================================================
# CLAIM 3: has-session -t =NAME exact-prefix not supported
# tmux supports =NAME to mean exact match (not prefix match)
# =====================================================================
Write-Host "`n=== CLAIM 3: has-session -t =NAME exact-prefix ===" -ForegroundColor Yellow

# Create session "pr207_abc"
$S3_FULL = "pr207_abc"
$S3_PREFIX_MATCH = "pr207_ab"  # partial match of S3_FULL
Cleanup $S3_FULL

& $PSMUX new-session -d -s $S3_FULL
Start-Sleep -Seconds 2

# Test 1: =pr207_abc (exact match) should succeed
& $PSMUX has-session -t "=$S3_FULL" 2>$null
$exitExact = $LASTEXITCODE
Write-Info "has-session -t =pr207_abc exit code: $exitExact (0=found)"

# Test 2: =pr207_ab (exact match on a prefix that doesn't exist as its own session)
& $PSMUX has-session -t "=$S3_PREFIX_MATCH" 2>$null
$exitPartial = $LASTEXITCODE
Write-Info "has-session -t =pr207_ab (no such session, prefix only) exit code: $exitPartial (should be non-0)"

# Test 3: pr207_abc (no = prefix, normal behaviour)
& $PSMUX has-session -t $S3_FULL 2>$null
$exitNormal = $LASTEXITCODE
Write-Info "has-session -t pr207_abc (no =) exit code: $exitNormal (0=found)"

if ($exitExact -eq 0 -and $exitPartial -ne 0) {
    Write-Pass "CLAIM 3 DISPROVED: =NAME exact-match works correctly (exact=0, partial-prefix=non-0)"
    $script:Results["claim3"] = "DISPROVED"
} elseif ($exitExact -ne 0) {
    Write-Fail "CLAIM 3 CONFIRMED: =NAME not supported - exact match failed (exit=$exitExact)"
    $script:Results["claim3"] = "CONFIRMED"
} elseif ($exitExact -eq 0 -and $exitPartial -eq 0) {
    Write-Fail "CLAIM 3 CONFIRMED: = prefix ignored - both exact and non-existent prefix matched"
    $script:Results["claim3"] = "CONFIRMED_BOTH_MATCH"
}

Cleanup $S3_FULL

# =====================================================================
# CLAIM 4: new-session -e KEY=VAL not propagated into spawned shell
# =====================================================================
Write-Host "`n=== CLAIM 4: -e KEY=VAL env propagation ===" -ForegroundColor Yellow

$S4 = "pr207_env"
Cleanup $S4

# Create session with -e env var
& $PSMUX new-session -d -s $S4 -e "CAO_TEST_VAR=PSMUX_TEST_VALUE_12345"
Start-Sleep -Seconds 3

# Try to read the env var via send-keys + capture
& $PSMUX send-keys -t $S4 'echo CAO_RESULT=$CAO_TEST_VAR' Enter
Start-Sleep -Seconds 2

$captured = & $PSMUX capture-pane -t $S4 -p 2>&1 | Out-String
Write-Info "Pane capture after echoing CAO_TEST_VAR:"
Write-Info $captured.Substring(0, [Math]::Min(300, $captured.Length))

if ($captured -match "CAO_RESULT=PSMUX_TEST_VALUE_12345") {
    Write-Pass "CLAIM 4 DISPROVED: -e KEY=VAL IS propagated into shell (found PSMUX_TEST_VALUE_12345)"
    $script:Results["claim4"] = "DISPROVED"
} elseif ($captured -match "CAO_RESULT=\s*$" -or $captured -match "CAO_RESULT=$") {
    Write-Fail "CLAIM 4 CONFIRMED: -e KEY=VAL NOT propagated - variable is empty in shell"
    $script:Results["claim4"] = "CONFIRMED"
} else {
    Write-Info "CLAIM 4 INCONCLUSIVE - captured:"
    Write-Info $captured
    $script:Results["claim4"] = "INCONCLUSIVE"
}

Cleanup $S4

# =====================================================================
# CLAIM 5: Named paste buffers don't exist
# -b NAME parses as usize, silently uses slot 0 when parse fails
# =====================================================================
Write-Host "`n=== CLAIM 5: Named paste buffers ===" -ForegroundColor Yellow

$S5 = "pr207_buf"
Cleanup $S5

& $PSMUX new-session -d -s $S5
Start-Sleep -Seconds 2

# Set buffer with name "mybuf_alpha"
& $PSMUX set-buffer -b "mybuf_alpha" "ALPHA_CONTENT_999" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Set buffer with name "mybuf_beta"
& $PSMUX set-buffer -b "mybuf_beta" "BETA_CONTENT_777" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Show buffer by name - should return the specific named buffer
$alphaOut = & $PSMUX show-buffer -b "mybuf_alpha" 2>&1
$betaOut  = & $PSMUX show-buffer -b "mybuf_beta" 2>&1

Write-Info "show-buffer -b mybuf_alpha: '$alphaOut'"
Write-Info "show-buffer -b mybuf_beta: '$betaOut'"

# List buffers to see what's there
$bufList = & $PSMUX list-buffers 2>&1 | Out-String
Write-Info "list-buffers output: $($bufList.Substring(0, [Math]::Min(400, $bufList.Length)))"

if ($alphaOut -match "ALPHA_CONTENT_999" -and $betaOut -match "BETA_CONTENT_777") {
    Write-Pass "CLAIM 5 DISPROVED: Named buffers work - alpha='$alphaOut', beta='$betaOut'"
    $script:Results["claim5"] = "DISPROVED"
} elseif ($alphaOut -match "BETA_CONTENT_777" -or $betaOut -match "ALPHA_CONTENT_999") {
    Write-Fail "CLAIM 5 CONFIRMED: Named buffers collide - names are ignored, both writing to same slot"
    $script:Results["claim5"] = "CONFIRMED_COLLISION"
} elseif ($alphaOut -eq $betaOut -and $alphaOut.Length -gt 0) {
    Write-Fail "CLAIM 5 CONFIRMED: Both named buffers return same content = '$alphaOut'"
    $script:Results["claim5"] = "CONFIRMED_SAME_SLOT"
} else {
    Write-Info "CLAIM 5 AMBIGUOUS - alpha='$alphaOut' beta='$betaOut'"
    $script:Results["claim5"] = "AMBIGUOUS"
}

# Additional test: set two buffers, then check if list-buffers shows named entries
$hasNamedAlpha = $bufList -match "mybuf_alpha"
$hasNamedBeta  = $bufList -match "mybuf_beta"
if ($hasNamedAlpha -and $hasNamedBeta) {
    Write-Pass "Named buffers appear in list-buffers output"
} else {
    Write-Fail "Named buffers NOT in list-buffers: alpha=$hasNamedAlpha, beta=$hasNamedBeta"
}

Cleanup $S5

# =====================================================================
# CLAIM 6: paste-buffer -p ignores -p (no bracketed paste)
# Should emit ESC[200~ text ESC[201~ when -p is used
# =====================================================================
Write-Host "`n=== CLAIM 6: paste-buffer -p bracketed paste ===" -ForegroundColor Yellow

$S6 = "pr207_paste"
Cleanup $S6

& $PSMUX new-session -d -s $S6
Start-Sleep -Seconds 2

# Set a buffer with unique marker
& $PSMUX set-buffer "PASTE_TEST_MARKER_XYZ" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Clear pane first
& $PSMUX send-keys -t $S6 "clear" Enter
Start-Sleep -Milliseconds 800

# Use paste-buffer -p (bracketed paste flag)
& $PSMUX paste-buffer -p -t $S6 2>&1 | Out-Null
Start-Sleep -Seconds 1

$captured6 = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
Write-Info "Pane after paste-buffer -p:"
Write-Info $captured6.Substring(0, [Math]::Min(300, $captured6.Length))

# Check if the text appeared (regardless of bracketed paste sequences)
if ($captured6 -match "PASTE_TEST_MARKER_XYZ") {
    Write-Pass "paste-buffer -p pasted content into pane (content found)"
    # Note: We can't easily verify bracketed paste ESC sequences from capture-pane
    # The claim is about bracket wrapping, but at minimum content should appear
    Write-Info "NOTE: Cannot verify ESC[200~/ESC[201~ sequences via capture-pane"
    Write-Info "      Further verification would require checking the raw PTY stream"
    $script:Results["claim6"] = "PARTIAL_PASS_CONTENT_PASTED"
} else {
    Write-Fail "paste-buffer -p did NOT paste content or content not visible"
    $script:Results["claim6"] = "AMBIGUOUS"
}

# Also test paste-buffer WITHOUT -p for comparison
& $PSMUX send-keys -t $S6 "clear" Enter
Start-Sleep -Milliseconds 800
& $PSMUX paste-buffer -t $S6 2>&1 | Out-Null
Start-Sleep -Seconds 1
$captured6_nop = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
Write-Info "Pane after paste-buffer (no -p):"
Write-Info $captured6_nop.Substring(0, [Math]::Min(300, $captured6_nop.Length))

if ($captured6_nop -match "PASTE_TEST_MARKER_XYZ") {
    Write-Pass "paste-buffer (no -p) also pasted content"
}

Cleanup $S6

# =====================================================================
# ADDITIONAL VERIFICATION: Confirm -F with new-session -P format token
# More thorough test of claim 2 - test what -P output actually looks like
# =====================================================================
Write-Host "`n=== BONUS: What does new-session -P actually output? ===" -ForegroundColor Yellow

$S7 = "pr207_bonus"
Cleanup $S7

# What tmux SHOULD return: formatted output when -P and -F are both given
$out_P_only    = & $PSMUX new-session -d -s $S7 -P 2>&1
Start-Sleep -Milliseconds 500
Cleanup $S7

$S7b = "pr207_bonus2"
$out_P_F_space = & $PSMUX new-session -d -s $S7b -P -F '#{session_name}:#{session_id}' 2>&1
Start-Sleep -Milliseconds 500

Write-Info "new-session -P (no -F): '$out_P_only'"
Write-Info "new-session -P -F '#{session_name}:#{session_id}': '$out_P_F_space'"

Cleanup $S7
Cleanup $S7b

# =====================================================================
# SUMMARY
# =====================================================================
Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host " SUMMARY OF FINDINGS" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

foreach ($key in $script:Results.Keys | Sort-Object) {
    $verdict = $script:Results[$key]
    $color = if ($verdict -match "^CONFIRMED") { "Red" } elseif ($verdict -match "^DISPROVED") { "Green" } else { "Yellow" }
    Write-Host "  $key : $verdict" -ForegroundColor $color
}

Write-Host "`n  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit 0  # Don't fail on "issues" - this is a discovery test
