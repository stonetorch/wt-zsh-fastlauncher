# Issue #324: psmux new -s work2 overwrites psmux new -s work
# Fix: creating a second session does not destroy the first.
# Proof:
#   1. Create gap324a
#   2. Create gap324b  (this was the step that killed gap324a before the fix)
#   3. has-session gap324a exits 0  (must survive)
#   4. has-session gap324b exits 0  (must also exist)
#   5. list-sessions shows both with DISTINCT names and DISTINCT session_ids
#   6. gap324a's port is still TCP-reachable (server process still alive)

$ErrorActionPreference = "Continue"
$PSMUX    = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

$script:Pass = 0
$script:Fail = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:Pass++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:Fail++ }

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 12000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -EA SilentlyContinue)
            if ($port -and $port.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port.Trim())
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Tcp-Alive {
    param([string]$Name)
    $pf = "$psmuxDir\$Name.port"
    if (-not (Test-Path $pf)) { return $false }
    $port = (Get-Content $pf -Raw -EA SilentlyContinue).Trim()
    if (-not ($port -match '^\d+$')) { return $false }
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.Close()
        return $true
    } catch { return $false }
}

function Cleanup {
    foreach ($s in @("gap324a","gap324b")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 500
    foreach ($s in @("gap324a","gap324b")) {
        Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue
    }
}

Write-Host "`n=== Issue #324: Second session must not overwrite first ===" -ForegroundColor Cyan

Cleanup
Start-Sleep -Milliseconds 300

# --- Step 1: create gap324a ---
Write-Host "`n[Step 1] Creating gap324a..." -ForegroundColor Yellow
& $PSMUX new-session -d -s gap324a 2>&1 | Out-Null
if (Wait-Session "gap324a") {
    Write-Pass "gap324a created and reachable"
} else {
    Write-Fail "gap324a failed to start — aborting"
    exit 1
}

$id_a_before = (& $PSMUX display-message -t gap324a -p '#{session_id}' 2>&1 | Out-String).Trim()
Write-Host "  gap324a session_id before: '$id_a_before'"

# --- Step 2: create gap324b (this was the overwriting step) ---
Write-Host "`n[Step 2] Creating gap324b (the step that triggered the bug)..." -ForegroundColor Yellow
& $PSMUX new-session -d -s gap324b 2>&1 | Out-Null
if (Wait-Session "gap324b") {
    Write-Pass "gap324b created and reachable"
} else {
    Write-Fail "gap324b failed to start"
}

# Short pause to let any overwrite side-effect manifest
Start-Sleep -Milliseconds 500

# --- Step 3: gap324a must still exist (has-session exits 0) ---
Write-Host "`n[Test 1] has-session gap324a exits 0 after gap324b was created" -ForegroundColor Yellow
& $PSMUX has-session -t gap324a 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "has-session gap324a exited 0 (first session survived)"
} else {
    Write-Fail "has-session gap324a exited $LASTEXITCODE (first session was DESTROYED — bug present)"
}

# --- Step 4: gap324b must also exist ---
Write-Host "`n[Test 2] has-session gap324b exits 0" -ForegroundColor Yellow
& $PSMUX has-session -t gap324b 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "has-session gap324b exited 0 (second session exists)"
} else {
    Write-Fail "has-session gap324b exited $LASTEXITCODE"
}

# --- Step 5: list-sessions shows both with distinct names and IDs ---
Write-Host "`n[Test 3] list-sessions shows both gap324a and gap324b" -ForegroundColor Yellow
$lsOut = (& $PSMUX list-sessions 2>&1 | Out-String).Trim()
Write-Host "  list-sessions output:"
$lsOut -split "`n" | Where-Object { $_ -match "gap324" } | ForEach-Object { Write-Host "    $_" }

$hasA = $lsOut -match "gap324a"
$hasB = $lsOut -match "gap324b"

if ($hasA) { Write-Pass "list-sessions contains gap324a" }
else        { Write-Fail "list-sessions MISSING gap324a" }

if ($hasB) { Write-Pass "list-sessions contains gap324b" }
else        { Write-Fail "list-sessions MISSING gap324b" }

# --- Step 6: distinct session_ids ---
Write-Host "`n[Test 4] gap324a and gap324b have distinct session_ids" -ForegroundColor Yellow
$id_a = (& $PSMUX display-message -t gap324a -p '#{session_id}' 2>&1 | Out-String).Trim()
$id_b = (& $PSMUX display-message -t gap324b -p '#{session_id}' 2>&1 | Out-String).Trim()
Write-Host "  gap324a id: '$id_a'   gap324b id: '$id_b'"

if ($id_a -match '^\$\d+$') { Write-Pass "gap324a has valid session_id: $id_a" }
else                         { Write-Fail "gap324a session_id invalid: '$id_a'" }

if ($id_b -match '^\$\d+$') { Write-Pass "gap324b has valid session_id: $id_b" }
else                         { Write-Fail "gap324b session_id invalid: '$id_b'" }

if ($id_a -ne "" -and $id_b -ne "" -and $id_a -ne $id_b) {
    Write-Pass "gap324a and gap324b have DISTINCT session_ids ($id_a vs $id_b)"
} else {
    Write-Fail "session_ids are identical or empty: '$id_a' == '$id_b' (overwrite bug)"
}

# --- Step 7: gap324a TCP port still alive ---
Write-Host "`n[Test 5] gap324a server process still TCP-reachable after gap324b creation" -ForegroundColor Yellow
if (Tcp-Alive "gap324a") {
    Write-Pass "gap324a port is TCP-reachable (server process still running)"
} else {
    Write-Fail "gap324a port is NOT reachable (server was killed by gap324b creation)"
}

# --- Step 8: gap324a session_id unchanged ---
Write-Host "`n[Test 6] gap324a session_id unchanged after gap324b creation" -ForegroundColor Yellow
if ($id_a_before -ne "" -and $id_a -eq $id_a_before) {
    Write-Pass "gap324a session_id stable: $id_a"
} else {
    Write-Fail "gap324a session_id changed: was '$id_a_before', now '$id_a'"
}

Cleanup

Write-Host "`n=== Issue #324 Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
exit $script:Fail
