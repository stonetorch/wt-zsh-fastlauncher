$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

$bin = "$env:TEMP\psmux253_bin"
$marker = "$env:TEMP\psmux253_marker.txt"
$exePath = "$bin\tech-pass.exe"
$env:PATH = "$bin;$env:PATH"

function Test-Cmd {
    param([string]$Name, [string]$RawArgs)
    $SESSION = "i253_$Name"
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item $marker -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 800
    Write-Host ("`n=== {0} ===" -f $Name) -ForegroundColor Cyan
    $full = "`"$PSMUX`" $RawArgs"
    Write-Host "RAW: $full" -ForegroundColor DarkGray
    cmd /c $full 2>&1 | Out-Host
    Start-Sleep -Seconds 5

    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    Write-Host "PANE:" -ForegroundColor Yellow
    Write-Host $cap.TrimEnd()
    $markerExists = Test-Path $marker
    $paneCmd = (& $PSMUX display-message -t $SESSION -p '#{pane_current_command}' 2>&1) -join ''
    $startCmd = (& $PSMUX display-message -t $SESSION -p '#{pane_start_command}' 2>&1) -join ''
    Write-Host ("marker={0} paneCmd={1} startCmd={2}" -f $markerExists,$paneCmd,$startCmd)
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    return @{ Marker=$markerExists; PaneCmd=$paneCmd; StartCmd=$startCmd }
}

# EXACT user forms (from cmd.exe shell; -d added so we don't hang)
$r1 = Test-Cmd "form1" "new -s i253_form1 -d -- cmd pwsh -Command `"tech-pass.exe`""
$r2 = Test-Cmd "form2" "new -s i253_form2 -d -- cmd pwsh -Command `"$bin\tech-pass.exe`""
$r3 = Test-Cmd "form3" "new -s i253_form3 -d -- cmd `"$bin\tech-pass.exe`""
# Sane forms
$r4 = Test-Cmd "direct" "new -s i253_direct -d -- `"$bin\tech-pass.exe`""
$r5 = Test-Cmd "cmdc"   "new -s i253_cmdc -d -- cmd /c `"$bin\tech-pass.exe`""

Write-Host "`n=== SUMMARY ===" -ForegroundColor Magenta
"form1:  marker=$($r1.Marker) paneCmd=$($r1.PaneCmd)" | Write-Host
"form2:  marker=$($r2.Marker) paneCmd=$($r2.PaneCmd)" | Write-Host
"form3:  marker=$($r3.Marker) paneCmd=$($r3.PaneCmd)" | Write-Host
"direct: marker=$($r4.Marker) paneCmd=$($r4.PaneCmd)" | Write-Host
"cmdc:   marker=$($r5.Marker) paneCmd=$($r5.PaneCmd)" | Write-Host
