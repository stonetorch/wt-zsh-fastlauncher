# psmux Issue #57 - cursor-style / cursor-blink does not work
#
# Verifies that:
#   1. set-option -g cursor-style stores the value (show-options -g -v cursor-style returns it)
#   2. set-option -g cursor-blink stores the value (show-options -g -v cursor-blink returns it)
#   3. All three cursor-style values are accepted: block, underline, bar
#   4. Both cursor-blink values are accepted: on, off
#   5. Runtime changes via set-option are reflected immediately in show-options
#   6. Config-file values (set -g) are stored at session start
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue57_cursor_style_blink.ps1

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass { param($msg) Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:TestsFailed++ }
function Write-Info { param($msg) Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-Test { param($msg) Write-Host "`n[TEST] $msg" -ForegroundColor White }

$PSMUX = "$env:USERPROFILE\.cargo\bin\psmux.exe"
if (-not (Test-Path $PSMUX)) {
    $PSMUX = (Get-Command psmux -ErrorAction SilentlyContinue).Source
}
if (-not $PSMUX -or -not (Test-Path $PSMUX)) { Write-Error "psmux binary not found"; exit 1 }
Write-Info "Using: $PSMUX"

$SESSION = "gap57"

function Wait-ForSession {
    param($name, $timeout = 12)
    $deadline = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $deadline) {
        & $PSMUX has-session -t $name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-Opt {
    param($opt)
    (& $PSMUX show-options -g -v $opt 2>&1 | Out-String).Trim()
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>$null
    Start-Sleep -Milliseconds 300
}

# --- Kill any leftover gap57 session ---
& $PSMUX kill-session -t $SESSION 2>$null
Start-Sleep -Milliseconds 500

Write-Host ""
Write-Host ("=" * 60)
Write-Host "ISSUE #57: cursor-style / cursor-blink option storage"
Write-Host ("=" * 60)

# ===========================================================
# Test 1: Start session and read default show-options values
# ===========================================================
Write-Test "1: Default cursor options are readable via show-options"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }

    $style = Get-Opt "cursor-style"
    $blink = Get-Opt "cursor-blink"
    Write-Info "Default cursor-style=[$style] cursor-blink=[$blink]"

    if ($style -ne "") {
        Write-Pass "1a: cursor-style is readable (value='$style')"
    } else {
        Write-Fail "1a: cursor-style returned empty string"
    }

    if ($blink -ne "") {
        Write-Pass "1b: cursor-blink is readable (value='$blink')"
    } else {
        Write-Fail "1b: cursor-blink returned empty string"
    }
} catch {
    Write-Fail "1: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 2: set-option -g cursor-style block stores correctly
# ===========================================================
Write-Test "2: set-option -g cursor-style block -> show-options returns 'block'"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }

    & $PSMUX set-option -g cursor-style block 2>$null
    Start-Sleep -Milliseconds 800
    $val = Get-Opt "cursor-style"
    if ($val -eq "block") {
        Write-Pass "2: cursor-style=block stored and returned correctly"
    } else {
        # Retry once - server may be busy after fresh session start
        & $PSMUX set-option -g cursor-style block 2>$null
        Start-Sleep -Milliseconds 800
        $val = Get-Opt "cursor-style"
        if ($val -eq "block") {
            Write-Pass "2: cursor-style=block stored and returned correctly (retry)"
        } else {
            Write-Fail "2: cursor-style=block -> show-options returned '$val'"
        }
    }
} catch {
    Write-Fail "2: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 3: set-option -g cursor-style underline stores correctly
# ===========================================================
Write-Test "3: set-option -g cursor-style underline -> show-options returns 'underline'"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }

    & $PSMUX set-option -g cursor-style underline 2>$null
    Start-Sleep -Milliseconds 400
    $val = Get-Opt "cursor-style"
    if ($val -eq "underline") {
        Write-Pass "3: cursor-style=underline stored and returned correctly"
    } else {
        Write-Fail "3: cursor-style=underline -> show-options returned '$val'"
    }
} catch {
    Write-Fail "3: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 4: set-option -g cursor-style bar stores correctly
# ===========================================================
Write-Test "4: set-option -g cursor-style bar -> show-options returns 'bar'"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }

    & $PSMUX set-option -g cursor-style bar 2>$null
    Start-Sleep -Milliseconds 400
    $val = Get-Opt "cursor-style"
    if ($val -eq "bar") {
        Write-Pass "4: cursor-style=bar stored and returned correctly"
    } else {
        Write-Fail "4: cursor-style=bar -> show-options returned '$val'"
    }
} catch {
    Write-Fail "4: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 5: set-option -g cursor-blink off stores correctly
# ===========================================================
Write-Test "5: set-option -g cursor-blink off -> show-options returns 'off'"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }

    & $PSMUX set-option -g cursor-blink off 2>$null
    Start-Sleep -Milliseconds 400
    $val = Get-Opt "cursor-blink"
    if ($val -eq "off") {
        Write-Pass "5: cursor-blink=off stored and returned correctly"
    } else {
        Write-Fail "5: cursor-blink=off -> show-options returned '$val'"
    }
} catch {
    Write-Fail "5: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 6: set-option -g cursor-blink on stores correctly
# ===========================================================
Write-Test "6: set-option -g cursor-blink on -> show-options returns 'on'"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }

    & $PSMUX set-option -g cursor-blink on 2>$null
    Start-Sleep -Milliseconds 400
    $val = Get-Opt "cursor-blink"
    if ($val -eq "on") {
        Write-Pass "6: cursor-blink=on stored and returned correctly"
    } else {
        Write-Fail "6: cursor-blink=on -> show-options returned '$val'"
    }
} catch {
    Write-Fail "6: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 7: Runtime changes cycle through all combinations
# ===========================================================
Write-Test "7: Runtime cycling through all cursor-style + cursor-blink combinations"
try {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }

    $combos = @(
        @{ style = "block";     blink = "on"  },
        @{ style = "block";     blink = "off" },
        @{ style = "underline"; blink = "on"  },
        @{ style = "underline"; blink = "off" },
        @{ style = "bar";       blink = "on"  },
        @{ style = "bar";       blink = "off" }
    )

    $allOk = $true
    foreach ($c in $combos) {
        & $PSMUX set-option -g cursor-style $c.style 2>$null
        Start-Sleep -Milliseconds 400
        & $PSMUX set-option -g cursor-blink  $c.blink 2>$null
        Start-Sleep -Milliseconds 600
        $gotStyle = Get-Opt "cursor-style"
        $gotBlink = Get-Opt "cursor-blink"
        if ($gotStyle -eq $c.style -and $gotBlink -eq $c.blink) {
            Write-Info "  OK: style=$($c.style) blink=$($c.blink)"
        } else {
            # Retry once for server propagation
            & $PSMUX set-option -g cursor-style $c.style 2>$null
            Start-Sleep -Milliseconds 400
            & $PSMUX set-option -g cursor-blink  $c.blink 2>$null
            Start-Sleep -Milliseconds 600
            $gotStyle = Get-Opt "cursor-style"
            $gotBlink = Get-Opt "cursor-blink"
            if ($gotStyle -eq $c.style -and $gotBlink -eq $c.blink) {
                Write-Info "  OK (retry): style=$($c.style) blink=$($c.blink)"
            } else {
                Write-Info "  BAD: expected style=$($c.style) blink=$($c.blink), got style=$gotStyle blink=$gotBlink"
                $allOk = $false
            }
        }
    }

    if ($allOk) {
        Write-Pass "7: All 6 cursor style+blink combinations stored correctly"
    } else {
        Write-Fail "7: One or more cursor combinations not stored correctly (see INFO above)"
    }
} catch {
    Write-Fail "7: Exception: $_"
} finally {
    Cleanup
}

