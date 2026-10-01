# Feature test: choose-tree-preview global option
# Proves the option works through every code path:
#   - Default value
#   - CLI set / get / show-options round-trip
#   - Config file (source-file) round-trip
#   - TCP server set/show round-trip
#   - format variable lookup
#   - JSON snapshot delivery to client (dump-state)
#   - unset reverts to default
#   - Win32 TUI: chooser opens with option on/off without crashing

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "ctp_test"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup {
    foreach ($s in @($SESSION, "ctp_cfg", "ctp_tui_on", "ctp_tui_off")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 500
    Get-ChildItem $psmuxDir -Filter "ctp_*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

function Get-OptionValue {
    param([string]$Opt, [string]$Target = $SESSION)
    (& $PSMUX show-options -g -v $Opt -t $Target 2>&1 | Out-String).Trim()
}

function Show-OptionsLine {
    param([string]$Opt, [string]$Target = $SESSION)
    $all = & $PSMUX show-options -g -t $Target 2>&1 | Out-String
    ($all -split "`n" | Where-Object { $_ -match "^\s*$Opt\s" } | Select-Object -First 1).Trim()
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command, [int]$ReadTimeoutMs = 5000)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $auth = $reader.ReadLine()
    if ($auth -ne "OK") { $tcp.Close(); return "AUTH_FAILED:$auth" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = $ReadTimeoutMs
    $sb = [System.Text.StringBuilder]::new()
    try {
        for ($i=0; $i -lt 50; $i++) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            [void]$sb.AppendLine($line)
            if ($line -eq "OK" -or $line -eq "END" -or $line.StartsWith("ERR")) { break }
        }
    } catch {}
    $tcp.Close()
    return $sb.ToString().Trim()
}

function Get-DumpState {
    param([string]$Session)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush(); $null = $reader.ReadLine()
    # One-shot dump-state (no PERSISTENT) returns the JSON inline
    $writer.Write("dump-state`n"); $writer.Flush()
    $best = $null
    for ($j = 0; $j -lt 20; $j++) {
        try { $line = $reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line.Length -gt 100 -and $line.StartsWith("{")) { $best = $line; break }
    }
    $tcp.Close()
    return $best
}

# ============================================================================
# SETUP
# ============================================================================
Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "FATAL: could not create test session" -ForegroundColor Red
    exit 99
}

Write-Host "`n=== choose-tree-preview Option Tests ===" -ForegroundColor Cyan

# ----------------------------------------------------------------------------
# TEST 1: Default value is "off"
# ----------------------------------------------------------------------------
Write-Host "`n[Test 1] Default value" -ForegroundColor Yellow
# Make sure we start clean - unset in case warm config persisted something
& $PSMUX set-option -g -u choose-tree-preview 2>&1 | Out-Null
$default = Get-OptionValue "choose-tree-preview"
if ($default -eq "off") { Write-Pass "Default is 'off' (got '$default')" }
else { Write-Fail "Default expected 'off', got '$default'" }

$line = Show-OptionsLine "choose-tree-preview"
if ($line -match "choose-tree-preview\s+off") { Write-Pass "show-options lists 'choose-tree-preview off'" }
else { Write-Fail "show-options line wrong: '$line'" }

# ----------------------------------------------------------------------------
# TEST 2: CLI set on -> show on
# ----------------------------------------------------------------------------
Write-Host "`n[Test 2] CLI set 'on'" -ForegroundColor Yellow
& $PSMUX set -g choose-tree-preview on 2>&1 | Out-Null
$v = Get-OptionValue "choose-tree-preview"
if ($v -eq "on") { Write-Pass "After 'set on', show-options reports 'on'" }
else { Write-Fail "After 'set on', got '$v'" }

# Also test set-option (long form)
& $PSMUX set-option -g choose-tree-preview off 2>&1 | Out-Null
$v = Get-OptionValue "choose-tree-preview"
if ($v -eq "off") { Write-Pass "set-option -g choose-tree-preview off persists" }
else { Write-Fail "set-option off failed, got '$v'" }

