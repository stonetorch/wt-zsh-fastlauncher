# Helper: emit alt-screen enter, 5 INNER lines, alt-screen exit, then
# exit.  No profile is loaded, so PSReadLine is not in the way.
[Console]::Out.Write([char]27 + "[?1049h")
1..5 | ForEach-Object { Write-Host "INNER $_" }
[Console]::Out.Write([char]27 + "[?1049l")
[Console]::Out.Flush()
