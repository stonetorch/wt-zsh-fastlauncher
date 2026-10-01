#!/usr/bin/env pwsh
# test_robust_argfuzz.ps1
# EXTREME robustness campaign: CLI ARGUMENT FUZZING / MALFORMED INPUT.
#
# Namespace: rbArg (EVERY psmux call passes -L rbArg as the FIRST args).
# Goal: throw malformed / hostile / nonsensical CLI input at the server and
#       PROVE that after EACH category the server is STILL ALIVE and STILL
#       responds correctly to a valid command. Bad input must produce a
#       graceful (nonzero) error WITHOUT taking down the server.
#
# Cleanup is ONLY ever done via `& psmux -L rbArg kill-server`.
# We NEVER kill by image name and NEVER touch other namespaces.

$ErrorActionPreference = "Continue"

$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:TestsFailed++ }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run a psmux command in the rbArg namespace. Returns the joined string output;
# sets $script:LastExit to the exit code.
function Invoke-Psmux {
    # NOTE: use the automatic $args, NOT a [Parameter(ValueFromRemainingArguments)]
    # param. The latter turns this into an advanced function whose common
    # parameters (-ProgressAction, -PipelineVariable, ...) SWALLOW a leading -p
    # (e.g. `display-message -p`), failing with "parameter name 'p' is ambiguous"
    # BEFORE psmux is ever invoked. That left $script:LastExit stale at 0 and made
    # display-message -p cases spuriously look like "exit 0". The plain $args form
    # passes every flag through verbatim.
    $out = & psmux -L rbArg @args 2>&1
    $script:LastExit = $LASTEXITCODE
    if ($null -eq $out) { return "" }
    return ($out | Out-String)
}

# Core robustness proof. After a batch of bad input we MUST be able to:
#   1. list-sessions with exit code 0 (server alive + responsive)
#   2. ask the base session for its name and get rbArg_base back
# Returns $true only if BOTH hold.
function Assert-ServerAliveAndValid {
    param([string]$Context)

    $ls = & psmux -L rbArg list-sessions 2>&1
    $lsExit = $LASTEXITCODE
    $lsStr = if ($null -eq $ls) { "" } else { ($ls | Out-String) }

    if ($lsExit -ne 0) {
        Write-Fail "$Context : server DID NOT survive (list-sessions exit=$lsExit). Output: $($lsStr.Trim())"
        return $false
    }

    $name = & psmux -L rbArg display-message -p '#{session_name}' -t rbArg_base 2>&1
    $dmExit = $LASTEXITCODE
    $nameStr = if ($null -eq $name) { "" } else { ($name | Out-String).Trim() }

    if ($dmExit -ne 0) {
        Write-Fail "$Context : valid follow-up command failed (display-message exit=$dmExit). Output: $nameStr"
        return $false
    }

    if ($nameStr -notmatch 'rbArg_base') {
        Write-Fail "$Context : base session name mismatch. Expected 'rbArg_base', got '$nameStr'"
        return $false
    }

    Write-Pass "$Context : server alive and valid command still returns 'rbArg_base'"
    return $true
}

# ---------------------------------------------------------------------------
# Banner + clean slate
# ---------------------------------------------------------------------------

Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host " psmux ROBUSTNESS: CLI Argument Fuzzing (rbArg)" -ForegroundColor Cyan
Write-Host "================================================`n" -ForegroundColor Cyan

# Best-effort clean of our OWN namespace only (never global, never by image).
& psmux -L rbArg kill-server 2>&1 | Out-Null
Start-Sleep -Seconds 1

# ---------------------------------------------------------------------------
# Setup: create the base session and prove it is alive.
# ---------------------------------------------------------------------------

Write-Host "--- Setup: create base session rbArg_base ---" -ForegroundColor Yellow

& psmux -L rbArg new-session -d -s rbArg_base 2>&1 | Out-Null
$setupExit = $LASTEXITCODE
Start-Sleep -Seconds 3

if ($setupExit -ne 0) {
    Write-Fail "Setup: new-session for rbArg_base failed (exit=$setupExit). Cannot continue."
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "Passed: $script:TestsPassed" -ForegroundColor Green
    Write-Host "Failed: $script:TestsFailed" -ForegroundColor Red
    & psmux -L rbArg kill-server 2>&1 | Out-Null
    exit $script:TestsFailed
}

