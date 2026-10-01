# Discussion #328: how to chain psmux commands in Windows cmd.exe.
# Tries each separator variant via cmd.exe /c and checks whether the chain
# produced a session with TWO windows (new-session + new-window).
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$S = "disc328"

function Reset { & $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 500; Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue }
function WinCount {
    Start-Sleep -Milliseconds 800
    & $PSMUX has-session -t $S 2>$null
    if ($LASTEXITCODE -ne 0) { return -1 }
    $w = (& $PSMUX list-windows -t $S 2>&1)
    return ($w | Measure-Object -Line).Lines
}
function WinNames { (& $PSMUX list-windows -t $S -F '#{window_name}' 2>&1) -join "," }

# Each variant is the raw cmd.exe command line. %PSMUX% expanded inline.
$variants = @(
    @{ name='bare semicolon  ;';   cmd = "`"$PSMUX`" new-session -d -s $S cmd.exe ; new-window -n win2 cmd.exe" }
    @{ name='backslash  \;';        cmd = "`"$PSMUX`" new-session -d -s $S cmd.exe \; new-window -n win2 cmd.exe" }
    @{ name='caret  ^;';            cmd = "`"$PSMUX`" new-session -d -s $S cmd.exe ^; new-window -n win2 cmd.exe" }
    @{ name='quoted  `";`"';        cmd = "`"$PSMUX`" new-session -d -s $S cmd.exe `";`" new-window -n win2 cmd.exe" }
)

Write-Host "=== cmd.exe chaining variants (expect 2 windows: default + win2) ===" -ForegroundColor Cyan
foreach ($v in $variants) {
    Reset
    Write-Host "`n[$($v.name)]" -ForegroundColor Yellow
    Write-Host "  cmd: $($v.cmd)"
    cmd.exe /c $v.cmd 2>&1 | ForEach-Object { Write-Host "    out> $_" -ForegroundColor DarkGray }
    $c = WinCount
    if ($c -eq 2) { Write-Host "  RESULT: 2 windows ($(WinNames)) -> CHAIN WORKS" -ForegroundColor Green }
    elseif ($c -eq 1) { Write-Host "  RESULT: 1 window ($(WinNames)) -> chain NOT applied (separator consumed/ignored)" -ForegroundColor Red }
    elseif ($c -eq -1) { Write-Host "  RESULT: no session created -> parse error" -ForegroundColor Red }
    else { Write-Host "  RESULT: $c windows ($(WinNames))" -ForegroundColor Red }
}

# Also test the in-app separator that psmux uses internally (command-prompt / config): \;
Write-Host "`n=== Control: does psmux support \; chaining at all (via command-prompt path)? ===" -ForegroundColor Cyan
Reset
& $PSMUX new-session -d -s $S cmd.exe 2>&1 | Out-Null
Start-Sleep -Seconds 2
# chain via a single CLI invocation using the separator as its own arg
& $PSMUX new-window -t $S -n a `; new-window -t $S -n b 2>&1 | Out-Null
$c2 = WinCount
Write-Host "after 'new-window -n a \; new-window -n b' from one invocation: $c2 windows ($(WinNames))"

Reset
Write-Host "`n=== done ===" -ForegroundColor Cyan
