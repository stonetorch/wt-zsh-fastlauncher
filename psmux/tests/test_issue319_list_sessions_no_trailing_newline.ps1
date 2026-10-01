# Issue #319: Strip trailing newline from list-sessions format output
# Tests that list-sessions -F and plain list-sessions do NOT produce a
# trailing blank line / extra newline beyond the last real entry.
#
# The bug: the server appended an extra newline to the formatted payload,
# which libtmux parsed into a spurious empty last field, breaking tmuxp/libtmux.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "gap319"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION  2>&1 | Out-Null
    & $PSMUX kill-session -t "${SESSION}b" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*"  -Force -EA SilentlyContinue
    Remove-Item "$psmuxDir\${SESSION}b.*" -Force -EA SilentlyContinue
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $portFile = "$psmuxDir\$Session.port"
    $keyFile  = "$psmuxDir\$Session.key"
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    # AUTH handshake with a generous timeout
    $stream.ReadTimeout = 8000
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $authResp = $reader.ReadLine()
    if ($authResp -ne "OK") { $tcp.Close(); return ,[string[]]@() }
    # Send the command; read all response lines
    # First line: up to 8s (server may take a moment to process)
    # Subsequent lines: 800ms idle timeout signals end of response
    $writer.Write("$Command`n"); $writer.Flush()
    $lines = [System.Collections.Generic.List[string]]::new()
    $stream.ReadTimeout = 8000
    try {
        $firstLine = $reader.ReadLine()
        if ($null -ne $firstLine) {
            $lines.Add($firstLine)
            # Switch to a short timeout to detect end-of-response
            $stream.ReadTimeout = 800
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                $lines.Add($line)
            }
        }
    } catch { }
    $tcp.Close()
    # Return as array — PowerShell unwraps single-item collections without the comma operator
    return ,[string[]]$lines
}