# ----------------------------------------------------------------------------
# TEST 3: Aliases for boolean (true/1)
# ----------------------------------------------------------------------------
Write-Host "`n[Test 3] Boolean aliases" -ForegroundColor Yellow
& $PSMUX set -g choose-tree-preview true 2>&1 | Out-Null
$v = Get-OptionValue "choose-tree-preview"
if ($v -eq "on") { Write-Pass "'true' is accepted as on (got '$v')" }
else { Write-Fail "'true' should map to on, got '$v'" }

& $PSMUX set -g choose-tree-preview off 2>&1 | Out-Null
& $PSMUX set -g choose-tree-preview 1 2>&1 | Out-Null
$v = Get-OptionValue "choose-tree-preview"
if ($v -eq "on") { Write-Pass "'1' is accepted as on (got '$v')" }
else { Write-Fail "'1' should map to on, got '$v'" }

# Random other string -> off
& $PSMUX set -g choose-tree-preview banana 2>&1 | Out-Null
$v = Get-OptionValue "choose-tree-preview"
if ($v -eq "off") { Write-Pass "Unknown value 'banana' falls back to off" }
else { Write-Fail "Unknown value should be off, got '$v'" }

# ----------------------------------------------------------------------------
# TEST 4: unset reverts to default
# ----------------------------------------------------------------------------
Write-Host "`n[Test 4] unset reverts to default" -ForegroundColor Yellow
& $PSMUX set -g choose-tree-preview on 2>&1 | Out-Null
$v = Get-OptionValue "choose-tree-preview"
if ($v -ne "on") { Write-Fail "Could not set to on, got '$v'" }
& $PSMUX set-option -g -u choose-tree-preview 2>&1 | Out-Null
$v = Get-OptionValue "choose-tree-preview"
if ($v -eq "off") { Write-Pass "set-option -u reverts to default 'off'" }
else { Write-Fail "After unset expected off, got '$v'" }

# ----------------------------------------------------------------------------
# TEST 5: format variable #{choose-tree-preview}
# ----------------------------------------------------------------------------
Write-Host "`n[Test 5] format variable lookup" -ForegroundColor Yellow
& $PSMUX set -g choose-tree-preview on 2>&1 | Out-Null
$fv = (& $PSMUX display-message -t $SESSION -p '#{choose-tree-preview}' 2>&1 | Out-String).Trim()
if ($fv -eq "on") { Write-Pass "#{choose-tree-preview} resolves to 'on'" }
else { Write-Fail "#{choose-tree-preview} should be 'on', got '$fv'" }

& $PSMUX set -g choose-tree-preview off 2>&1 | Out-Null
$fv = (& $PSMUX display-message -t $SESSION -p '#{choose-tree-preview}' 2>&1 | Out-String).Trim()
if ($fv -eq "off") { Write-Pass "#{choose-tree-preview} resolves to 'off'" }
else { Write-Fail "#{choose-tree-preview} should be 'off', got '$fv'" }

# ----------------------------------------------------------------------------
# TEST 6: TCP server set/show round-trip
# ----------------------------------------------------------------------------
Write-Host "`n[Test 6] TCP set/show round-trip" -ForegroundColor Yellow
$resp = Send-TcpCommand -Session $SESSION -Command "set-option -g choose-tree-preview on"
# set-option is silent on success (no response or empty); failure would surface as ERR
if ($resp -notmatch "ERR") { Write-Pass "TCP set-option succeeded (no ERR; resp='$resp')" }
else { Write-Fail "TCP set-option response: '$resp'" }

$resp = Send-TcpCommand -Session $SESSION -Command "show-options -g -v choose-tree-preview"
if ($resp -match "(?m)^on") { Write-Pass "TCP show-options returns 'on'" }
else { Write-Fail "TCP show-options got: '$resp'" }

$resp = Send-TcpCommand -Session $SESSION -Command "set-option -g choose-tree-preview off"
$resp = Send-TcpCommand -Session $SESSION -Command "show-options -g -v choose-tree-preview"
if ($resp -match "(?m)^off") { Write-Pass "TCP set off + show shows 'off'" }
else { Write-Fail "TCP show after off got: '$resp'" }

# ----------------------------------------------------------------------------
# TEST 7: dump-state JSON contains choose_tree_preview field (snake_case)
# ----------------------------------------------------------------------------
Write-Host "`n[Test 7] JSON snapshot delivery to client" -ForegroundColor Yellow
& $PSMUX set -g choose-tree-preview on 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$dump = Get-DumpState -Session $SESSION
if ($dump -and $dump -match '"choose_tree_preview"\s*:\s*true') {
    Write-Pass "dump-state JSON contains choose_tree_preview=true"
} else {
    Write-Fail "dump-state missing or wrong; snippet: $($dump -replace '.*(choose_tree_preview[^,}]*).*', '$1')"
}

