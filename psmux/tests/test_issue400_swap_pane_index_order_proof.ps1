# Issue #400 - Layer 3 proof: the `{` / `}` prefix keybindings (input.rs dispatch)
# drive swap-pane -U / -D by pane INDEX order. Real keystrokes via WriteConsoleInput.
# This exercises the TUI input-handling path that the CLI/TCP tests cannot reach.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function IdAt($Session, $idx) {
    foreach ($l in (& $PSMUX list-panes -t $Session -F '#{pane_index}=#{pane_id}' 2>&1)) {
        if ($l -match "^$idx=(.+)$") { return $Matches[1] }
    }
    return ""
}
function ActiveIdx($Session) {
    foreach ($l in (& $PSMUX list-panes -t $Session -F '#{pane_index}:#{pane_active}' 2>&1)) {
        if ($l -match '^(\d+):1$') { return [int]$Matches[1] }
    }
    return -1
}

# Compile injector once
$injectorExe = "$env:TEMP\psmux_injector.exe"
$repo = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
$injectorSrc = Join-Path $repo "tests\injector.cs"
if (-not (Test-Path $injectorExe) -or ((Get-Item $injectorSrc).LastWriteTime -gt (Get-Item $injectorExe -EA SilentlyContinue).LastWriteTime)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
    & $csc /nologo /optimize /out:$injectorExe $injectorSrc 2>&1 | Out-Null
}
if (-not (Test-Path $injectorExe)) { Write-Fail "injector failed to compile"; exit 1 }

Write-Host "`n=== Issue #400 Layer 3: prefix { / } keybinding proof ===" -ForegroundColor Cyan

$S = "test_issue400_keys"
& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$S -PassThru
Start-Sleep -Seconds 4
& $PSMUX split-window -h -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX split-window -h -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX split-window -h -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 400

# --- Scenario 1: prefix + '{'  => swap-pane -U (prev by index) ---
Write-Host "`n[Key 1] pane 1 active, prefix + '{' (swap-pane -U)" -ForegroundColor Yellow
& $PSMUX select-pane -t "${S}.1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
$id0 = IdAt $S 0; $id1 = IdAt $S 1
# ^b = Ctrl+B (prefix), {U:007B} = literal '{' delivered as KeyCode::Char('{')
& $injectorExe $proc.Id "^b{SLEEP:400}{U:007B}"
Start-Sleep -Seconds 1
if ((IdAt $S 0) -eq $id1 -and (IdAt $S 1) -eq $id0) { Write-Pass "prefix+{ swapped idx0<->idx1 by index" }
else { Write-Fail "prefix+{ did not swap: idx0=$(IdAt $S 0) idx1=$(IdAt $S 1) (wanted idx0=$id1 idx1=$id0)" }
if ((ActiveIdx $S) -eq 0) { Write-Pass "prefix+{ focus followed to idx0" }
else { Write-Fail "prefix+{ focus expected idx0, got idx$(ActiveIdx $S)" }

# --- Scenario 2: prefix + '}'  => swap-pane -D (next by index) ---
Write-Host "`n[Key 2] active idx0, prefix + '}' (swap-pane -D)" -ForegroundColor Yellow
$id0 = IdAt $S 0; $id1 = IdAt $S 1
# active is currently idx0; }=next swaps idx0<->idx1 back
& $injectorExe $proc.Id "^b{SLEEP:400}{U:007D}"
Start-Sleep -Seconds 1
if ((IdAt $S 0) -eq $id1 -and (IdAt $S 1) -eq $id0) { Write-Pass "prefix+} swapped idx0<->idx1 (next by index)" }
else { Write-Fail "prefix+} did not swap: idx0=$(IdAt $S 0) idx1=$(IdAt $S 1) (wanted idx0=$id1 idx1=$id0)" }
if ((ActiveIdx $S) -eq 1) { Write-Pass "prefix+} focus followed to idx1" }
else { Write-Fail "prefix+} focus expected idx1, got idx$(ActiveIdx $S)" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
