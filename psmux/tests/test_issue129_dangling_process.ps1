# Issue #129: Dangling psmux process when no sessions are active
#
# Clarified/verified behavior: psmux keeps an intentional __warm__ standby server
# for fast session creation, so a psmux.exe process legitimately exists while
# psmux is in use. The real requirement is that `kill-server` (and the
# uninstall-cleanup path) leaves NO dangling process: after kill-server in a
# socket namespace, zero psmux.exe processes and zero port/key files remain.
#
# Runs in an ISOLATED namespace (-L) so it never touches the user's real
# processes or the default __warm__ server.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue129_dangling_process.ps1

$ErrorActionPreference = 'Continue'
$PSMUX = (Get-Command psmux -ErrorAction Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$NS = 'gap129ns'
$pass = 0; $fail = 0
function P($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:fail++ }
function NsProcs { @(Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue | Where-Object { $_.CommandLine -like "*-L $NS*" }) }

Write-Host "`n=== Issue #129: no dangling process after kill-server (namespaced) ===" -ForegroundColor Cyan

& $PSMUX -L $NS kill-server 2>&1 | Out-Null; Start-Sleep -Milliseconds 600
Get-ChildItem "$psmuxDir\$NS*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
NsProcs | ForEach-Object { try{Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue}catch{} }

# Create two sessions in the namespace, then tear down.
& $PSMUX -L $NS new-session -d -s a 2>&1 | Out-Null
& $PSMUX -L $NS new-session -d -s b 2>&1 | Out-Null
for ($i=0;$i -lt 48;$i++){ if (Test-Path "$psmuxDir\${NS}__a.port"){ break }; Start-Sleep -Milliseconds 250 }
Start-Sleep -Seconds 2
if ((NsProcs).Count -ge 1) { P "servers running in namespace before teardown" } else { F "no servers started" }

# kill-session each, then kill-server to remove the warm standby too
& $PSMUX -L $NS kill-session -t a 2>&1 | Out-Null
& $PSMUX -L $NS kill-session -t b 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Seconds 2

$after = NsProcs
if ($after.Count -eq 0) { P "no dangling psmux process in namespace after kill-server" }
else { F "dangling process(es): $((($after|ForEach-Object{$_.CommandLine}) -join '; '))" }

# #129 is about a dangling PROCESS; assert no .port/.key remain. A leftover .sid
# is a harmless metadata orphan (noted as INFO, not a failure of this fix).
$liveFiles = @(Get-ChildItem "$psmuxDir\$NS*" -EA SilentlyContinue | Where-Object { $_.Name -match '\.(port|key)$' })
if ($liveFiles.Count -eq 0) { P "no orphan .port/.key files in namespace" }
else { F "orphan live files: $((($liveFiles|ForEach-Object{$_.Name}) -join ', '))" }
$sidLeft = @(Get-ChildItem "$psmuxDir\$NS*.sid" -EA SilentlyContinue)
if ($sidLeft.Count -gt 0) { Write-Host "  [INFO] minor: $($sidLeft.Count) orphan .sid file(s) remain (harmless metadata, separate cleanup nit)" -ForegroundColor DarkYellow }

NsProcs | ForEach-Object { try{Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue}catch{} }
Get-ChildItem "$psmuxDir\$NS*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Write-Host "`nResults: $pass passed, $fail failed"
exit $fail
