$ErrorActionPreference = 'Stop'
$taskRoot = $PSScriptRoot
$patchedPsmux = Join-Path $taskRoot 'psmux\target\release\psmux.exe'
$testData = Join-Path $taskRoot 'psmux\target\host-cwd-wt'
New-Item -ItemType Directory -Force -Path $testData | Out-Null
$launchCwd = (Get-Location).Path
@{ time = (Get-Date -Format o); pid = $PID; cwd = $launchCwd } |
    ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $testData 'launches.jsonl') -Encoding utf8
$env:PSMUX_DATA_DIR = $testData
$env:PSMUX_NO_WARM = '1'
& $patchedPsmux -L hostcwd-wt new-session -s "wt-$PID" -c $launchCwd -- cmd.exe /d /c C:\msys64\msys2_shell.cmd -defterm -ucrt64 -no-start -here -use-full-path -shell zsh
exit $LASTEXITCODE