if (-not (Assert-ServerAliveAndValid "Setup")) {
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "Passed: $script:TestsPassed" -ForegroundColor Green
    Write-Host "Failed: $script:TestsFailed" -ForegroundColor Red
    & psmux -L rbArg kill-server 2>&1 | Out-Null
    exit $script:TestsFailed
}

# ===========================================================================
# CATEGORY 1: Unknown command
# ===========================================================================
Write-Host "`n--- Category 1: Unknown command ---" -ForegroundColor Yellow

$null = Invoke-Psmux this-is-not-a-command
if ($script:LastExit -ne 0) {
    Write-Pass "Unknown command 'this-is-not-a-command' rejected with nonzero exit ($script:LastExit)"
} else {
    Write-Fail "Unknown command unexpectedly returned exit 0"
}

$null = Invoke-Psmux totally-bogus-subcommand --with --random --flags 123
if ($script:LastExit -ne 0) {
    Write-Pass "Second unknown command also rejected with nonzero exit ($script:LastExit)"
} else {
    Write-Fail "Second unknown command unexpectedly returned exit 0"
}

[void](Assert-ServerAliveAndValid "After Category 1 (unknown command)")

# ===========================================================================
# CATEGORY 2: Missing required args
# ===========================================================================
Write-Host "`n--- Category 2: Missing required args ---" -ForegroundColor Yellow

# split-window with no target / no session ctx (CLI has no current client).
$null = Invoke-Psmux split-window
Write-Host "    split-window (no target) exit=$script:LastExit" -ForegroundColor DarkGray

# rename-window with no name argument.
$null = Invoke-Psmux rename-window
Write-Host "    rename-window (no name) exit=$script:LastExit" -ForegroundColor DarkGray

# set-option with no value.
$null = Invoke-Psmux set-option history-limit
Write-Host "    set-option history-limit (no value) exit=$script:LastExit" -ForegroundColor DarkGray

# bind-key with no command.
$null = Invoke-Psmux bind-key X
Write-Host "    bind-key X (no command) exit=$script:LastExit" -ForegroundColor DarkGray

# new-window with no session context (no -t, no attached client).
$null = Invoke-Psmux new-window
Write-Host "    new-window (no session ctx) exit=$script:LastExit" -ForegroundColor DarkGray

# The robustness contract for THIS category is purely server survival:
# whether psmux errors or no-ops on missing args, it must NOT crash.
[void](Assert-ServerAliveAndValid "After Category 2 (missing required args)")

# ===========================================================================
# CATEGORY 3: Bad / nonexistent targets
# ===========================================================================
Write-Host "`n--- Category 3: Bad / nonexistent targets ---" -ForegroundColor Yellow

$null = Invoke-Psmux display-message -p '#{session_name}' -t does_not_exist
if ($script:LastExit -ne 0) {
    Write-Pass "Target -t does_not_exist rejected with nonzero exit ($script:LastExit)"
} else {
    Write-Fail "Nonexistent session target unexpectedly returned exit 0"
}

$null = Invoke-Psmux select-window -t 'rbArg_base:999'
if ($script:LastExit -ne 0) {
    Write-Pass "Bad window index -t rbArg_base:999 rejected (exit $script:LastExit)"
} else {
    Write-Fail "Bad window index unexpectedly returned exit 0"
}

$null = Invoke-Psmux select-pane -t 'rbArg_base.999'
if ($script:LastExit -ne 0) {
    Write-Pass "Bad pane index -t rbArg_base.999 rejected (exit $script:LastExit)"
} else {
    Write-Fail "Bad pane index unexpectedly returned exit 0"
}

$null = Invoke-Psmux display-message -p 'x' -t ':::'
if ($script:LastExit -ne 0) {
    Write-Pass "Garbage target -t ::: rejected (exit $script:LastExit)"
} else {
    Write-Fail "Garbage target ::: unexpectedly returned exit 0"
}

$null = Invoke-Psmux select-pane -t '%999'
if ($script:LastExit -ne 0) {
    Write-Pass "Bad pane id -t %999 rejected (exit $script:LastExit)"
} else {
    Write-Fail "Bad pane id %999 unexpectedly returned exit 0"
}

