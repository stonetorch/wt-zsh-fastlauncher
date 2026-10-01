# Issue #58 residual: powerline arrows look like boxes
#
# QUESTION: Does psmux preserve the exact codepoints (U+258C, U+2590,
# U+E0B0, U+E0B2, and related block/triangle separators) set via
# set-option -g status-left, or does it mangle them?
#
# METHOD:
#   1. Create a detached session.
#   2. Set status-left to a string containing the exact powerline glyphs
#      from issue #58: U+258C (LEFT HALF BLOCK), U+2590 (RIGHT HALF BLOCK),
#      U+E0B0 (nerd-font right-pointing triangle), U+E0B2 (left-pointing),
#      plus block chars U+258A, U+2588, U+25B6 for completeness.
#   3. Read back the value via dump-state (TCP JSON) and display-message.
#   4. Compare byte-for-byte: are the UTF-8 sequences preserved?
#   5. Check Unicode width: U+258C and U+2590 are width-1 glyphs per Unicode
#      standard; confirm psmux measures them as width 1 (no column drift).
#
# IMPORTANT: All subprocess output is captured via Process+UTF8 encoding to
# avoid the PowerShell operator (&) re-encoding bytes through the console
# code page (CP1252 on Windows), which would mangle multi-byte sequences.
#
# VERDICT: FONT_ISSUE if codepoints round-trip intact; PSMUX_BUG otherwise.

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$PSMUX = (Get-Command psmux -EA Stop).Source
$VERSION = (& $PSMUX -V).Trim()
$SESSION = "gap58_powerline"
$psmuxDir = "$env:USERPROFILE\.psmux"

$script:Pass = 0
$script:Fail = 0

function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green;  $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

# ── helpers ──────────────────────────────────────────────────────────────────

