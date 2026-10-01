# More-granular debug: verify the existing pane's parser actually
# picked up alternate-screen=off.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

function Wait-Prompt {
    param([string]$Target, [int]$TimeoutMs = 15000, [string]$Pattern = "PS [A-Z]:\\")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Wait-Output {
    param([string]$Target, [string]$Marker, [int]$TimeoutMs = 30000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match $Marker) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Seconds 1
Remove-Item "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.sess" -Force -EA SilentlyContinue

$SESSION = "iss88_dbg2"
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 4
[void](Wait-Prompt -Target $SESSION)

Write-Host "=== Before set-option ===" -ForegroundColor Cyan
Write-Host "alternate-screen option = $((& $PSMUX show-options -g -v alternate-screen 2>&1).Trim())"
Write-Host "#{alternate_on} = $((& $PSMUX display-message -t $SESSION -p '#{alternate_on}' 2>&1).Trim())"

# Toggle off and verify
& $PSMUX set-option -g alternate-screen off 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "`n=== After set-option off ===" -ForegroundColor Cyan
Write-Host "alternate-screen option = $((& $PSMUX show-options -g -v alternate-screen 2>&1).Trim())"

# Now do the EXACT same sequence as before
Write-Host "`n=== Sending 1049h directly ===" -ForegroundColor Cyan
& $PSMUX send-keys -t $SESSION '[Console]::Out.Write([char]27 + "[?1049h")' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2  # extra time for any buffering
$altOn = (& $PSMUX display-message -t $SESSION -p '#{alternate_on}' 2>&1).Trim()
Write-Host "After 1049h, #{alternate_on} = $altOn"
Write-Host "(0 means flag worked, 1 means it didn't)"

# Capture state right after 1049h, before any output
$capImm = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
Write-Host "`n=== Pane content RIGHT AFTER 1049h (visible only) ==="
$tail = if ($capImm.Length -gt 800) { $capImm.Substring($capImm.Length - 800) } else { $capImm }
Write-Host "$tail"

# Now write 5 lines and see where they land
& $PSMUX send-keys -t $SESSION '1..5 | ForEach-Object { "X $_" }' Enter 2>&1 | Out-Null
[void](Wait-Output -Target $SESSION -Marker "X 5" -TimeoutMs 5000)
Start-Sleep -Seconds 1

# Check both visible-only AND deep scrollback
$capV = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
$capD = & $PSMUX capture-pane -t $SESSION -S -2000 -p 2>&1 | Out-String
$visX = ([regex]::Matches($capV, '(?m)^X (\d+)\b')).Count
$deepX = ([regex]::Matches($capD, '(?m)^X (\d+)\b')).Count
Write-Host "`n=== After writing X 1..5 ==="
Write-Host "X count VISIBLE = $visX"
Write-Host "X count DEEP    = $deepX"

# Now exit alt
& $PSMUX send-keys -t $SESSION '[Console]::Out.Write([char]27 + "[?1049l")' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1

$capV2 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
$capD2 = & $PSMUX capture-pane -t $SESSION -S -2000 -p 2>&1 | Out-String
$visX2 = ([regex]::Matches($capV2, '(?m)^X (\d+)\b')).Count
$deepX2 = ([regex]::Matches($capD2, '(?m)^X (\d+)\b')).Count
Write-Host "`n=== After 1049l ==="
Write-Host "X count VISIBLE = $visX2"
Write-Host "X count DEEP    = $deepX2"

if ($altOn -eq "0" -and $deepX2 -ge 4) {
    Write-Host "`nFIX WORKS: 1049h dropped, X lines persist in scrollback after 1049l" -ForegroundColor Green
} elseif ($altOn -eq "0" -and $deepX2 -eq 0) {
    Write-Host "`nFIX BROKEN: 1049h dropped (good) but X lines vanished after 1049l (bad)" -ForegroundColor Red
} else {
    Write-Host "`nUNCLEAR: alt_on=$altOn deepX2=$deepX2" -ForegroundColor Yellow
}

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
& $PSMUX kill-server 2>&1 | Out-Null
