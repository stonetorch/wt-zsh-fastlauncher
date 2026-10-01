# Tiny script: emit only the escape sequences requested via stdin,
# nothing else.  Used to drive psmux pane parsers from tests without
# PSReadLine prompt-redraw noise.
param([string]$Mode)
[Console]::Out.Write([char]27 + "[?1049$Mode")
[Console]::Out.Flush()
