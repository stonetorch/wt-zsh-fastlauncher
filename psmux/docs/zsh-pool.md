# Native persistent MSYS2 Zsh pool

Run `psmux -L zsh-pool zsh-pool` from Windows Terminal. The current Windows cwd
is the requested directory. `-c <directory>` overrides it. `MSYS2_ROOT` defaults
to `C:\msys64`; new sessions use the established `msys2_shell.cmd -ucrt64
-defterm -no-start -here -use-full-path -shell zsh` startup.

The allocator runs inside psmux and continues through its normal native attach
or new-session path. It does not start an external PowerShell or Rust launcher
and does not invoke psmux subprocesses to list, paste, send keys, or attach.

## Reuse contract

The shell opts in with these existing hooks; no changes are required:

```zsh
if [[ -n "$PSMUX_SESSION" ]]; then
    autoload -Uz add-zsh-hook
    _psmux_mark_idle() {
        print -Pn '\e]2;zsh-idle\a'
        if [[ -n "$WT_SESSION" ]]; then
            local winpwd
            winpwd="$(cygpath -w "$PWD")"
            printf '\e]9;9;%s\e\\' "$winpwd"
        fi
    }
    _psmux_mark_busy() { print -Pn '\e]2;zsh-busy\a'; }
    add-zsh-hook precmd _psmux_mark_idle
    add-zsh-hook preexec _psmux_mark_busy
fi
```

Only detached `zsh-*` sessions in the selected namespace are considered.
The server must have exactly one window and one live pane, be in passthrough
mode, have no floating panes, and have the raw shell title `zsh-idle` outside
the alternate screen. Attached, busy, dead, complex, and older incompatible
servers are left intact. A busy detached shell can become reusable when its
foreground command ends and precmd emits the idle marker.

On reuse, the server rechecks eligibility and writes `builtin cd -- '<MSYS
directory>' && clear` followed by Enter in one event-loop turn. Paths are
converted and quoted natively. The allocator waits for a newer parser output
version, an idle prompt, and the confirmed requested cwd before attaching.
Shell variables, jobs, aliases, and history stay in the same running shell;
the visible terminal screen is cleared. A failed or unconfirmed cd reports an
error and leaves the existing session intact.

An exclusive per-session file handle is held for the client's whole lifetime,
including creation before attach registration. This prevents concurrent pool
clients from claiming the same shell. Windows releases the handle on client
exit or termination; tiny lock files persist and are reused. The server also
tracks the claiming process and refuses a second live claim. No lock expires
on a timer while its owner is still alive.

## Windows Terminal profile

Build with `cargo build --release --bin psmux --target-dir target/pool-final`.
This separate output preserves the executable already serving existing
host-cwd test sessions. The current workspace's profile command is:

```json
"commandline": "%USERPROFILE%\\Desktop\\psmux-zsh-launcher\\psmux\\target\\pool-final\\release\\psmux.exe -L zsh-pool zsh-pool"
```

`startingDirectory` may remain the Desktop. Native Duplicate Tab / Duplicate
Pane receives the active shell cwd through `host_cwd`. Previously running
sessions in the default namespace or `.psmux-hostcwd` registry are preserved;
the new `-L zsh-pool` namespace starts its own pool. Close or detach a new pool
tab at an idle prompt, then reopen to reuse it. Closing a tab while a command
is busy leaves that session ineligible until it returns to idle. Configurations
using `destroy-unattached on` destroy detached sessions and should use `off`
for persistent pooling.

The compatibility `launch-patched-zsh.cmd` now invokes this native entry as
well. Pointing the profile directly at psmux removes the cmd wrapper too.

## Validation

```powershell
cargo test --bin psmux zsh_pool
cargo test --bin psmux host_cwd
cargo run --example verify_zsh_pool -- target/pool-final/release/psmux.exe
cargo run --example verify_host_cwd -- target/pool-final/release/psmux.exe
```

Live checks use private workspace data directories and unique namespaces.
The pool harness creates real MSYS2 Zsh shells, preserves a shell variable and
pane PID across reuse, exercises quoted Unicode cwd, skips attached and busy
sessions, starts simultaneous clients, and checks reuse after client termination.
Only test namespaces are cleaned up. It expects the supplied Zsh idle/busy hooks.
Use `PSMUX_ZSH_DEBUG=1` to log each `create`/`reuse` decision.
