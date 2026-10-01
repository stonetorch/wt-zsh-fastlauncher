# wt-zsh-fastlauncher

> **Unofficial fork.** This project is built on top of
> [psmux](https://github.com/psmux/psmux) (MIT, Copyright (c) 2025 Josh) and
> redistributes a modified copy of it under `psmux/`. It is not affiliated with
> or endorsed by the psmux project. See [NOTICE](NOTICE) for third-party
> attribution and [FORK-NOTES.md](FORK-NOTES.md) for the exact upstream commit
> this fork is based on and the full list of changes.

Native Rust launcher for:

Windows Terminal -> psmux -> persistent MSYS2 UCRT64 zsh

The preferred entry is now the integrated `psmux -L zsh-pool zsh-pool` command
in the local `psmux/` fork. See [native pool usage and verification](psmux/docs/zsh-pool.md).
The standalone launcher below remains the earlier implementation.

Behavior:

1. Scan all psmux panes once.
2. Reuse the first session that is:
   - named `zsh-*`
   - detached (`session_attached == 0`)
   - alive
   - marked `zsh-idle`
3. Before attaching, instantly paste `builtin cd -- '<current directory>' && clear` to change directory and then clear the screen.
4. If no idle zsh exists, create a new psmux session running MSYS2 UCRT64 zsh.

## Required zsh idle marker

At the end of `~/.zshrc`:

```zsh
if [[ -n "$PSMUX_SESSION" ]]; then
    autoload -Uz add-zsh-hook

    _psmux_mark_idle() {
        print -Pn '\e]2;zsh-idle\a'
        local winpwd
        winpwd="$(cygpath -w "$PWD")"
        printf '\e]9;9;%s\e\\' "$winpwd"
    }

    _psmux_mark_busy() {
        print -Pn '\e]2;zsh-busy\a'
    }

    add-zsh-hook precmd  _psmux_mark_idle
    add-zsh-hook preexec _psmux_mark_busy
fi
```

In `%USERPROFILE%\.psmux.conf`:

```tmux
set -g allow-set-title on
set -g status off
```

After changing psmux config, restart the psmux server once:

```powershell
psmux kill-server
```

## Optional: Ctrl+D detaches instead of closing the shell

By default `Ctrl+D` on an empty prompt runs `exit`: the shell process ends, the
pooled session is destroyed, and the next tab has to pay for a cold start. This
widget turns that keystroke into a detach instead, so the session stays alive
and stays reusable — jobs, history, aliases, and shell variables survive with it.

Add to `~/.zshrc`, after the idle marker block above:

```zsh
if [[ -n "$PSMUX_SESSION" ]]; then
    setopt IGNORE_EOF   # required: lets an empty line reach the widget below

    _psmux_ctrl_d() {
        # Only release on an empty command line with no pending multi-line input.
        if [[ -z "$BUFFER" && -z "$PREBUFFER" ]]; then
            if ! psmux detach-client; then
                zle -M 'psmux detach failed; session kept'
            fi
        else
            # With text typed, keep the usual delete-char / list-choices behavior.
            zle .delete-char-or-list
        fi
    }

    zle -N _psmux_ctrl_d
    bindkey -M emacs '^D' _psmux_ctrl_d
    bindkey -M viins '^D' _psmux_ctrl_d
fi
```

`psmux` must be on your `PATH`. If it is not, replace it with a full MSYS path
to the binary, for example
`/c/Users/<you>/AppData/Local/psmux/psmux.exe`.

## Build

From PowerShell:

```powershell
cd <this-project>
cargo build --release
```

Binary:

```text
target\release\wt-zsh-fastlauncher.exe
```

Copy it somewhere permanent, for example:

```powershell
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Copy-Item .\target\release\wt-zsh-fastlauncher.exe "$HOME\bin\wt-zsh-fastlauncher.exe"
```

## Windows Terminal profile

Example:

```json
{
    "closeOnExit": "always",
    "commandline": "%USERPROFILE%\\bin\\wt-zsh-fastlauncher.exe",
    "guid": "{f6290734-5462-4308-ac88-c661d3469211}",
    "hidden": false,
    "icon": "%LOCALAPPDATA%\\TerminalIcons\\zsh.png",
    "name": "Zsh",
    "pathTranslationStyle": "msys2"
}
```

If you want "Open in Terminal" / `wt -d <dir>` to determine the directory, do not force a fixed
`startingDirectory` in this profile. The launcher uses its own Windows current working directory.

## psmux executable selection

Order:

1. `PSMUX_EXE` environment variable, if set.
2. `%LOCALAPPDATA%\psmux\psmux.exe`, if present.
3. `psmux.exe` from PATH.

This intentionally prefers the installed psmux build containing unreleased fixes. The copy in
`%LOCALAPPDATA%\psmux\` is produced from this repo's `psmux/` fork; refresh it with
`psmux/scripts/update-install.ps1` after changing that source.

## MSYS2 location

Default:

```text
C:\msys64
```

If different:

```powershell
setx MSYS2_ROOT "D:\msys64"
```

## Debug

Temporarily:

```powershell
$env:PSMUX_ZSH_DEBUG = "1"
.\wt-zsh-fastlauncher.exe
```

The launcher prints which psmux it chose, the Windows/MSYS paths, and whether it reused or created a
session.

## Notes

- The local psmux source in `psmux/` implements active-pane `host_cwd` forwarding to Windows Terminal. See [implementation and verification](psmux/docs/host-cwd.md). Build with `cargo build --release --bin psmux` from that directory.
- Point `PSMUX_EXE` at `psmux\target\release\psmux.exe` to select the patched binary. Existing servers must also use the patched version; the isolated verification script starts fresh servers without replacing your running sessions.

- Unicode/CJK paths are converted directly in Rust; `cygpath` is not called.
- `send-paste` transports the `cd` and `clear` command as UTF-8 Base64.
- `builtin cd` bypasses zoxide's `cd` wrapper.
- Reusing an idle shell uses one `send-paste` call plus one `send-keys Enter` call; `send-paste` requires exactly one Base64 payload.
- When no idle shell exists, `new-session` creates and attaches in one psmux process.
