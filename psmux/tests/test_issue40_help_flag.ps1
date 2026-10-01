# Issue #40 E2E Test: "failed to print help"
#
# Reporter observed that `tmux --help` (i.e. psmux --help) switched to default
# session instead of printing help. Verifies:
#   1. `psmux --help` exits 0 (or documented code), prints usage text, no panic
#   2. `psmux -h` behaves the same
#   3. Output is non-trivial (> 50 chars) and contains expected help tokens
#   4. No session was created as a side effect

param([switch]$Verbose)

$ErrorActionPreference = "Continue"
$PSMUX    = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:passed = 0
$script:failed = 0

# ── helpers ─────────────────────────────────────────────────────────────────

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:passed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:failed++ }

# Capture stdout + stderr, return object with .Output (string) and .ExitCode (int)
function Invoke-Psmux {
    param([string[]]$CmdArgs)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($PSMUX)
    foreach ($a in $CmdArgs) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(8000) | Out-Null
    return @{
        Output   = ($stdout + $stderr).Trim()
        ExitCode = $proc.ExitCode
    }
}

# ── setup ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Issue #40: psmux --help must print usage, not attach to session ===" -ForegroundColor Cyan
Write-Host ""

# Snapshot existing sessions so we can detect side-effect creation
$sessionsBefore = @(Get-ChildItem "$psmuxDir\*.port" -EA SilentlyContinue | Select-Object -ExpandProperty BaseName)
Write-Host "    Sessions before test: $($sessionsBefore -join ', ')" -ForegroundColor DarkGray

# ── Test 1: psmux --help ─────────────────────────────────────────────────────

Write-Host "--- Test 1: psmux --help ---" -ForegroundColor Magenta

$result1 = Invoke-Psmux @("--help")
if ($Verbose) { Write-Host "    Output:`n$($result1.Output)" -ForegroundColor Gray }

# Exit code should be 0 (help is not an error)
if ($result1.ExitCode -eq 0) {
    Write-Pass "1a: psmux --help exits 0"
} else {
    Write-Fail "1a: psmux --help exits $($result1.ExitCode) (expected 0)"
}

# Output must be non-trivial (full help is ~16k chars; accept anything > 200)
if ($result1.Output.Length -gt 200) {
    Write-Pass "1b: --help output is non-trivial ($($result1.Output.Length) chars)"
} else {
    Write-Fail "1b: --help output too short ($($result1.Output.Length) chars): '$($result1.Output)'"
}

# Output must not contain panic/crash indicators
if ($result1.Output -notmatch '(?i)panic|thread.*main.*panicked|stack overflow|unwrap.*failed') {
    Write-Pass "1c: --help output contains no panic/crash text"
} else {
    Write-Fail "1c: --help output contains panic/crash text: '$($result1.Output)'"
}

# Output must contain at least one recognisable help token
$helpTokens = @('usage','Usage','USAGE','new-session','new-window','split-window','attach','kill-session','psmux','tmux')
$tokenFound = $helpTokens | Where-Object { $result1.Output -match [regex]::Escape($_) }
if ($tokenFound) {
    Write-Pass "1d: --help output contains help token(s): $($tokenFound -join ', ')"
} else {
    Write-Fail "1d: --help output contains none of the expected tokens ($($helpTokens -join ', ')). Output: '$($result1.Output)'"
}

# ── Test 2: psmux -h ──────────────────────────────────────────────────────────

Write-Host ""
Write-Host "--- Test 2: psmux -h ---" -ForegroundColor Magenta

$result2 = Invoke-Psmux @("-h")
if ($Verbose) { Write-Host "    Output:`n$($result2.Output)" -ForegroundColor Gray }

if ($result2.ExitCode -eq 0) {
    Write-Pass "2a: psmux -h exits 0"
} else {
    Write-Fail "2a: psmux -h exits $($result2.ExitCode) (expected 0)"
}

if ($result2.Output.Length -gt 200) {
    Write-Pass "2b: -h output is non-trivial ($($result2.Output.Length) chars)"
} else {
    Write-Fail "2b: -h output too short ($($result2.Output.Length) chars): '$($result2.Output)'"
}

if ($result2.Output -notmatch '(?i)panic|thread.*main.*panicked|stack overflow|unwrap.*failed') {
    Write-Pass "2c: -h output contains no panic/crash text"
} else {
    Write-Fail "2c: -h output contains panic/crash text"
}

$tokenFound2 = $helpTokens | Where-Object { $result2.Output -match [regex]::Escape($_) }
if ($tokenFound2) {
    Write-Pass "2d: -h output contains help token(s): $($tokenFound2 -join ', ')"
} else {
    Write-Fail "2d: -h output contains none of the expected tokens. Output: '$($result2.Output)'"
}

# ── Test 3: no side-effect session was created ────────────────────────────────

Write-Host ""
Write-Host "--- Test 3: --help must not attach to or create a session ---" -ForegroundColor Magenta

Start-Sleep -Milliseconds 500
$sessionsAfter = @(Get-ChildItem "$psmuxDir\*.port" -EA SilentlyContinue | Select-Object -ExpandProperty BaseName)
$newSessions = $sessionsAfter | Where-Object { $_ -notin $sessionsBefore }
# Exclude purely numeric sessions -- the warm-pool server auto-increments these
# independent of any --help invocation; they are not a side effect of the flag.
$unexpectedSessions = $newSessions | Where-Object { $_ -notmatch '^\d+$' -and $_ -ne '__warm__' }

if ($Verbose) { Write-Host "    Sessions after test: $($sessionsAfter -join ', ')" -ForegroundColor Gray }
if ($newSessions.Count -gt 0) {
    Write-Host "    New sessions (including warm-pool): $($newSessions -join ', ')" -ForegroundColor DarkGray
}

if ($unexpectedSessions.Count -eq 0) {
    Write-Pass "3: --help did not create any named sessions (no side effect)"
} else {
    Write-Fail "3: --help created unexpected named session(s): $($unexpectedSessions -join ', ')"
}

# ── Test 4: help subcommand form (psmux help) ─────────────────────────────────

Write-Host ""
Write-Host "--- Test 4: psmux help (subcommand form) ---" -ForegroundColor Magenta

$result4 = Invoke-Psmux @("help")
if ($Verbose) { Write-Host "    Output:`n$($result4.Output)" -ForegroundColor Gray }

# Accept exit 0 or 1 for subcommand form (tmux exits 1 for some help variants)
if ($result4.ExitCode -in @(0,1)) {
    Write-Pass "4a: psmux help exits $($result4.ExitCode) (0 or 1 acceptable)"
} else {
    Write-Fail "4a: psmux help exits $($result4.ExitCode) (expected 0 or 1)"
}

if ($result4.Output.Length -gt 200) {
    Write-Pass "4b: psmux help produces output ($($result4.Output.Length) chars)"
} else {
    Write-Fail "4b: psmux help output too short ($($result4.Output.Length) chars)"
}

if ($result4.Output -notmatch '(?i)panic|thread.*main.*panicked|stack overflow') {
    Write-Pass "4c: psmux help contains no panic text"
} else {
    Write-Fail "4c: psmux help contains panic text: '$($result4.Output)'"
}

# ── summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:passed)" -ForegroundColor Green
Write-Host "  Failed: $($script:failed)" -ForegroundColor $(if ($script:failed -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($script:failed -gt 0) {
    Write-Host "ISSUE #40 NOT VERIFIED: $($script:failed) test(s) failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ISSUE #40 VERIFIED: --help / -h print usage text, exit 0, create no session" -ForegroundColor Green
    exit 0
}