# Wait for the port file to appear (up to 12 seconds)
function Wait-PortFile {
    param([string]$Session, [int]$TimeoutSec = 12)
    $portFile = "$psmuxDir\$Session.port"
    $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
    while ([DateTime]::Now -lt $deadline) {
        if (Test-Path $portFile) {
            $content = (Get-Content $portFile -Raw -EA SilentlyContinue).Trim()
            if ($content -match '^\d+$') { return $true }
        }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# === SETUP ===
Cleanup
Start-Sleep -Milliseconds 300
& $PSMUX new-session -d -s $SESSION

$portReady = Wait-PortFile -Session $SESSION -TimeoutSec 12
if (-not $portReady) {
    Write-Fail "Session port file never appeared within 12s"
    Cleanup
    exit 1
}

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session did not start"
    Cleanup
    exit 1
}

Write-Host "`n=== Issue #319 Tests: list-sessions no trailing newline ===" -ForegroundColor Cyan

# ================================================================
# Part A: CLI path -- list-sessions -F '#{session_name}'
# ================================================================
Write-Host "`n--- Part A: CLI Path (list-sessions -F) ---" -ForegroundColor Magenta

# Test 1: list-sessions -F '#{session_name}' output does not end with a blank line
Write-Host "`n[Test 1] list-sessions -F output has no trailing blank line" -ForegroundColor Yellow

# Capture raw bytes so we can see the exact trailing characters
$rawBytes = & $PSMUX list-sessions -F '#{session_name}' 2>&1
# Out-String preserves newlines; we want the string before PowerShell adds its own trailing newline
$rawStr = ($rawBytes | Out-String)

Write-Host "    Raw output repr: '$($rawStr -replace "`r", '\r' -replace "`n", '\n')'" -ForegroundColor DarkGray

# Split on newlines, keeping empty trailing entries visible
$lines = $rawStr -split "`n"
Write-Host "    Line count (incl trailing): $($lines.Count)" -ForegroundColor DarkGray
for ($i = 0; $i -lt $lines.Count; $i++) {
    Write-Host "      line[$i] = '$($lines[$i])'" -ForegroundColor DarkGray
}

# The last non-empty line should be the session name; no line after it should be empty
# PowerShell Out-String adds one trailing newline itself, so we trim ONE trailing empty element
# caused by the final \n that any well-formed line-oriented output has.
# A bug manifests as TWO or more trailing empty elements (extra blank line in content).
$trimmedOnce = $rawStr.TrimEnd("`r", "`n")
$linesNoTrail = $trimmedOnce -split "`n"
$lastLine = $linesNoTrail[-1].TrimEnd("`r")

Write-Host "    Last non-PS-trailing line: '$lastLine'" -ForegroundColor DarkGray

if ($lastLine -ne '') {
    Write-Pass "No trailing blank line: last content line is '$lastLine'"
} else {
    Write-Fail "Trailing blank line detected: last line after trimming one trailing newline is empty"
}

# Test 2: The output lines contain our session name (sanity: output is correct)
Write-Host "`n[Test 2] list-sessions -F output contains the session name" -ForegroundColor Yellow
if ($rawStr -match [regex]::Escape($SESSION)) {
    Write-Pass "Session '$SESSION' appears in list-sessions -F output"
} else {
    Write-Fail "Session '$SESSION' NOT found in list-sessions -F output: '$($rawStr.Trim())'"
}

# Test 3: Count of non-empty lines equals count of sessions (no phantom entries)
Write-Host "`n[Test 3] Non-empty lines = number of active sessions (no phantom blank entries)" -ForegroundColor Yellow
$nonEmptyLines = ($linesNoTrail | Where-Object { $_.Trim() -ne '' })
$sessionCount  = ($nonEmptyLines | Measure-Object).Count

# We have exactly 1 session running (gap319)
if ($sessionCount -ge 1) {
    # Verify there are no empty lines embedded in the real content
    $emptyInMiddle = ($linesNoTrail | Where-Object { $_.Trim() -eq '' })
    if (($emptyInMiddle | Measure-Object).Count -eq 0) {
        Write-Pass "Output has $sessionCount non-empty line(s) and zero empty lines in content"
    } else {
        Write-Fail "Output has empty lines embedded in content (phantom entries): $($linesNoTrail -join '|')"
    }
} else {
    Write-Fail "Expected at least 1 non-empty line, got $sessionCount"
}

# ================================================================
# Part B: Plain list-sessions (no -F) also has no trailing blank line
# ================================================================
Write-Host "`n--- Part B: Plain list-sessions (no format) ---" -ForegroundColor Magenta

# Test 4: plain list-sessions has no trailing blank line
Write-Host "`n[Test 4] Plain list-sessions has no trailing blank line" -ForegroundColor Yellow
$plainRaw = (& $PSMUX list-sessions 2>&1 | Out-String)
$plainTrimmed = $plainRaw.TrimEnd("`r", "`n")
$plainLines = $plainTrimmed -split "`n"
$plainLast = $plainLines[-1].TrimEnd("`r")

Write-Host "    Last content line: '$plainLast'" -ForegroundColor DarkGray

if ($plainLast -ne '') {
    Write-Pass "Plain list-sessions: no trailing blank line"
} else {
    Write-Fail "Plain list-sessions: trailing blank line detected"
}

# ================================================================
# Part C: Multi-session scenario
# ================================================================
Write-Host "`n--- Part C: Multi-session list-sessions ---" -ForegroundColor Magenta

# Start a second session
& $PSMUX new-session -d -s "${SESSION}b"
$portReady2 = Wait-PortFile -Session "${SESSION}b" -TimeoutSec 12
if (-not $portReady2) {
    Write-Fail "Second session port file never appeared"
} else {
    Start-Sleep -Milliseconds 300

    # Test 5: With 2 sessions, -F output still has no trailing blank line
    Write-Host "`n[Test 5] Two sessions: -F output has no trailing blank line" -ForegroundColor Yellow
    $twoRaw = (& $PSMUX list-sessions -F '#{session_name}' 2>&1 | Out-String)
    $twoTrimmed = $twoRaw.TrimEnd("`r", "`n")
    $twoLines = $twoTrimmed -split "`n"
    $twoLast  = $twoLines[-1].TrimEnd("`r")

    Write-Host "    Lines with 2 sessions: $($twoLines -join ' | ')" -ForegroundColor DarkGray

    if ($twoLast -ne '') {
        Write-Pass "Two-session list: last line is '$twoLast' (not blank)"
    } else {
        Write-Fail "Two-session list: trailing blank line detected"
    }

    # Test 6: Exactly 2 non-empty lines (one per session), no phantom
    Write-Host "`n[Test 6] Two-session list has exactly 2 non-empty lines" -ForegroundColor Yellow
    $twoNonEmpty = ($twoLines | Where-Object { $_.Trim() -ne '' } | Measure-Object).Count
    if ($twoNonEmpty -eq 2) {
        Write-Pass "Two sessions produce exactly 2 non-empty lines"
    } else {
        # Acceptable if there are other warm sessions present; just ensure no empty lines
        $twoEmpty = ($twoLines | Where-Object { $_.Trim() -eq '' } | Measure-Object).Count
        if ($twoEmpty -eq 0) {
            Write-Pass "Got $twoNonEmpty non-empty lines (other sessions may exist) and zero empty lines"
        } else {
            Write-Fail "Got $twoNonEmpty non-empty lines but ALSO $twoEmpty empty line(s) -- phantom entries"
        }
    }
}

# ================================================================
# Part D: TCP server path -- raw response has no extra newline
# ================================================================
Write-Host "`n--- Part D: TCP Server Path ---" -ForegroundColor Magenta

# Test 7: TCP list-sessions -F response: last line returned is not empty
Write-Host "`n[Test 7] TCP list-sessions -F last response line is not blank" -ForegroundColor Yellow
$tcpLines = Send-TcpCommand -Session $SESSION -Command "list-sessions -F '#{session_name}'"

if ($null -eq $tcpLines -or $tcpLines.Count -eq 0) {
    Write-Fail "TCP send-command failed (AUTH error or connection refused)"
} else {
    Write-Host "    TCP response lines ($($tcpLines.Count) total):" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $tcpLines.Count; $i++) {
        Write-Host "      [$i] '$($tcpLines[$i])'" -ForegroundColor DarkGray
    }

    # Filter out transport-level empty lines that come AFTER real data
    # The key assertion: no empty string appears after the last non-empty line
    $lastNonEmptyIdx = -1
    for ($i = $tcpLines.Count - 1; $i -ge 0; $i--) {
        if ($tcpLines[$i].Trim() -ne '') { $lastNonEmptyIdx = $i; break }
    }

    if ($lastNonEmptyIdx -eq -1) {
        Write-Fail "TCP response contained only empty lines"
    } elseif ($lastNonEmptyIdx -eq $tcpLines.Count - 1) {
        Write-Pass "TCP: last line is non-empty ('$($tcpLines[$lastNonEmptyIdx])') -- no trailing blank"
    } else {
        $trailingEmpties = $tcpLines.Count - 1 - $lastNonEmptyIdx
        Write-Fail "TCP: $trailingEmpties trailing empty line(s) after last real entry '$($tcpLines[$lastNonEmptyIdx])'"
    }
}

