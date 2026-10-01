# Verbose probe: open the display-popup interactive shell and DUMP the popup_rows
# text so we can see whether a shell prompt rendered and whether injected input
# appears. Prints the decoded popup content (runs.text concatenated per row).
$ErrorActionPreference = "Continue"
$NS = "rb351p"; $SESS = "p"
$psmuxExe = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"

$conf = "$env:TEMP\rb351p.conf"
@"
unbind C-b
set -g prefix C-a
bind-key C-a send-prefix
bind-key P display-popup -E -w 80% -h 80%
"@ | Set-Content -Path $conf -Encoding UTF8

function Get-Dump {
    $portFile = "$psmuxDir\${NS}__${SESS}.port"; $keyFile = "$psmuxDir\${NS}__${SESS}.key"
    if (-not (Test-Path $portFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim(); $key = (Get-Content $keyFile -Raw).Trim()
    $tcp=$null
    try {
        $tcp=[System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$port); $tcp.NoDelay=$true; $tcp.ReceiveTimeout=4000
        $s=$tcp.GetStream(); $s.ReadTimeout=4000; $w=[System.IO.StreamWriter]::new($s); $r=[System.IO.StreamReader]::new($s)
        $w.Write("AUTH $key`n"); $w.Flush(); $null=$r.ReadLine(); $w.Write("PERSISTENT`n"); $w.Flush()
        $w.Write("dump-state`n"); $w.Flush()
        $best=$null; $tcp.ReceiveTimeout=800
        for($j=0;$j -lt 80;$j++){ try{$line=$r.ReadLine()}catch{break}; if($null -eq $line){break}; if($line -ne "NC" -and $line.Length -gt 100){$best=$line}; if($best){$tcp.ReceiveTimeout=60} }
        return $best
    } catch { return $null } finally { if($tcp){$tcp.Close()} }
}
function Show-Popup($label,$dump){
    Write-Host "----- $label -----" -ForegroundColor Cyan
    if (-not $dump) { Write-Host "(no dump)"; return }
    try { $j = $dump | ConvertFrom-Json } catch { Write-Host "(json parse fail)"; return }
    Write-Host ("popup_active={0} popup_has_pty={1}" -f $j.popup_active, $j.popup_has_pty)
    if ($j.popup_rows) {
        $n=0
        foreach($row in $j.popup_rows){
            $txt = -join ($row.runs | ForEach-Object { $_.text })
            if ($txt.Trim().Length -gt 0) { Write-Host ("  row: {0}" -f $txt.TrimEnd()); $n++ }
        }
        if ($n -eq 0) { Write-Host "  (popup_rows all blank)" }
    } else { Write-Host "  (no popup_rows)"; }
    if ($j.popup_lines) { foreach($l in $j.popup_lines){ Write-Host "  line: $l" } }
}

try {
    & $psmuxExe -L $NS kill-server 2>&1 | Out-Null; Start-Sleep -Milliseconds 500
    $env:PSMUX_CONFIG_FILE=$conf
    $proc = Start-Process -FilePath $psmuxExe -ArgumentList "-L",$NS,"new-session","-s",$SESS -PassThru
    Start-Sleep -Seconds 5
    $env:PSMUX_CONFIG_FILE=$null

    & $injector $proc.Id "^a{SLEEP:400}P" 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    Show-Popup "AFTER OPEN (waited 4s for shell prompt)" (Get-Dump)

    & $injector $proc.Id "echo PMARKER351{ENTER}" 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    Show-Popup "AFTER 'echo PMARKER351' + Enter" (Get-Dump)
}
finally {
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    & $psmuxExe -L $NS kill-server 2>&1 | Out-Null
    Remove-Item $conf -Force -EA SilentlyContinue
}
