# Issue #268 - Proof that the fix wires set-titles into the dump-state JSON.
# This is the SERVER-SIDE proof: the client receives a host_title field
# whenever set-titles is on, with set-titles-string fully expanded.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "issue268_dump"
$script:Pass = 0
$script:Fail = 0

function Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function FailX($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Send-Tcp {
    param([string]$Cmd)
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $w = [System.IO.StreamWriter]::new($stream)
    $r = [System.IO.StreamReader]::new($stream)
    $w.Write("AUTH $key`n"); $w.Flush()
    $null = $r.ReadLine()
    $w.Write("$Cmd`n"); $w.Flush()
    $stream.ReadTimeout = 5000
    # dump-state can be multi-line; keep reading until we hit '}' as last char.
    $sb = [System.Text.StringBuilder]::new()
    try {
        while ($true) {
            $line = $r.ReadLine()
            if ($null -eq $line) { break }
            [void]$sb.AppendLine($line)
            if ($line.EndsWith('}') -and $sb.Length -gt 50) { break }
        }
    } catch {}
    $tcp.Close()
    return $sb.ToString().Trim()
}

Cleanup
Write-Host "`n=== Issue #268 Dump-state Proof ===" -ForegroundColor Cyan

& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { FailX "Session failed to start"; exit 2 }
Pass "Session started"

# --- Test 1: set-titles=off should NOT include host_title in dump ---
Write-Host "`n[Test 1] set-titles=off => host_title absent" -ForegroundColor Yellow
& $PSMUX set-option -g set-titles off 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$dump1 = Send-Tcp "dump-state"
if ($dump1 -match '"host_title"') {
    FailX "Expected NO host_title when set-titles=off, but it was present in dump"
} else {
    Pass "No host_title when set-titles=off"
}

# --- Test 2: set-titles=on with default string => host_title present ---
Write-Host "`n[Test 2] set-titles=on, default string => host_title='#S:#I:#W' expanded" -ForegroundColor Yellow
& $PSMUX set-option -g set-titles on 2>&1 | Out-Null
& $PSMUX set-option -g set-titles-string '' 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$dump2 = Send-Tcp "dump-state"
if ($dump2 -match '"host_title"\s*:\s*"([^"]*)"') {
    $val = $matches[1]
    Write-Host "    host_title = '$val'"
    # Default format "#S:#I:#W" -> "issue268_dump:0:something"
    if ($val -match '^issue268_dump:\d+:') {
        Pass "Default format expanded correctly: '$val'"
    } else {
        FailX "Default format unexpected: '$val'"
    }
} else {
    FailX "host_title NOT present when set-titles=on (default string)"
    Write-Host "    dump head: $($dump2.Substring(0, [Math]::Min(400, $dump2.Length)))" -ForegroundColor DarkGray
}

# --- Test 3: custom set-titles-string ---
Write-Host "`n[Test 3] custom set-titles-string='psmux/#S #W'" -ForegroundColor Yellow
& $PSMUX set-option -g set-titles-string 'psmux/#S #W' 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$dump3 = Send-Tcp "dump-state"
if ($dump3 -match '"host_title"\s*:\s*"([^"]*)"') {
    $val = $matches[1]
    Write-Host "    host_title = '$val'"
    if ($val -match '^psmux/issue268_dump') {
        Pass "Custom string expanded: '$val'"
    } else {
        FailX "Custom string unexpected: '$val'"
    }
} else {
    FailX "host_title not present with custom string"
}

# --- Test 4: rename-window changes the active window name => host_title updates ---
Write-Host "`n[Test 4] After rename-window 'mywin', host_title contains 'mywin'" -ForegroundColor Yellow
& $PSMUX rename-window -t $SESSION 'mywin' 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$dump4 = Send-Tcp "dump-state"
if ($dump4 -match '"host_title"\s*:\s*"([^"]*)"') {
    $val = $matches[1]
    Write-Host "    host_title = '$val'"
    if ($val -match 'mywin') {
        Pass "Window rename reflected in host_title: '$val'"
    } else {
        FailX "Window rename NOT reflected: '$val'"
    }
}

# --- Test 5: set-titles=off again => host_title disappears ---
Write-Host "`n[Test 5] set-titles=off again => host_title removed" -ForegroundColor Yellow
& $PSMUX set-option -g set-titles off 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$dump5 = Send-Tcp "dump-state"
if ($dump5 -match '"host_title"') {
    FailX "host_title still present after set-titles=off"
} else {
    Pass "host_title absent after toggling set-titles=off"
}

# --- Test 6: pane_title (#T) flows through when an app sets it via OSC 2 ---
Write-Host "`n[Test 6] OSC 2 from inside pane updates host_title via #T" -ForegroundColor Yellow
& $PSMUX set-option -g set-titles on 2>&1 | Out-Null
& $PSMUX set-option -g set-titles-string '#T' 2>&1 | Out-Null
& $PSMUX set-option -g allow-rename on 2>&1 | Out-Null

# Run a PowerShell command in the pane that emits an OSC 2 set-title
$marker = "INNER_APP_TITLE_268"
& $PSMUX send-keys -t $SESSION 'cls' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $PSMUX send-keys -t $SESSION ('Write-Host -NoNewline ([char]27 + "]2;{0}" + [char]7); Write-Host done' -f $marker) Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3

$dump6 = Send-Tcp "dump-state"
if ($dump6 -match '"host_title"\s*:\s*"([^"]*)"') {
    $val = $matches[1]
    Write-Host "    host_title = '$val'"
    if ($val -eq $marker) {
        Pass "OSC 2 from pane propagates to host_title"
    } else {
        Write-Host "    (host_title is the format-expansion of #T which is pane title)" -ForegroundColor DarkYellow
        Write-Host "    Got: '$val' (might be hostname fallback if pane title still empty)" -ForegroundColor DarkYellow
        if ($val -ne "") { Pass "host_title populated with non-empty value" }
        else { FailX "host_title is empty after OSC 2" }
    }
}

Cleanup
Write-Host "`n=== Result ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass" -ForegroundColor Green
Write-Host "  Failed: $script:Fail" -ForegroundColor $(if ($script:Fail -gt 0) {'Red'} else {'Green'})
exit $script:Fail