& $PSMUX set -g choose-tree-preview off 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$dump = Get-DumpState -Session $SESSION
if ($dump -and $dump -match '"choose_tree_preview"\s*:\s*false') {
    Write-Pass "dump-state JSON contains choose_tree_preview=false"
} else {
    Write-Fail "dump-state should have false; not found"
}

# ----------------------------------------------------------------------------
# TEST 8: Config file source-file applies the option
# ----------------------------------------------------------------------------
Write-Host "`n[Test 8] source-file from psmux.conf" -ForegroundColor Yellow
$conf = "$env:TEMP\ctp_test_$([Guid]::NewGuid().ToString('N')).conf"
"set -g choose-tree-preview on`n" | Set-Content -Path $conf -Encoding UTF8 -NoNewline
& $PSMUX set -g choose-tree-preview off 2>&1 | Out-Null
$pre = Get-OptionValue "choose-tree-preview"
& $PSMUX source-file -t $SESSION $conf 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$post = Get-OptionValue "choose-tree-preview"
if ($pre -eq "off" -and $post -eq "on") {
    Write-Pass "source-file flips 'off' -> 'on'"
} else {
    Write-Fail "source-file failed: pre='$pre' post='$post'"
}
Remove-Item $conf -Force -EA SilentlyContinue

# ----------------------------------------------------------------------------
# TEST 9: Persists across new sessions on same warm server
# ----------------------------------------------------------------------------
Write-Host "`n[Test 9] Option independently set on a separate session/server" -ForegroundColor Yellow
# Each psmux session has its own server, so 'set -g' is per-server.
# Verify a fresh session starts with default 'off' and can be flipped independently.
& $PSMUX new-session -d -s "ctp_cfg" 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX has-session -t "ctp_cfg" 2>$null
if ($LASTEXITCODE -eq 0) {
    $v = Get-OptionValue "choose-tree-preview" "ctp_cfg"
    if ($v -eq "off") { Write-Pass "Fresh session starts with default 'off'" }
    else { Write-Fail "Fresh session expected 'off', got '$v'" }
    & $PSMUX set -g choose-tree-preview on -t "ctp_cfg" 2>&1 | Out-Null
    $v = Get-OptionValue "choose-tree-preview" "ctp_cfg"
    if ($v -eq "on") { Write-Pass "Independent set on second session works" }
    else { Write-Fail "Second session set on failed, got '$v'" }
    & $PSMUX kill-session -t "ctp_cfg" 2>&1 | Out-Null
} else {
    Write-Fail "Could not create second session"
}

# Reset before TUI tests
& $PSMUX set -g choose-tree-preview off 2>&1 | Out-Null

# ============================================================================
# WIN32 TUI VISUAL VERIFICATION
# ============================================================================
Write-Host "`n=============================================================" -ForegroundColor Cyan
Write-Host "Win32 TUI VERIFICATION" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan

# Compile injector if missing
$injectorExe = "$env:TEMP\psmux_injector.exe"
$injectorSrc = Join-Path (Split-Path $PSScriptRoot -Parent) "tests\injector.cs"
if (-not (Test-Path $injectorExe) -or ((Get-Item $injectorSrc).LastWriteTime -gt (Get-Item $injectorExe).LastWriteTime)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (Test-Path $csc) {
        & $csc /nologo /optimize /out:$injectorExe $injectorSrc 2>&1 | Out-Null
    }
}
$haveInjector = Test-Path $injectorExe
if (-not $haveInjector) {
    Write-Info "Injector unavailable - skipping keystroke TUI scenarios"
}

