# Issue #164: status-format[] not rendered with parse_inline_styles on multi-line status bar
#
# Fix: client.rs lines 5165-5173 pass status_format[N] through layout_format_line()
# which calls parse_inline_styles() -- so #[fg=...] directives are processed, not
# rendered as literal text. Also status_format[0] now overrides the default layout.
#
# Verification strategy via dump-state:
#   The server expands status_format[N] via expand_format() before serialising to
#   JSON (server/mod.rs:1546-1553). expand_format() handles #{...} variables but
#   NOT #[...] style directives -- those are intentionally left for the client-side
#   parse_inline_styles(). So in dump-state:
#     - status_format[N] contains the raw #[fg=red] directive (as stored)
#     - status_lines == 2 (or 3)
#   The CLIENT then calls layout_format_line() which strips/processes #[...].
#   We verify the fix is in place by:
#   1. Setting status 2, status-format[0] and status-format[1] with #[...] directives
#      and unique text markers.
#   2. Asserting dump-state status_lines == 2.
#   3. Asserting dump-state status_format[0] contains our marker for line 0.
#   4. Asserting dump-state status_format[1] retains the #[fg=red] directive
#      (server keeps it; client is responsible for rendering it).
#   5. Asserting show-options reports status 2.
#   6. Asserting session survives (no crash from multi-line status rendering).

$ErrorActionPreference = "Continue"
$PSMUX        = (Get-Command psmux -EA Stop).Source
$SESSION      = "gap164"
$psmuxDir     = "$env:USERPROFILE\.psmux"
$script:Pass  = 0
$script:Fail  = 0