[void](Assert-ServerAliveAndValid "After Category 3 (bad targets)")

# ===========================================================================
# CATEGORY 4: Wrong-type args
# ===========================================================================
Write-Host "`n--- Category 4: Wrong-type args ---" -ForegroundColor Yellow

$null = Invoke-Psmux select-window -t 'rbArg_base:notanumber'
if ($script:LastExit -ne 0) {
    Write-Pass "select-window -t rbArg_base:notanumber rejected (exit $script:LastExit)"
} else {
    Write-Fail "Non-numeric window index unexpectedly returned exit 0"
}

$null = Invoke-Psmux resize-pane -t rbArg_base -x abc
if ($script:LastExit -ne 0) {
    Write-Pass "resize-pane -x abc (non-numeric) rejected (exit $script:LastExit)"
} else {
    Write-Fail "resize-pane -x abc unexpectedly returned exit 0"
}

$null = Invoke-Psmux set-option history-limit notanumber
if ($script:LastExit -ne 0) {
    Write-Pass "set-option history-limit notanumber rejected (exit $script:LastExit)"
} else {
    Write-Fail "set-option history-limit notanumber unexpectedly returned exit 0"
}

[void](Assert-ServerAliveAndValid "After Category 4 (wrong-type args)")

# ===========================================================================
# CATEGORY 5: Huge args
# ===========================================================================
Write-Host "`n--- Category 5: Huge args ---" -ForegroundColor Yellow

# 5000-char session name.
$hugeName = 'h' * 5000
$null = Invoke-Psmux new-session -d -s $hugeName
Write-Host "    new-session with 5000-char name exit=$script:LastExit" -ForegroundColor DarkGray
Write-Pass "5000-char session name handled without crash (exit $script:LastExit)"

# If by chance that huge session was created, clean it up (namespaced only).
$null = Invoke-Psmux kill-session -t $hugeName

[void](Assert-ServerAliveAndValid "After Category 5a (5000-char session name)")

# 100000-char send-keys payload to the base session.
$hugePayload = 'A' * 100000
$null = Invoke-Psmux send-keys -t rbArg_base $hugePayload
Write-Host "    send-keys 100000-char payload exit=$script:LastExit" -ForegroundColor DarkGray
Write-Pass "100000-char send-keys payload handled without crash (exit $script:LastExit)"

# Give the server a moment to process the large input.
Start-Sleep -Seconds 1

[void](Assert-ServerAliveAndValid "After Category 5b (100000-char send-keys)")

# ===========================================================================
# CATEGORY 6: Injection-flavored strings (must be literal data)
# ===========================================================================
Write-Host "`n--- Category 6: Injection-flavored strings ---" -ForegroundColor Yellow

# Single-quoted PowerShell strings => no PS expansion; psmux must treat these
# as opaque literal data and never crash / never let them reach a shell.
$inj1 = '; & | $() `backtick` %TEMP% <>"'' rm -rf'
$inj2 = 'name`nwith`nnewlines and ; semicolons & ampersands'

$null = Invoke-Psmux rename-window -t rbArg_base $inj1
Write-Host "    rename-window injection#1 exit=$script:LastExit" -ForegroundColor DarkGray

$null = Invoke-Psmux rename-window -t rbArg_base $inj2
Write-Host "    rename-window injection#2 exit=$script:LastExit" -ForegroundColor DarkGray

$null = Invoke-Psmux new-session -d -s $inj1
Write-Host "    new-session injection-name exit=$script:LastExit" -ForegroundColor DarkGray
# Attempt namespaced cleanup of any session that may have been created.
$null = Invoke-Psmux kill-session -t $inj1

$null = Invoke-Psmux send-keys -t rbArg_base $inj1
Write-Host "    send-keys injection payload exit=$script:LastExit" -ForegroundColor DarkGray

# The proof: injection data did not crash the server and the base session is
# still addressable. (Base window may have been renamed; that is fine - we
# only require the SESSION to survive and respond.)
[void](Assert-ServerAliveAndValid "After Category 6 (injection strings)")

