#requires -Version 5
# Issue #305: Set-PSReadLineKeyHandler not working inside psmux
#
# Strategy (Layer 1 - CLI path):
#   1. Create a detached psmux session.
#   2. Inside the pane run Set-PSReadLineKeyHandler binding Ctrl+J to a
#      ScriptBlock that writes a known marker string.
#   3. Use psmux send-keys to deliver C-j to the pane (the send-keys path
#      passes the VT escape directly to the pty).
#   4. capture-pane and assert the marker appears.
#
# Strategy (Layer 2 - TUI/injector path):
#   Attach psmux in a real console window, inject Ctrl+J via WriteConsoleInput,
#   capture-pane and assert marker.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue305_psreadline_key_handler.ps1

$ErrorActionPreference = 'Continue'
$script:Pass = 0
$script:Fail = 0

function P($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function F($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:Fail++ }
function I($m) { Write-Host "  [INFO] $m" -ForegroundColor Cyan }

$PSMUX      = (Get-Command psmux -ErrorAction Stop).Source
$SESSION    = 'gap305'
$psmuxDir   = "$env:USERPROFILE\.psmux"
$injector   = "$env:TEMP\psmux_injector.exe"
$MARKER     = 'PSReadLineHandlerFired305'

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -ErrorAction SilentlyContinue
}

function Wait-Session($name, $timeout = 12) {
    $deadline = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $deadline) {
        & $PSMUX has-session -t $name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Capture($target) {
    & $PSMUX capture-pane -t $target -p 2>&1 | Out-String
}

# Build injector if needed
if (-not (Test-Path $injector)) {
    I "Compiling injector..."
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injector "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
    if (-not (Test-Path $injector)) { F "injector compile failed"; exit 1 }
}
I "Injector: $injector"
I "psmux: $PSMUX"

Write-Host ""
Write-Host ("=" * 65) -ForegroundColor Cyan
Write-Host "  Issue #305: Set-PSReadLineKeyHandler fires inside psmux" -ForegroundColor Cyan
Write-Host ("=" * 65) -ForegroundColor Cyan

# -----------------------------------------------------------------------
# Layer 1: CLI send-keys path
# -----------------------------------------------------------------------
Write-Host "`n--- Layer 1: send-keys C-j fires PSReadLine key handler ---" -ForegroundColor Yellow

Cleanup
& $PSMUX new-session -d -s $SESSION -x 140 -y 35 2>&1 | Out-Null
if (-not (Wait-Session $SESSION)) { F "Layer1: session did not start"; exit 1 }
Start-Sleep -Seconds 1

# Register the custom key handler: Ctrl+J inserts the marker
$bindCmd = "Set-PSReadLineKeyHandler -Key Ctrl+j -ScriptBlock { [Microsoft.PowerShell.PSConsoleReadLine]::Insert('$MARKER') }"
& $PSMUX send-keys -t $SESSION $bindCmd Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 1200

# Deliver Ctrl+J via send-keys (VT sequence path)
& $PSMUX send-keys -t $SESSION C-j 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$cap = Capture $SESSION
I "Pane content (last 6 lines):"
($cap -split "`n" | Select-Object -Last 6) | ForEach-Object { I "  |$_|" }

if ($cap -match [regex]::Escape($MARKER)) {
    P "Layer1: Ctrl+J handler fired - marker '$MARKER' found in pane"
} else {
    F "Layer1: marker '$MARKER' NOT found - send-keys Ctrl+J did not trigger PSReadLine handler"
}

Cleanup

# -----------------------------------------------------------------------
# Layer 2: TUI / WriteConsoleInput injection path
# -----------------------------------------------------------------------
Write-Host "`n--- Layer 2: injected Ctrl+J fires PSReadLine key handler ---" -ForegroundColor Yellow

Cleanup

$proc = Start-Process -FilePath $PSMUX `
    -ArgumentList "new-session","-s",$SESSION,"-x","140","-y","35" `
    -PassThru
Start-Sleep -Seconds 4

if ($proc.HasExited) { F "Layer2: psmux exited before injection"; Cleanup }
else {
    P "Layer2: attached psmux PID=$($proc.Id) alive"

    # Register the handler via send-keys (CLI path into the running session)
    # then inject Ctrl+J via WriteConsoleInput to test the real TUI key path.
    $bindStr = "Set-PSReadLineKeyHandler -Key Ctrl+j -ScriptBlock { [Microsoft.PowerShell.PSConsoleReadLine]::Insert('$MARKER') }"
    & $PSMUX send-keys -t $SESSION $bindStr Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1800

    # Inject Ctrl+J via WriteConsoleInput into the attached psmux console
    & $injector $proc.Id '^j' 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800

    $cap2 = Capture $SESSION
    I "Pane content after injection (last 6 lines):"
    ($cap2 -split "`n" | Select-Object -Last 6) | ForEach-Object { I "  |$_|" }

    if ($cap2 -match [regex]::Escape($MARKER)) {
        P "Layer2: injected Ctrl+J handler fired - marker found in pane"
    } else {
        F "Layer2: marker NOT found after WriteConsoleInput Ctrl+J injection"
    }

    if (-not $proc.HasExited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
    Cleanup
}

# -----------------------------------------------------------------------
# Layer 3: Verify the handler is NOT broken just because psmux intercepts
#          Ctrl+B (the default prefix) — a plain bound key must still reach PSReadLine
# -----------------------------------------------------------------------
Write-Host "`n--- Layer 3: non-prefix key handler (Ctrl+G) also fires ---" -ForegroundColor Yellow

Cleanup
& $PSMUX new-session -d -s $SESSION -x 140 -y 35 2>&1 | Out-Null
if (-not (Wait-Session $SESSION)) { F "Layer3: session did not start" }
else {
    Start-Sleep -Seconds 1
    $marker3 = 'CtrlGHandlerFired305'
    $bind3 = "Set-PSReadLineKeyHandler -Key Ctrl+g -ScriptBlock { [Microsoft.PowerShell.PSConsoleReadLine]::Insert('$marker3') }"
    & $PSMUX send-keys -t $SESSION $bind3 Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1200
    & $PSMUX send-keys -t $SESSION C-g 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $cap3 = Capture $SESSION
    if ($cap3 -match [regex]::Escape($marker3)) {
        P "Layer3: non-prefix Ctrl+G handler fired correctly"
    } else {
        F "Layer3: Ctrl+G handler did not fire - key may have been swallowed"
    }
    Cleanup
}

Write-Host ""
Write-Host ("=" * 65) -ForegroundColor Cyan
$total = $script:Pass + $script:Fail
Write-Host "  RESULTS: $($script:Pass) passed, $($script:Fail) failed (of $total)" `
    -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ("=" * 65) -ForegroundColor Cyan

exit $script:Fail
