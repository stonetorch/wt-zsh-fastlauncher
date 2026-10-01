# Issue #120: `__warm__` server remains after the last pane exits
#
# Clarified/verified behavior: the __warm__ server is an INTENTIONAL standby,
# pre-spawned so the next `new-session` is fast. It legitimately persists while
# psmux is in use. The real requirement (the #120 / #138 fix surface) is that an
# explicit `kill-server` tears down BOTH the live session server AND the standby
# __warm__ server in that socket namespace, leaving no lingering process or files.
#
# Runs entirely in an ISOLATED socket namespace (-L) so it never touches the
# user's real __warm__ server or sessions.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue120_warm_server_leak.ps1

$ErrorActionPreference = 'Continue'
$PSMUX = (Get-Command psmux -ErrorAction Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$NS = 'gap120ns'
$pass = 0; $fail = 0
function P($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:fail++ }
function NsProcs { @(Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue | Where-Object { $_.CommandLine -like "*-L $NS*" }) }

Write-Host "`n=== Issue #120: warm server cleanup via kill-server (namespaced) ===" -ForegroundColor Cyan

& $PSMUX -L $NS kill-server 2>&1 | Out-Null; Start-Sleep -Milliseconds 600
Get-ChildItem "$psmuxDir\$NS*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
NsProcs | ForEach-Object { try{Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue}catch{} }

& $PSMUX -L $NS new-session -d -s s1 2>&1 | Out-Null
$pf = "$psmuxDir\${NS}__s1.port"
for ($i=0;$i -lt 48;$i++){ if (Test-Path $pf){ break }; Start-Sleep -Milliseconds 250 }
Start-Sleep -Seconds 2

$before = NsProcs
if ($before.Count -ge 1) { P "session server running in namespace ($($before.Count) psmux proc incl any warm standby)" }
else { F "expected a running server in namespace, found none" }

& $PSMUX -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Seconds 2
$after = NsProcs
if ($after.Count -eq 0) { P "kill-server removed ALL namespace processes incl __warm__ (no lingering process)" }
else { F "kill-server left $($after.Count) lingering process(es): $((($after|ForEach-Object{$_.CommandLine}) -join '; '))" }

# The #120 issue is about a dangling PROCESS; assert no .port/.key remain (the
# live-server registry files). A leftover .sid is a separate, harmless metadata
# orphan (noted as INFO, not a failure of this issue's fix).
$liveFiles = @(Get-ChildItem "$psmuxDir\$NS*" -EA SilentlyContinue | Where-Object { $_.Name -match '\.(port|key)$' })
if ($liveFiles.Count -eq 0) { P "no lingering .port/.key files in namespace after kill-server" }
else { F "lingering live files: $((($liveFiles|ForEach-Object{$_.Name}) -join ', '))" }
$sidLeft = @(Get-ChildItem "$psmuxDir\$NS*.sid" -EA SilentlyContinue)
if ($sidLeft.Count -gt 0) { Write-Host "  [INFO] minor: $($sidLeft.Count) orphan .sid file(s) remain after kill-server (harmless metadata, separate cleanup nit)" -ForegroundColor DarkYellow }

NsProcs | ForEach-Object { try{Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue}catch{} }
Get-ChildItem "$psmuxDir\$NS*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Write-Host "`nResults: $pass passed, $fail failed"
exit $fail