# ===========================================================================
# CATEGORY 7: Flag edge cases
# ===========================================================================
Write-Host "`n--- Category 7: Flag edge cases ---" -ForegroundColor Yellow

# Duplicate -d -d flags.
$null = Invoke-Psmux new-session -d -d -s rbArg_dupflag
Write-Host "    new-session -d -d exit=$script:LastExit" -ForegroundColor DarkGray
$null = Invoke-Psmux kill-session -t rbArg_dupflag

# Unknown long flag.
$null = Invoke-Psmux list-sessions --frobnicate
if ($script:LastExit -ne 0) {
    Write-Pass "Unknown flag --frobnicate rejected (exit $script:LastExit)"
} else {
    Write-Fail "Unknown flag --frobnicate unexpectedly returned exit 0"
}

# -t with no value at end of args.
$null = Invoke-Psmux display-message -p 'x' -t
Write-Host "    display-message -t (no value) exit=$script:LastExit" -ForegroundColor DarkGray

# Equals / glued forms of -t.
$null = Invoke-Psmux display-message -p '#{session_name}' -trbArg_base
Write-Host "    display-message -trbArg_base (glued) exit=$script:LastExit" -ForegroundColor DarkGray

$null = Invoke-Psmux display-message -p '#{session_name}' -t=rbArg_base
Write-Host "    display-message -t=rbArg_base (equals) exit=$script:LastExit" -ForegroundColor DarkGray

# Whatever the parser does with these, the server must survive.
[void](Assert-ServerAliveAndValid "After Category 7 (flag edge cases)")

# ===========================================================================
# CATEGORY 8: has-session negative path
# ===========================================================================
Write-Host "`n--- Category 8: has-session negative path ---" -ForegroundColor Yellow

$null = Invoke-Psmux has-session -t rbArg_definitely_absent_xyz
if ($script:LastExit -ne 0) {
    Write-Pass "has-session on absent session returns nonzero exit ($script:LastExit)"
} else {
    Write-Fail "has-session on absent session unexpectedly returned exit 0"
}

# And the positive path still works for the real session.
$null = Invoke-Psmux has-session -t rbArg_base
if ($script:LastExit -eq 0) {
    Write-Pass "has-session on rbArg_base returns exit 0 (positive path intact)"
} else {
    Write-Fail "has-session on rbArg_base unexpectedly returned nonzero ($script:LastExit)"
}

[void](Assert-ServerAliveAndValid "After Category 8 (has-session)")

# ===========================================================================
# CATEGORY 9: Duplicate session name
# ===========================================================================
Write-Host "`n--- Category 9: Duplicate session name ---" -ForegroundColor Yellow

$null = Invoke-Psmux new-session -d -s rbArg_base
if ($script:LastExit -ne 0) {
    Write-Pass "Duplicate new-session -s rbArg_base rejected gracefully (exit $script:LastExit)"
} else {
    Write-Fail "Duplicate session creation unexpectedly returned exit 0"
}

# The ORIGINAL base session must still be intact and the server alive.
[void](Assert-ServerAliveAndValid "After Category 9 (duplicate session)")

# Extra proof: exactly one rbArg_base session exists (original survived).
$sessOut = Invoke-Psmux list-sessions -F '#{session_name}'
$baseCount = (($sessOut -split "`r?`n") | Where-Object { $_.Trim() -eq 'rbArg_base' }).Count
if ($baseCount -eq 1) {
    Write-Pass "Exactly one rbArg_base session present after duplicate attempt (original intact)"
} else {
    Write-Fail "Expected exactly 1 rbArg_base session, found $baseCount. Output: $($sessOut.Trim())"
}

# ===========================================================================
# Cleanup (namespaced ONLY) + Results
# ===========================================================================
Write-Host "`n--- Cleanup (rbArg namespace only) ---" -ForegroundColor Yellow
& psmux -L rbArg kill-server 2>&1 | Out-Null
Start-Sleep -Seconds 1
Write-Host "  kill-server -L rbArg issued" -ForegroundColor DarkGray

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "Failed: $script:TestsFailed" -ForegroundColor Red
Write-Host "Total : $($script:TestsPassed + $script:TestsFailed)" -ForegroundColor Cyan

exit $script:TestsFailed