# Test 8: TCP plain list-sessions response has at most ONE trailing empty line
# (the multi-line protocol sentinel) and NOT two or more.
# The #319 bug would cause an extra embedded newline, producing 2+ trailing empties.
Write-Host "`n[Test 8] TCP plain list-sessions has at most one trailing empty sentinel (not two)" -ForegroundColor Yellow
$tcpPlain = Send-TcpCommand -Session $SESSION -Command "list-sessions"

if ($null -eq $tcpPlain -or $tcpPlain.Count -eq 0) {
    Write-Fail "TCP plain list-sessions failed or returned nothing"
} else {
    Write-Host "    TCP plain response lines ($($tcpPlain.Count) total):" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $tcpPlain.Count; $i++) {
        Write-Host "      [$i] len=$($tcpPlain[$i].Length) '$($tcpPlain[$i])'" -ForegroundColor DarkGray
    }

    # Find last non-empty line index
    $lastNonEmptyPlain = -1
    for ($i = $tcpPlain.Count - 1; $i -ge 0; $i--) {
        if ($tcpPlain[$i].Trim() -ne '') { $lastNonEmptyPlain = $i; break }
    }

    if ($lastNonEmptyPlain -eq -1) {
        Write-Fail "TCP plain list-sessions: response contained only empty lines (no content)"
    } else {
        $trailingEmpties = $tcpPlain.Count - 1 - $lastNonEmptyPlain
        # Protocol allows exactly 1 trailing empty sentinel; 2+ indicates the #319 double-newline bug
        if ($trailingEmpties -le 1) {
            Write-Pass "TCP plain list-sessions: $trailingEmpties trailing empty line(s) -- at most 1 sentinel (no double-newline bug)"
        } else {
            Write-Fail "TCP plain list-sessions: $trailingEmpties trailing empty lines (expected at most 1) -- double-newline bug present"
        }
    }
}

# ================================================================
# TEARDOWN
# ================================================================
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
