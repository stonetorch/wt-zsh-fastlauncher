# Debug: what does the pane actually contain in Scenario B?
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

$SESSION = "iss88_debug"
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 4
[void](Wait-Prompt -Target $SESSION)

& $PSMUX set-option -g alternate-screen off 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Write-Host "alternate-screen = $((& $PSMUX show-options -g -v alternate-screen 2>&1).Trim())"

& $PSMUX send-keys -t $SESSION '1..30 | ForEach-Object { "main $_" }' Enter 2>&1 | Out-Null
[void](Wait-Output -Target $SESSION -Marker "main 29")
Start-Sleep -Seconds 1

Write-Host "`n--- After main 30 lines, before 1049h ---"
$capBefore = & $PSMUX capture-pane -t $SESSION -S -2000 -p 2>&1 | Out-String
$mainBefore = ([regex]::Matches($capBefore, '(?m)^main (\d+)\b')).Count
Write-Host "main count BEFORE 1049h = $mainBefore"

& $PSMUX send-keys -t $SESSION '[Console]::Out.Write([char]27 + "[?1049h")' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1
$altOn = (& $PSMUX display-message -t $SESSION -p '#{alternate_on}' 2>&1).Trim()
Write-Host "1049h sent, #{alternate_on}=$altOn"

& $PSMUX send-keys -t $SESSION '1..20 | ForEach-Object { "alt $_" }' Enter 2>&1 | Out-Null
[void](Wait-Output -Target $SESSION -Marker "alt 19")
Start-Sleep -Seconds 1

Write-Host "`n--- After alt 20 lines, before 1049l ---"
$capMid = & $PSMUX capture-pane -t $SESSION -S -2000 -p 2>&1 | Out-String
$mainMid = ([regex]::Matches($capMid, '(?m)^main (\d+)\b')).Count
$altMid = ([regex]::Matches($capMid, '(?m)^alt (\d+)\b')).Count
Write-Host "BEFORE 1049l: main=$mainMid, alt=$altMid"

& $PSMUX send-keys -t $SESSION '[Console]::Out.Write([char]27 + "[?1049l")' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1

Write-Host "`n--- After 1049l ---"
$capAfter = & $PSMUX capture-pane -t $SESSION -S -2000 -p 2>&1 | Out-String
$mainAfter = ([regex]::Matches($capAfter, '(?m)^main (\d+)\b')).Count
$altAfter = ([regex]::Matches($capAfter, '(?m)^alt (\d+)\b')).Count
Write-Host "AFTER 1049l: main=$mainAfter, alt=$altAfter"

Write-Host "`n--- Last 1500 chars of -S -2000 capture ---"
$tail = if ($capAfter.Length -gt 1500) { $capAfter.Substring($capAfter.Length - 1500) } else { $capAfter }
Write-Host $tail

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
& $PSMUX kill-server 2>&1 | Out-Null