# ----------------------------------------------------------------------------
# TUI TEST A: Launch attached session with option ON, verify chooser opens
# ----------------------------------------------------------------------------
Write-Host "`n[TUI A] Attached session with choose-tree-preview=on" -ForegroundColor Yellow

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","ctp_tui_on" -PassThru
Start-Sleep -Seconds 4
& $PSMUX has-session -t "ctp_tui_on" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "TUI: attached session 'ctp_tui_on' is alive"
    
    # Set the option on this session's own server
    & $PSMUX set -g choose-tree-preview on -t "ctp_tui_on" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    
    # Verify the session's view of the option (server-side)
    $v = Get-OptionValue "choose-tree-preview" "ctp_tui_on"
    if ($v -eq "on") { Write-Pass "TUI: server reports option 'on' for attached session" }
    else { Write-Fail "TUI: server option is '$v'" }
    
    # Verify dump-state for the attached session shows on
    Start-Sleep -Milliseconds 300
    $dump = Get-DumpState -Session "ctp_tui_on"
    if ($dump -and $dump -match '"choose_tree_preview"\s*:\s*true') {
        Write-Pass "TUI: attached session dump-state has choose_tree_preview=true"
    } else {
        Write-Fail "TUI: dump-state for attached session does not show true"
    }

    if ($haveInjector) {
        # Open chooser via prefix+s, verify the session does not crash and stays responsive
        & $injectorExe $proc.Id "^b{SLEEP:300}s" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        & $PSMUX has-session -t "ctp_tui_on" 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: chooser open with preview-on did not crash session" }
        else { Write-Fail "TUI: session died after opening chooser with preview on" }
        
        # Close the chooser
        & $injectorExe $proc.Id "{ESC}" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        
        # Verify session still responsive after closing chooser
        $name = (& $PSMUX display-message -t "ctp_tui_on" -p '#{session_name}' 2>&1).Trim()
        if ($name -eq "ctp_tui_on") { Write-Pass "TUI: session responsive after chooser close (name='$name')" }
        else { Write-Fail "TUI: session not responsive, got '$name'" }
        
        # Open prefix+w (choose-tree)
        & $injectorExe $proc.Id "^b{SLEEP:300}w" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        & $PSMUX has-session -t "ctp_tui_on" 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: prefix+w (choose-tree) with preview-on did not crash" }
        else { Write-Fail "TUI: choose-tree crashed session" }
        & $injectorExe $proc.Id "{ESC}" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
    
    & $PSMUX kill-session -t "ctp_tui_on" 2>&1 | Out-Null
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    Start-Sleep -Seconds 1
} else {
    Write-Fail "TUI: could not start attached session 'ctp_tui_on'"
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}

# ----------------------------------------------------------------------------
# TUI TEST B: Same with option OFF (control case)
# ----------------------------------------------------------------------------
Write-Host "`n[TUI B] Attached session with choose-tree-preview=off (control)" -ForegroundColor Yellow

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","ctp_tui_off" -PassThru
Start-Sleep -Seconds 4
& $PSMUX has-session -t "ctp_tui_off" 2>$null
if ($LASTEXITCODE -eq 0) {
    # Fresh session starts with default off; explicitly set off to be deterministic
    & $PSMUX set -g choose-tree-preview off -t "ctp_tui_off" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $v = Get-OptionValue "choose-tree-preview" "ctp_tui_off"
    if ($v -eq "off") { Write-Pass "TUI: control session sees option 'off'" }
    else { Write-Fail "TUI: control session got '$v'" }
    
    $dump = Get-DumpState -Session "ctp_tui_off"
    if ($dump -and $dump -match '"choose_tree_preview"\s*:\s*false') {
        Write-Pass "TUI: control session dump-state has choose_tree_preview=false"
    } else {
        $snippet = if ($dump) { ($dump -replace '.*?("choose_tree_preview"[^,}]*).*', '$1').Substring(0, [Math]::Min(80, $dump.Length)) } else { '<null>' }
        Write-Fail "TUI: control dump-state should have false; snippet: $snippet"
    }
    
    if ($haveInjector) {
        & $injectorExe $proc.Id "^b{SLEEP:300}s" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        & $PSMUX has-session -t "ctp_tui_off" 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: chooser open with preview-off works (control)" }
        else { Write-Fail "TUI: control session crashed" }
        & $injectorExe $proc.Id "{ESC}" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
    
    & $PSMUX kill-session -t "ctp_tui_off" 2>&1 | Out-Null
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
} else {
    Write-Fail "TUI: could not start control session"
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}

# ============================================================================
# TEARDOWN
# ============================================================================
& $PSMUX set-option -g -u choose-tree-preview 2>&1 | Out-Null
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
