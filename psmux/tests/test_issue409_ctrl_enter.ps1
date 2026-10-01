# Issue #409: In Windows Terminal, Ctrl+Enter is forwarded to the pane child as
# CR (0x0D) instead of LF (0x0A). Native WT delivers Ctrl+Enter as LF to raw/VT
# stdin readers (Node/libuv apps like pi, Claude Code); psmux delivers CR, so
# those apps treat Ctrl+Enter like a plain Enter (submit) instead of newline.
#
# Reproduction strategy (faithful to WT):
#   - WT feeds psmux input as native console INPUT_RECORDs (win32 input), NOT VT.
#   - So we inject a real VK_RETURN KEY_EVENT (with/without LEFT_CTRL) into the
#     attached psmux client's console input buffer via WriteConsoleInput.
#   - The pane runs a Node raw-stdin receiver (same reader style as pi) that logs
#     each received byte as hex. We then read exactly what psmux forwarded.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue409"
$psmuxDir = "$env:USERPROFILE\.psmux"
$recv = "$env:TEMP\psmux_409_recv.log"
$recvJs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "ctrl_enter_recv.js"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

# --- Compile injector ---
$injector = "$env:TEMP\psmux_injector.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$injSrc = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "injector.cs"
& $csc /nologo /optimize /out:$injector $injSrc 2>&1 | Out-Null
if (-not (Test-Path $injector)) { Write-Fail "injector compile failed"; exit 1 }

# --- Cleanup ---
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Remove-Item $recv -Force -EA SilentlyContinue

Write-Host "`n=== Issue #409: Ctrl+Enter byte forwarding ===" -ForegroundColor Cyan

# --- Launch attached psmux (real console window) ---
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session did not start"; exit 1 }
Write-Info "psmux client PID = $($proc.Id)"

# --- Start the Node raw-stdin receiver in the pane ---
$recvEsc = $recv.Replace('\','\\')
& $PSMUX send-keys -t $SESSION "node `"$recvJs`" `"$recv`"" Enter 2>&1 | Out-Null

# Wait for receiver READY
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $recv) -and ((Get-Content $recv -Raw) -match "READY")) { $ready = $true; break }
}
if (-not $ready) { Write-Fail "Node receiver never became READY"; & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null; exit 1 }
Write-Pass "Node raw-stdin receiver is running in the pane"

function Get-NewBytes {
    param([int]$BeforeCount)
    $lines = @(Get-Content $recv | Where-Object { $_ -like "BYTES:*" })
    if ($lines.Count -le $BeforeCount) { return @() }
    return @($lines[$BeforeCount..($lines.Count-1)])
}

function Inject-And-Read {
    param([string]$Keys, [string]$Label)
    $before = @(Get-Content $recv | Where-Object { $_ -like "BYTES:*" }).Count
    & $injector $proc.Id $Keys 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $new = Get-NewBytes -BeforeCount $before
    Write-Info ("{0}: injector-log-tail => {1}" -f $Label, ((Get-Content "$env:TEMP\psmux_inject.log" -Raw) -replace "`r?`n"," | "))
    if ($new.Count -eq 0) { Write-Info "$Label -> (no bytes received)"; return "" }
    $hex = ($new -join " ; ")
    Write-Info "$Label -> $hex"
    return ($new -join " ")
}

# --- Baseline: plain Enter should be CR (0x0D) ---
Write-Host "`n[Test 1] Plain Enter baseline" -ForegroundColor Yellow
$b1 = Inject-And-Read -Keys "{ENTER}" -Label "Enter"
if ($b1 -match "0d") { Write-Pass "Plain Enter forwarded as 0x0D (CR) as expected" }
else { Write-Fail "Plain Enter expected 0x0D, got: $b1" }

# --- Core claim: Ctrl+Enter. Native WT => LF(0x0A). psmux (buggy) => CR(0x0D). ---
Write-Host "`n[Test 2] Ctrl+Enter (VK_RETURN + LEFT_CTRL)" -ForegroundColor Yellow
$b2 = Inject-And-Read -Keys "{RAW:0D:0D:0008}" -Label "Ctrl+Enter"
if ($b2 -match "0a") {
    Write-Pass "Ctrl+Enter forwarded as 0x0A (LF) — matches native WT (correct)"
} elseif ($b2 -match "0d") {
    Write-Fail "BUG REPRODUCED: Ctrl+Enter forwarded as 0x0D (CR); native WT sends 0x0A (LF)"
} else {
    Write-Fail "Ctrl+Enter unexpected bytes: $b2"
}

# --- Contrast: repeat Ctrl+Enter to show determinism ---
Write-Host "`n[Test 3] Ctrl+Enter again (determinism)" -ForegroundColor Yellow
$b3 = Inject-And-Read -Keys "{RAW:0D:0D:0008}" -Label "Ctrl+Enter #2"
if ($b3 -match "0a") { Write-Pass "Ctrl+Enter #2 = 0x0A (LF)" }
elseif ($b3 -match "0d") { Write-Fail "Ctrl+Enter #2 = 0x0D (CR) — bug still present" }
else { Write-Info "Ctrl+Enter #2 bytes: $b3" }

# --- Teardown ---
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "`n  Full receiver log:" -ForegroundColor DarkGray
Get-Content $recv | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
exit $script:TestsFailed