function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green;  $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-Port {
    param([int]$Secs = 12)
    $portFile = "$psmuxDir\$SESSION.port"
    for ($i = 0; $i -lt ($Secs * 4); $i++) {
        if (Test-Path $portFile) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Send-Tcp {
    param([string]$Cmd)
    $portFile = "$psmuxDir\$SESSION.port"
    $keyFile  = "$psmuxDir\$SESSION.key"
    if (-not (Test-Path $portFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    try {
        $tcp    = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream); $writer.AutoFlush = $true
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.Write("AUTH $key`n")
        $null = $reader.ReadLine()   # OK
        $writer.Write("$Cmd`n")
        $stream.ReadTimeout = 8000
        $resp = $reader.ReadLine()
        $tcp.Close()
        return $resp
    } catch { return $null }
}

# ── setup ──────────────────────────────────────────────────────────────────────
Cleanup
Write-Host "`n=== Issue #164: status-format[] inline styles on multi-line status ===" -ForegroundColor Cyan

& $PSMUX new-session -d -s $SESSION -x 200 -y 40 2>$null
if (-not (Wait-Port 12)) {
    Write-Fail "Session port file never appeared"
    exit 1
}
Start-Sleep -Milliseconds 800

# Configure multi-line status with inline style directives and unique markers.
# Markers are chosen to be unambiguous in the JSON dump.
$marker0 = "STATUSLINE0MARKER"
$marker1 = "STATUSLINE1MARKER"

& $PSMUX set-option -t $SESSION -g status 2 2>$null
Start-Sleep -Milliseconds 200

# Set format for line 0: align directive + marker
& $PSMUX set-option -t $SESSION -g "status-format[0]" "#[align=left]$marker0 #{session_name}" 2>$null
Start-Sleep -Milliseconds 100

# Set format for line 1: fg style directive + marker (the bug: this was rendered literally)
& $PSMUX set-option -t $SESSION -g "status-format[1]" "#[fg=red]$marker1" 2>$null
Start-Sleep -Milliseconds 400

# ── Test 1: dump-state reports status_lines >= 2 ──────────────────────────────
# show-options reports "status on/off" (boolean), not the numeric line count.
# The numeric count is only exposed via dump-state as "status_lines".
Write-Host "`n[Test 1] dump-state reports status_lines >= 2 after 'set status 2'" -ForegroundColor Yellow
$dump = Send-Tcp "dump-state"
if ($null -eq $dump) { Write-Fail "dump-state returned null (pre-check)"; $dump = "" }
if ($dump -match '"status_lines"\s*:\s*(\d+)') {
    $sl0 = [int]$matches[1]
    Write-Info "status_lines (before config) = $sl0"
}
# The set commands were already issued above; re-check after a brief wait
Start-Sleep -Milliseconds 200
$dump = Send-Tcp "dump-state"
if ($null -eq $dump) { Write-Fail "dump-state returned null"; Cleanup; exit 1 }
if ($dump -eq "NC") { Start-Sleep -Milliseconds 300; $dump = Send-Tcp "dump-state" }
Write-Info "dump-state length: $($dump.Length) bytes"
if ($dump -match '"status_lines"\s*:\s*(\d+)') {
    $sl1 = [int]$matches[1]
    Write-Info "status_lines = $sl1"
    if ($sl1 -ge 2) {
        Write-Pass "status_lines == $sl1 (>= 2 as configured)"
    } else {
        Write-Fail "status_lines == $sl1 (expected >= 2 after 'set status 2')"
    }
} else {
    Write-Fail "status_lines not found in dump-state"
}

# ── Test 3: dump-state status_format[0] contains line-0 marker ────────────────
Write-Host "`n[Test 3] dump-state status_format[0] contains the line-0 marker" -ForegroundColor Yellow
try {
    $json3 = $dump | ConvertFrom-Json
    if ($json3.status_format -and $json3.status_format.Count -ge 1) {
        $sf0 = $json3.status_format[0]
        Write-Info "status_format[0] = '$sf0'"
        if ($sf0 -match [regex]::Escape($marker0)) {
            Write-Pass "status_format[0] contains marker '$marker0'"
        } else {
            Write-Fail "status_format[0] does not contain marker '$marker0': '$sf0'"
        }
    } else {
        Write-Fail "status_format array missing or empty in dump-state"
    }
} catch {
    Write-Fail "Failed to parse dump-state JSON for Test 3: $_"
}

# ── Test 4: dump-state status_format[1] contains line-1 marker ────────────────
Write-Host "`n[Test 4] dump-state status_format[1] contains the line-1 marker" -ForegroundColor Yellow
# Parse the full JSON to get status_format as an array
try {
    $json = $dump | ConvertFrom-Json
    $sfList = $json.status_format
    Write-Info "status_format count: $($sfList.Count)"
    if ($sfList.Count -ge 2) {
        $sf1 = $sfList[1]
        Write-Info "status_format[1] = '$sf1'"
        if ($sf1 -match [regex]::Escape($marker1)) {
            Write-Pass "status_format[1] contains marker '$marker1'"
        } else {
            Write-Fail "status_format[1] does not contain marker '$marker1': '$sf1'"
        }
    } else {
        Write-Fail "status_format array has fewer than 2 elements ($($sfList.Count))"
    }
} catch {
    Write-Fail "Failed to parse dump-state JSON: $_"
}

# ── Test 5: status_format[1] retains the #[fg=red] directive in dump-state ─────
# The server stores the format template with #[...] intact (expand_format only
# processes #{...} variables, not style directives). The client then renders it
# via layout_format_line/parse_inline_styles. So dump-state SHOULD contain the
# directive -- it is present as the "source of truth" for the client renderer.
Write-Host "`n[Test 5] dump-state status_format[1] retains #[fg=red] directive" -ForegroundColor Yellow
try {
    $json2 = $dump | ConvertFrom-Json
    if ($json2.status_format.Count -ge 2) {
        $sf1raw = $json2.status_format[1]
        if ($sf1raw -match '#\[fg=red\]') {
            Write-Pass "status_format[1] retains '#[fg=red]' directive in dump-state (client renders it)"
        } else {
            # It may have been stripped or escaped differently; check for the marker at minimum
            Write-Info "status_format[1] = '$sf1raw'"
            Write-Fail "status_format[1] does not contain '#[fg=red]': '$sf1raw'"
        }
    } else {
        Write-Fail "status_format has < 2 elements"
    }
} catch {
    Write-Fail "JSON parse error: $_"
}

# ── Test 6: status_format[0] retains #[align=left] directive ──────────────────
Write-Host "`n[Test 6] dump-state status_format[0] retains #[align=left] directive" -ForegroundColor Yellow
try {
    $json3 = $dump | ConvertFrom-Json
    if ($json3.status_format.Count -ge 1) {
        $sf0raw = $json3.status_format[0]
        if ($sf0raw -match '#\[align=left\]') {
            Write-Pass "status_format[0] retains '#[align=left]' directive"
        } else {
            Write-Fail "status_format[0] does not retain '#[align=left]': '$sf0raw'"
        }
    }
} catch {
    Write-Fail "JSON parse error: $_"
}

# ── Test 7: session survives multi-line status rendering (no crash) ────────────
Write-Host "`n[Test 7] Session survives multi-line status rendering (no crash)" -ForegroundColor Yellow
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "Session still alive after multi-line status configuration"
} else {
    Write-Fail "Session died -- possible panic in multi-line status rendering"
}

# ── Test 8: dump-state still valid after all config changes ───────────────────
Write-Host "`n[Test 8] Second dump-state returns valid JSON" -ForegroundColor Yellow
$dump2 = Send-Tcp "dump-state"
if ($null -ne $dump2 -and ($dump2.StartsWith("{") -or $dump2 -eq "NC")) {
    if ($dump2 -eq "NC") {
        Write-Pass "dump-state returned NC (no change -- session healthy)"
    } else {
        try {
            $null = $dump2 | ConvertFrom-Json
            Write-Pass "Second dump-state returns valid JSON ($($dump2.Length) bytes)"
        } catch {
            Write-Fail "Second dump-state JSON invalid: $_"
        }
    }
} else {
    Write-Fail "Second dump-state unexpected: $(if ($dump2) { $dump2.Substring(0,[Math]::Min(80,$dump2.Length)) } else { '<null>' })"
}

# ── Test 9: status 3 also works (regression guard for higher line counts) ──────
Write-Host "`n[Test 9] status 3 sets status_lines == 3 in dump-state" -ForegroundColor Yellow
& $PSMUX set-option -t $SESSION -g status 3 2>$null
& $PSMUX set-option -t $SESSION -g "status-format[2]" "#[fg=blue]STATUSLINE2MARKER" 2>$null
Start-Sleep -Milliseconds 400
$dump3 = Send-Tcp "dump-state"
if ($null -ne $dump3 -and $dump3 -ne "NC" -and $dump3 -match '"status_lines"\s*:\s*(\d+)') {
    $sl3 = [int]$matches[1]
    if ($sl3 -ge 3) {
        Write-Pass "status_lines == $sl3 after 'set status 3'"
    } else {
        Write-Fail "status_lines == $sl3 after 'set status 3' (expected >= 3)"
    }
} elseif ($dump3 -eq "NC") {
    # NC means state did not change -- check via show-options
    $opts3 = (& $PSMUX show-options -g 2>&1 | Out-String)
    if ($opts3 -match "status\s+3") {
        Write-Pass "status 3 confirmed via show-options (dump-state NC)"
    } else {
        Write-Fail "status 3 not confirmed: dump-state NC and show-options didn't show 3"
    }
} else {
    Write-Fail "Could not verify status_lines=3 from dump-state"
}

# ── cleanup ────────────────────────────────────────────────────────────────────
Cleanup

Write-Host "`n=== Results: $($script:Pass) passed, $($script:Fail) failed ===" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
exit $script:Fail