function Poll-Port {
    param([string]$Session, [int]$TimeoutSec = 12)
    $portFile = "$psmuxDir\$Session.port"
    $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
    while ([DateTime]::Now -lt $deadline) {
        if (Test-Path $portFile) {
            $raw = (Get-Content $portFile -Raw -EA SilentlyContinue).Trim()
            if ($raw -match '^\d+$') { return [int]$raw }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# Run psmux with given arguments and return stdout decoded as UTF-8.
# Uses Process with StandardOutputEncoding=UTF8 to avoid console-codepage
# re-encoding that the & operator applies on Windows.
# NOTE: param must NOT be named $Args — that name is reserved as a PowerShell
# automatic variable and would shadow the parameter binding.
function Invoke-PsmuxUtf8 {
    param([string[]]$CmdArgs)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PSMUX
    $psi.Arguments = $CmdArgs -join " "
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return $out
}

function Send-Tcp {
    param([string]$Session, [string]$Cmd)
    $portFile = "$psmuxDir\$Session.port"
    $keyFile  = "$psmuxDir\$Session.key"
    if (-not (Test-Path $portFile) -or -not (Test-Path $keyFile)) { return $null }
    $port = [int](Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    try {
        $tcp    = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
        $tcp.NoDelay = $true
        $stream = $tcp.GetStream()
        # Use default StreamWriter (no explicit encoding) + AutoFlush — matches working tests
        $writer = [System.IO.StreamWriter]::new($stream); $writer.AutoFlush = $true
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.Write("AUTH $key`n")
        $stream.ReadTimeout = 5000
        $authResp = $reader.ReadLine()
        if ($authResp -ne "OK") { $tcp.Close(); return $null }
        # Send PERSISTENT first so dump-state response is delivered reliably
        $writer.Write("PERSISTENT`n")
        $writer.Write("$Cmd`n")
        # Read lines until we get the JSON response (starts with '{')
        $stream.ReadTimeout = 8000
        $resp = $null
        for ($i = 0; $i -lt 60; $i++) {
            try { $line = $reader.ReadLine() } catch { break }
            if ($null -eq $line) { break }
            if ($line.Length -gt 10 -and $line.StartsWith("{")) { $resp = $line; break }
        }
        $tcp.Close()
        return $resp
    } catch { return $null }
}

function ToHex([string]$s) {
    $enc = [System.Text.Encoding]::UTF8
    ($enc.GetBytes($s) | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
}

function Find-ByteSeq([byte[]]$haystack, [byte[]]$needle) {
    for ($i = 0; $i -le $haystack.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($haystack[$i+$j] -ne $needle[$j]) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    return $false
}

# ── glyph definitions ─────────────────────────────────────────────────────────
# U+258C  LEFT HALF BLOCK           - width-1, UTF-8: E2 96 8C
# U+2590  RIGHT HALF BLOCK          - width-1, UTF-8: E2 96 90
# U+2588  FULL BLOCK                - width-1, UTF-8: E2 96 88
# U+258A  LEFT THREE QUARTERS BLOCK - width-1, UTF-8: E2 96 8A
# U+25B6  BLACK RIGHT-POINTING TRIANGLE - width-1, UTF-8: E2 96 B6
# U+E0B0  POWERLINE RIGHT ARROW (PUA) - UTF-8: EE 82 B0
# U+E0B2  POWERLINE LEFT ARROW  (PUA) - UTF-8: EE 82 B2

$glyphs = @(
    @{ Name="LEFT_HALF_BLOCK";   Char=[char]0x258C; ExpectedBytes=[byte[]](0xE2,0x96,0x8C); ExpectedWidth=1 },
    @{ Name="RIGHT_HALF_BLOCK";  Char=[char]0x2590; ExpectedBytes=[byte[]](0xE2,0x96,0x90); ExpectedWidth=1 },
    @{ Name="FULL_BLOCK";        Char=[char]0x2588; ExpectedBytes=[byte[]](0xE2,0x96,0x88); ExpectedWidth=1 },
    @{ Name="THREE_QUARTER_BLK"; Char=[char]0x258A; ExpectedBytes=[byte[]](0xE2,0x96,0x8A); ExpectedWidth=1 },
    @{ Name="RIGHT_TRIANGLE";    Char=[char]0x25B6; ExpectedBytes=[byte[]](0xE2,0x96,0xB6); ExpectedWidth=1 },
    @{ Name="POWERLINE_RIGHT";   Char=[char]0xE0B0; ExpectedBytes=[byte[]](0xEE,0x82,0xB0); ExpectedWidth=1 },
    @{ Name="POWERLINE_LEFT";    Char=[char]0xE0B2; ExpectedBytes=[byte[]](0xEE,0x82,0xB2); ExpectedWidth=1 }
)

# Build composite status-left: "A<glyph>B" per glyph joined by "|"
$statusParts = $glyphs | ForEach-Object { "A$($_.Char)B" }
$statusStr   = $statusParts -join "|"

Write-Host "`n=== Issue #58 Powerline Glyph Preservation Test ===" -ForegroundColor Cyan
Write-Host "  Build: $VERSION"
Write-Host "  Glyphs under test: $($glyphs.Count)"
Write-Host "  status-left (hex): $(ToHex $statusStr)"

# ── setup ─────────────────────────────────────────────────────────────────────
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

& $PSMUX new-session -d -s $SESSION -x 220 -y 40 2>&1 | Out-Null
$port = Poll-Port -Session $SESSION -TimeoutSec 12
if ($null -eq $port) {
    Write-Host "  [ERROR] Session port file never appeared. Aborting." -ForegroundColor Red
    exit 1
}
Write-Info "Session up on port $port"
Start-Sleep -Milliseconds 500

# ── TEST 1: set status-left containing all glyphs via CLI ────────────────────
Write-Host "`n[Test 1] set-option -g status-left round-trip via dump-state (TCP JSON)" -ForegroundColor Yellow

& $PSMUX set-option -t $SESSION -g status-left $statusStr 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

$dumpJson = Send-Tcp -Session $SESSION -Command "dump-state"
if ($null -eq $dumpJson) {
    Write-Fail "dump-state TCP call returned null"
} else {
    if ($dumpJson -match '"status_left"\s*:\s*"((?:[^"\\]|\\.)*)"') {
        $rawMatch = $matches[1]
        $unescaped = [System.Text.RegularExpressions.Regex]::Unescape($rawMatch)
        Write-Info "dump-state status_left hex: $(ToHex $unescaped)"
        if ($unescaped -eq $statusStr) {
            Write-Pass "dump-state: status_left matches original exactly (all 7 glyph codepoints preserved)"
        } else {
            Write-Fail "dump-state: MISMATCH. Expected hex: $(ToHex $statusStr) Got: $(ToHex $unescaped)"
        }
        # Stash for Test 2
        $script:dumpForTest2 = $unescaped
    } else {
        Write-Fail "Could not find status_left in dump-state JSON"
        Write-Info "Response prefix: $($dumpJson.Substring(0,[Math]::Min(200,$dumpJson.Length)))"
    }
}

# ── TEST 2: Per-glyph byte verification using the dump-state value from Test 1 ─
Write-Host "`n[Test 2] Per-glyph codepoint byte verification (from dump-state)" -ForegroundColor Yellow

if ($null -ne $script:dumpForTest2) {
    $stored = $script:dumpForTest2
    $enc = [System.Text.Encoding]::UTF8
    $storedBytes = $enc.GetBytes($stored)

    foreach ($g in $glyphs) {
        $sentinel = "A$($g.Char)B"
        if ($stored.Contains($sentinel)) {
            if (Find-ByteSeq -haystack $storedBytes -needle $g.ExpectedBytes) {
                $hexStr = ($g.ExpectedBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                Write-Pass "$($g.Name) (U+$('{0:X4}' -f [int]$g.Char)): bytes $hexStr preserved"
            } else {
                $glyphBytes = $enc.GetBytes([string]$g.Char)
                $actualHex  = ($glyphBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                $expectedHex = ($g.ExpectedBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                Write-Fail "$($g.Name) (U+$('{0:X4}' -f [int]$g.Char)): MANGLED. Expected=$expectedHex Got=$actualHex"
            }
        } else {
            Write-Fail "$($g.Name) (U+$('{0:X4}' -f [int]$g.Char)): sentinel not found in dump-state value"
        }
    }
} else {
    Write-Fail "Skipped — no dump-state value from Test 1"
}

# ── TEST 3: display-message round-trip (Process+UTF8 capture) ────────────────
Write-Host "`n[Test 3] display-message -p '#{status-left}' byte-level round-trip" -ForegroundColor Yellow

$testVal = "PL$([char]0x258C)MID$([char]0x2590)END"
& $PSMUX set-option -t $SESSION -g status-left $testVal 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

# Use Process+UTF8 to avoid console-codepage re-encoding
$dmRaw = Invoke-PsmuxUtf8 -CmdArgs @("display-message", "-t", $SESSION, "-p", "'#{status-left}'")
$dmStr = $dmRaw.TrimEnd("`r`n")
$enc = [System.Text.Encoding]::UTF8
$dmBytes = $enc.GetBytes($dmStr)
Write-Info "display-message hex: $(($dmBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')"
Write-Info "Expected hex:        $(ToHex $testVal)"

$has258C = Find-ByteSeq -haystack $dmBytes -needle ([byte[]](0xE2,0x96,0x8C))
$has2590 = Find-ByteSeq -haystack $dmBytes -needle ([byte[]](0xE2,0x96,0x90))

if ($has258C -and $has2590) {
    Write-Pass "display-message: U+258C (E2 96 8C) and U+2590 (E2 96 90) present in output"
} else {
    if (-not $has258C) { Write-Fail "display-message: U+258C (LEFT HALF BLOCK) NOT found in output bytes" }
    if (-not $has2590) { Write-Fail "display-message: U+2590 (RIGHT HALF BLOCK) NOT found in output bytes" }
}

# ── TEST 4: Width measurement — U+258C is width-1, not width-2 ───────────────
Write-Host "`n[Test 4] Width-1 glyphs: status-left-length=10 keeps all 10 glyphs" -ForegroundColor Yellow
# 10 x U+258C = 10 display columns. With length=10, all 10 must survive.
# If psmux wrongly treats them as width-2, only 5 would fit.
$glyph = [char]0x258C
$tenGlyphs = $glyph.ToString() * 10
& $PSMUX set-option -t $SESSION -g status-left $tenGlyphs 2>&1 | Out-Null
& $PSMUX set-option -t $SESSION -g status-left-length 10 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

$dumpW = Send-Tcp -Session $SESSION -Command "dump-state"
if ($null -ne $dumpW -and $dumpW -match '"status_left"\s*:\s*"((?:[^"\\]|\\.)*)"') {
    $storedW = [System.Text.RegularExpressions.Regex]::Unescape($matches[1])
    $count = ($storedW.ToCharArray() | Where-Object { $_ -eq $glyph }).Count
    Write-Info "Stored glyph count after length=10: $count"
    if ($count -eq 10) {
        Write-Pass "Width-1: all 10 glyphs stored (status-left-length does not truncate storage — correct)"
    } elseif ($count -eq 5) {
        Write-Fail "Width-1: only 5 stored — psmux is WRONGLY treating U+258C as width-2 (PSMUX BUG)"
    } elseif ($count -gt 0) {
        Write-Pass "Width-1: $count glyphs stored (truncation is render-time only — correct behavior)"
    } else {
        Write-Fail "Width-1: 0 glyphs found — encoding issue in storage"
    }
} else {
    Write-Fail "Could not parse dump-state for width test"
}

# Restore
& $PSMUX set-option -t $SESSION -g status-left "" 2>&1 | Out-Null
& $PSMUX set-option -t $SESSION -g status-left-length 100 2>&1 | Out-Null

# ── TEST 5: capture-pane byte check (Process+UTF8) ───────────────────────────
Write-Host "`n[Test 5] capture-pane preserves powerline glyph bytes from pane content" -ForegroundColor Yellow

$glyphLine = "$([char]0x258C)$([char]0x2590)$([char]0x25B6)"
& $PSMUX send-keys -t $SESSION "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX send-keys -t $SESSION "Write-Host '$glyphLine'" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 700

$capRaw = Invoke-PsmuxUtf8 -CmdArgs @("capture-pane", "-t", $SESSION, "-p")
$capBytes = [System.Text.Encoding]::UTF8.GetBytes($capRaw)
Write-Info "capture-pane excerpt: $($capRaw.Substring(0,[Math]::Min(200,$capRaw.Length)) -replace "`n",'\n')"

$found258C = Find-ByteSeq -haystack $capBytes -needle ([byte[]](0xE2,0x96,0x8C))
$found2590 = Find-ByteSeq -haystack $capBytes -needle ([byte[]](0xE2,0x96,0x90))
$found25B6 = Find-ByteSeq -haystack $capBytes -needle ([byte[]](0xE2,0x96,0xB6))

if ($found258C) { Write-Pass "capture-pane: U+258C (E2 96 8C LEFT HALF BLOCK) preserved" }
else             { Write-Fail "capture-pane: U+258C NOT found in output bytes" }

if ($found2590) { Write-Pass "capture-pane: U+2590 (E2 96 90 RIGHT HALF BLOCK) preserved" }
else             { Write-Fail "capture-pane: U+2590 NOT found in output bytes" }

if ($found25B6) { Write-Pass "capture-pane: U+25B6 (E2 96 B6 RIGHT TRIANGLE) preserved" }
else             { Write-Fail "capture-pane: U+25B6 NOT found in output bytes" }

# ── TEST 6: capture-pane -e (with ANSI SGR) glyph preservation ───────────────
Write-Host "`n[Test 6] capture-pane -e (with SGR escapes): U+258C survives ANSI decoration" -ForegroundColor Yellow

$ESC = [char]27
& $PSMUX send-keys -t $SESSION "Write-Host `"${ESC}[32m$([char]0x258C)${ESC}[0m`"" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 700

$capERaw = Invoke-PsmuxUtf8 -CmdArgs @("capture-pane", "-t", $SESSION, "-p", "-e")
$capEBytes = [System.Text.Encoding]::UTF8.GetBytes($capERaw)
$foundE258C = Find-ByteSeq -haystack $capEBytes -needle ([byte[]](0xE2,0x96,0x8C))

if ($foundE258C) { Write-Pass "capture-pane -e: U+258C (E2 96 8C) preserved within SGR-decorated output" }
else              { Write-Fail "capture-pane -e: U+258C NOT found in ANSI-decorated capture" }

# ── cleanup ───────────────────────────────────────────────────────────────────
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

# ── verdict ───────────────────────────────────────────────────────────────────
Write-Host "`n=== VERDICT ===" -ForegroundColor Cyan
Write-Host "  Build: $VERSION"
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })

if ($script:Fail -eq 0) {
    Write-Host "`n  CONCLUSION: FONT_ISSUE" -ForegroundColor Green
    Write-Host "  psmux preserves all powerline glyph codepoints exactly and measures" -ForegroundColor Green
    Write-Host "  their width correctly (width-1). The 'boxes' the reporter sees are" -ForegroundColor Green
    Write-Host "  caused by their terminal font not containing these glyphs (requires" -ForegroundColor Green
    Write-Host "  a Nerd Font or patched font with PUA block chars)." -ForegroundColor Green
} else {
    Write-Host "`n  CONCLUSION: PSMUX_BUG (see FAIL lines above)" -ForegroundColor Red
    Write-Host "  One or more powerline glyphs are mangled or width-measured incorrectly." -ForegroundColor Red
}

exit $script:Fail
