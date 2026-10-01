# Issue #416: inline `# comment` on a config line was passed verbatim to the
# option parser, so the directive silently had no effect.
# This E2E test proves that after the fix, a directive with a trailing inline
# comment takes effect, that whole-line and no-comment cases still work, and
# that quoted `#` (formats like "#{...}") survive comment stripping.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Get-Option { param($Opt,$Name) (& $PSMUX show-options -g -v $Opt -t $Name 2>&1 | Out-String).Trim() }

function Start-WithConfig {
    param([string]$Name, [string]$ConfContent)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
    $conf = "$env:TEMP\test416_$Name.conf"
    Set-Content -Path $conf -Value $ConfContent -Encoding UTF8
    $env:PSMUX_CONFIG_FILE = $conf
    & $PSMUX new-session -d -s $Name 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $env:PSMUX_CONFIG_FILE = $null
    & $PSMUX has-session -t $Name 2>$null
    return ($LASTEXITCODE -eq 0)
}

Write-Host "`n=== Issue #416 E2E: inline config comments ===" -ForegroundColor Cyan

# Test 1: the exact reported case
Write-Host "`n[Test 1] 'set -g base-index 1   # test' takes effect" -ForegroundColor Yellow
if (Start-WithConfig "t416_inline" "set -g base-index 1   # test") {
    $bi = Get-Option "base-index" "t416_inline"
    if ($bi -eq "1") { Write-Pass "base-index=1 with trailing inline comment" }
    else { Write-Fail "base-index expected 1, got '$bi'" }
    & $PSMUX kill-session -t "t416_inline" 2>&1 | Out-Null
} else { Write-Fail "session failed to start" }

# Test 2: whole-line comment control (was already working)
Write-Host "`n[Test 2] whole-line comment still works" -ForegroundColor Yellow
if (Start-WithConfig "t416_whole" "# comment`nset -g base-index 1") {
    $bi = Get-Option "base-index" "t416_whole"
    if ($bi -eq "1") { Write-Pass "base-index=1 with whole-line comment" }
    else { Write-Fail "base-index expected 1, got '$bi'" }
    & $PSMUX kill-session -t "t416_whole" 2>&1 | Out-Null
} else { Write-Fail "session failed to start" }

# Test 3: single space before comment
Write-Host "`n[Test 3] single-space inline comment" -ForegroundColor Yellow
if (Start-WithConfig "t416_space" "set -g base-index 1 #x") {
    $bi = Get-Option "base-index" "t416_space"
    if ($bi -eq "1") { Write-Pass "base-index=1 with 'value #x'" }
    else { Write-Fail "base-index expected 1, got '$bi'" }
    & $PSMUX kill-session -t "t416_space" 2>&1 | Out-Null
} else { Write-Fail "session failed to start" }

# Test 4: quoted # in a format string must survive
Write-Host "`n[Test 4] quoted #{...} format is not truncated" -ForegroundColor Yellow
if (Start-WithConfig "t416_fmt" 'set -g status-left "#{session_name}"  # show session') {
    $sl = Get-Option "status-left" "t416_fmt"
    if ($sl -eq "#{session_name}") { Write-Pass "status-left preserved '#{session_name}'" }
    else { Write-Fail "status-left expected '#{session_name}', got '$sl'" }
    & $PSMUX kill-session -t "t416_fmt" 2>&1 | Out-Null
} else { Write-Fail "session failed to start" }

# Test 5: source-file path also strips inline comments
Write-Host "`n[Test 5] source-file honors inline comments" -ForegroundColor Yellow
if (Start-WithConfig "t416_src" "set -g base-index 0") {
    $reload = "$env:TEMP\test416_reload.conf"
    Set-Content -Path $reload -Value "set -g base-index 1   # via source-file" -Encoding UTF8
    & $PSMUX source-file -t "t416_src" $reload 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $bi = Get-Option "base-index" "t416_src"
    if ($bi -eq "1") { Write-Pass "source-file applied 'base-index 1  # comment'" }
    else { Write-Fail "base-index expected 1 after source-file, got '$bi'" }
    & $PSMUX kill-session -t "t416_src" 2>&1 | Out-Null
} else { Write-Fail "session failed to start" }

Remove-Item "$env:TEMP\test416_*" -Force -EA SilentlyContinue

# === Win32 TUI visual verification ===
Write-Host "`n$('=' * 50)" -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ('=' * 50) -ForegroundColor Cyan
$ST = "t416_tui"
& $PSMUX kill-session -t $ST 2>&1 | Out-Null
Remove-Item "$psmuxDir\$ST.*" -Force -EA SilentlyContinue
$tuiConf = "$env:TEMP\test416_tui.conf"
Set-Content -Path $tuiConf -Value "set -g base-index 1   # inline comment in TUI config" -Encoding UTF8
$env:PSMUX_CONFIG_FILE = $tuiConf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$ST -PassThru
Start-Sleep -Seconds 4
$env:PSMUX_CONFIG_FILE = $null
$bi = Get-Option "base-index" $ST
if ($bi -eq "1") { Write-Pass "TUI: base-index=1 from inline-comment config" }
else { Write-Fail "TUI: base-index expected 1, got '$bi'" }
# prove the visible window is functional
& $PSMUX split-window -v -t $ST 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$panes = (& $PSMUX display-message -t $ST -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes (window functional)" }
else { Write-Fail "TUI: expected 2 panes, got '$panes'" }
& $PSMUX kill-session -t $ST 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$env:TEMP\test416_tui.conf" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