# ===========================================================
# Test 8: Config-file values loaded at session start
# ===========================================================
Write-Test "8: Config file 'set -g cursor-style underline' + 'set -g cursor-blink off' applied at startup"
$confFile = "$env:TEMP\psmux_gap57_test.conf"
try {
    Set-Content -Path $confFile -Value "set -g cursor-style underline`nset -g cursor-blink off" -Encoding UTF8

    $env:PSMUX_CONFIG_FILE = $confFile
    Start-Process -FilePath $PSMUX -ArgumentList "new-session -s $SESSION -d" -WindowStyle Hidden
    if (-not (Wait-ForSession $SESSION)) { throw "session did not start" }
    $env:PSMUX_CONFIG_FILE = $null

    Start-Sleep -Milliseconds 500
    $style = Get-Opt "cursor-style"
    $blink = Get-Opt "cursor-blink"
    Write-Info "After config load: cursor-style=[$style] cursor-blink=[$blink]"

    if ($style -eq "underline") {
        Write-Pass "8a: Config 'set -g cursor-style underline' applied (got '$style')"
    } else {
        Write-Fail "8a: Config cursor-style -> expected 'underline', got '$style'"
    }

    if ($blink -eq "off") {
        Write-Pass "8b: Config 'set -g cursor-blink off' applied (got '$blink')"
    } else {
        Write-Fail "8b: Config cursor-blink -> expected 'off', got '$blink'"
    }
} catch {
    Write-Fail "8: Exception: $_"
} finally {
    $env:PSMUX_CONFIG_FILE = $null
    Remove-Item $confFile -Force -ErrorAction SilentlyContinue
    Cleanup
}

# ===========================================================
# Summary
# ===========================================================
Write-Host ""
Write-Host ("=" * 60)
Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed"
Write-Host ("=" * 60)
exit $script:TestsFailed
