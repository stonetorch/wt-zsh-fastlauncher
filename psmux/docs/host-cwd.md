# Active pane cwd forwarding to Windows Terminal

This local change adds `host_cwd` to both server render-state paths. The client
announces changes using `ESC ] 9 ; 9 ; <Windows path> ESC \\`, which Windows
Terminal uses for its native Duplicate Tab and Duplicate Pane actions.

The active pane's OSC 7 / OSC 9;9 announcement takes precedence after conversion
through the existing Windows path translator. Without a usable announcement,
the existing `pane_current_path` query supplies the fallback. This precedence is
necessary for MSYS2: a foreground program can report the wrapper's original
Win32 startup cwd even after Zsh changes its POSIX cwd. The announcement retains
the shell's directory while a TUI runs. Background pane announcements cannot
change the host cwd. Status visibility and `set-titles` do not affect forwarding.

The client emits on first attach and on changes, suppresses duplicates, retries
failed writes, and rejects empty paths and control characters. The optional
wire field remains compatible with older clients and servers; an old server
cannot provide the new behavior, so testing requires a newly started server.

## Automated checks

```powershell
cargo test --bin psmux host_cwd
cargo build --release --bin psmux
cargo run --example verify_host_cwd -- target/release/psmux.exe
```

The example uses a private data directory under `target/host-cwd-live-<pid>` and
a unique `-L` namespace, then cleans up only that namespace. It tests server JSON
and actual attached-client output through ConPTY, including active pane/window
switches, background cwd changes, Unicode/spaces, status/title disabled, real
MSYS2 UCRT64 Zsh when installed at `C:\msys64`, an alternate-screen foreground
program, and a fresh attach. The MSYS2 check expects the user's `zsh-idle` hook.

## Native Windows Terminal check

Microsoft documents the OSC and native duplicate actions here:
https://learn.microsoft.com/en-us/windows/terminal/tutorials/new-tab-same-directory

From PowerShell, open an isolated test tab with this command (the paths below
assume a checkout at `%USERPROFILE%\Desktop\wt-zsh-fastlauncher`):

```powershell
wt.exe -w new new-tab --title host-cwd-test -d %USERPROFILE%\Desktop powershell.exe -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\Desktop\wt-zsh-fastlauncher\verify-wt-host-cwd.ps1
```

In Zsh, change directory with `builtin cd ~/Desktop/test111`. Use
WT's native Ctrl+Shift+D (Duplicate Tab), then Alt+Shift+D (the user's configured
Duplicate Pane). Check `pwd` in each new Zsh. Each copy must start in `test111`.
The script logs each process's inherited Windows cwd in
`target/host-cwd-wt/launches.jsonl`, so the host's inheritance can also be checked
independently of shell initialization. Repeat while a TUI is in the foreground.

Cleanup, after closing the test tabs:

```powershell
$env:PSMUX_DATA_DIR = "$env:USERPROFILE\Desktop\wt-zsh-fastlauncher\psmux\target\host-cwd-wt"
& "$env:USERPROFILE\Desktop\wt-zsh-fastlauncher\psmux\target\release\psmux.exe" -L hostcwd-wt kill-server
Remove-Item Env:PSMUX_DATA_DIR
```

Automated ConPTY results verify the emitted protocol, not WT's native GUI
actions. The native Duplicate/Split check remains a separate manual step.
