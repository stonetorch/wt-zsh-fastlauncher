# Repro for issue #351: `bind P display-popup -E -w 80% -h 80%` should open an
# INTERACTIVE popup (running the default shell because -E + no command), but the
# reporter sees an empty static popup ("Press 'q' or Escape to close") that does
# not accept input.
#
# This script PROVES the behavior via real keystroke injection + dump-state:
#   1. start attached session with the reporter's exact config (prefix C-a, bind P)
#   2. inject prefix(C-a)+P to open the popup
#   3. dump-state: is popup_active true? what is the popup content?
#   4. inject "echo PMARKER351" + Enter into the popup
#   5. dump-state again: did the popup react (interactive shell) or stay static?
#
# Namespaced -L rb351. Cleanup only via -L rb351 kill-server + our own PID.

$ErrorActionPreference = "Continue"
$NS = "rb351"
$SESS = "rb351_s"
$psmuxExe = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$pass = 0; $fail = 0
function P($m){ Write-Host "[PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m){ Write-Host "[FAIL] $m" -ForegroundColor Red; $script:fail++ }
function I($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }

if (-not (Test-Path $injector)) { Write-Host "injector missing; aborting"; exit 2 }

# Reporter's exact config.
$conf = "$env:TEMP\rb351.conf"
@"
unbind C-b
set -g prefix C-a
bind-key C-a send-prefix
bind-key P display-popup -E -w 80% -h 80%
"@ | Set-Content -Path $conf -Encoding UTF8

function Get-Dump {
    param([string]$Session)
    $portFile = "$psmuxDir\${NS}__${Session}.port"
    $keyFile  = "$psmuxDir\${NS}__${Session}.key"
    if (-not (Test-Path $portFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = if (Test-Path $keyFile) { (Get-Content $keyFile -Raw).Trim() } else { "" }
    $tcp = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 4000
        $s = $tcp.GetStream(); $s.ReadTimeout = 4000
        $w = [System.IO.StreamWriter]::new($s); $r = [System.IO.StreamReader]::new($s)
        if ($key) { $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine() }
        $w.Write("PERSISTENT`n"); $w.Flush()
        $w.Write("dump-state`n"); $w.Flush()
        $best = $null
        $tcp.ReceiveTimeout = 800
        for ($j=0; $j -lt 60; $j++) {
            try { $line = $r.ReadLine() } catch { break }
            if ($null -eq $line) { break }
            if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line }
            if ($best) { $tcp.ReceiveTimeout = 50 }
        }
        return $best
    } catch { return $null } finally { if ($tcp) { $tcp.Close() } }
}

try {
    & $psmuxExe -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\${NS}__*" -Force -EA SilentlyContinue

    $env:PSMUX_CONFIG_FILE = $conf
    $proc = Start-Process -FilePath $psmuxExe -ArgumentList "-L",$NS,"new-session","-s",$SESS -PassThru
    Start-Sleep -Seconds 5
    $env:PSMUX_CONFIG_FILE = $null

    & $psmuxExe -L $NS has-session -t $SESS 2>$null
    if ($LASTEXITCODE -eq 0) { P "session up" } else { F "session did not start"; throw "no session" }

    # Confirm binding registered as reporter showed.
    $kb = (& $psmuxExe -L $NS list-keys -T prefix 2>&1 | Out-String)
    if ($kb -match "P\s+display-popup") { P "binding present: prefix P -> display-popup -E" }
    else { I "prefix P binding line not matched in list-keys (continuing)" }

    $dump0 = Get-Dump $SESS
    $popup0 = $false
    if ($dump0) { try { $popup0 = [bool]([bool]([regex]::IsMatch($dump0,'"popup_active"\s*:\s*true'))) } catch {} }
    I "before injection popup_active=$popup0"

    # Open the popup: prefix (C-a) then capital P.
    & $injector $proc.Id "^a{SLEEP:400}P" 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $dump1 = Get-Dump $SESS
    $popup1 = $false; $content1 = ""
    if ($dump1) {
        $popup1 = [regex]::IsMatch($dump1,'"popup_active"\s*:\s*true')
        $m = [regex]::Match($dump1,'"popup_(text|content|output|lines)"\s*:\s*("(?<s>(\\.|[^"\\])*)"|\[(?<a>[^\]]*)\])')
        if ($m.Success) { $content1 = $m.Value }
    }
    if ($popup1) { P "prefix+P opened a popup (popup_active=true)" }
    else { F "prefix+P did NOT open a popup (popup_active not true) - dump len=$([int]($dump1 | Measure-Object -Character).Characters)" }
    I "popup content marker after open: $content1"

    # Inject a command into the popup. If interactive shell, echo runs.
    & $injector $proc.Id "echo PMARKER351{ENTER}" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $dump2 = Get-Dump $SESS
    $reacted = $false
    if ($dump2 -and ($dump2 -match "PMARKER351")) { $reacted = $true }

    if ($reacted) {
        P "popup is INTERACTIVE: injected 'echo PMARKER351' appears in state (shell ran in popup)"
    } else {
        F "BUG #351 REPRODUCED: popup did NOT react to input (no PMARKER351 in state); display-popup -E is not running an interactive shell"
    }

    # Also surface whether the popup shows the static 'Press q or Escape' hint with no shell.
    if ($dump1 -and ($dump1 -match "Press 'q'" -or $dump1 -match "Escape to close")) {
        I "popup shows static 'Press q/Escape to close' hint (matches reporter screenshot)"
    }

    & $injector $proc.Id "{ESC}" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
}
finally {
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    & $psmuxExe -L $NS kill-server 2>&1 | Out-Null
    Remove-Item $conf -Force -EA SilentlyContinue
}

Write-Host "`nPassed=$pass Failed=$fail"
exit $fail
