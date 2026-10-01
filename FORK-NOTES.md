# Fork Notes

This document records the exact upstream baseline this fork was derived from,
and every change made on top of it. It exists so the provenance of the
`psmux/` directory stays verifiable even though the upstream `.git` history is
not shipped with this repository.

## Upstream baseline

| Field | Value |
| --- | --- |
| Repository | https://github.com/psmux/psmux |
| Commit | `7f070fec5f1022d4995e3808f34666d829aee0e5` |
| Short hash | `7f070fe` |
| `git describe` | `v3.3.8-620-g7f070fe` |
| Commit date | 2026-10-01T13:04:59+05:30 |
| Branch | `master` |
| Crate version | `3.3.8` |
| License | MIT — Copyright (c) 2025 Josh |
| License text | [`psmux/LICENSE`](psmux/LICENSE) |

Everything under `psmux/` is that commit, modified as listed below.
The fork is maintained by **stonetorch**.

## Change summary

16 files touched: **9 modified**, **7 added**.

- Tracked files: `+209 / -1` lines
- New files: 1301 lines

## Added files

| File | Lines | Purpose |
| --- | --- | --- |
| `psmux/src/zsh_pool.rs` | 381 | Native Zsh pool allocator: `prepare` / `claim` / `ready` plus the `Claim` lease type. |
| `psmux/examples/verify_host_cwd.rs` | 307 | Live ConPTY harness for `host_cwd` forwarding. |
| `psmux/examples/verify_zsh_pool.rs` | 298 | Live harness for the Zsh pool: reuse, concurrency, Unicode cwd, termination. |
| `psmux/docs/zsh-pool.md` | 91 | Design and reuse contract for the Zsh pool. |
| `psmux/src/host_cwd.rs` | 82 | `emit_host_cwd` / `valid_cwd`: OSC 9;9 emission with dedupe and validation. |
| `psmux/scripts/update-install.ps1` | 79 | Build-and-install helper that syncs this fork's build into the PATH install dir. |
| `psmux/docs/host-cwd.md` | 63 | Design and verification notes for `host_cwd`. |

## Modified files

| File | Delta | Change |
| --- | --- | --- |
| `psmux/src/main.rs` | `+20 / -1` | Declares the two new modules; intercepts the `zsh-pool` subcommand and rewrites it into the normal native attach / new-session path, holding the reservation lease for the client's lifetime. |
| `psmux/src/server/helpers.rs` | `+27` | Adds `host_cwd` to `StatusFormats` and computes it (OSC 9;9 announcement first, `pane_current_path` as fallback); adds `append_host_cwd_json`. |
| `psmux/src/server/connection.rs` | `+23` | Adds the `zsh-pool-claim` and `zsh-pool-ready` control commands with Base64-decoded cwd and a synchronous reply. |
| `psmux/src/client.rs` | `+13` | Parses the `host_cwd` render field and emits OSC 9;9 to the host terminal with change-only debounce. |
| `psmux/src/server/mod.rs` | `+12` | Holds the pool claim state; routes `ZshPoolClaim` / `ZshPoolReady`; appends `host_cwd` to both render-state paths. |
| `psmux/src/cli.rs` | `+3` | Registers the `zsh-pool` command template and help text. |
| `psmux/src/types.rs` | `+2` | Adds `CtrlReq::ZshPoolClaim` and `CtrlReq::ZshPoolReady`. |
| `psmux/src/help.rs` | `+1` | Lists `zsh-pool` in the CLI command table. |
| `psmux/tests-rs/test_issue615_warm_claim_cwd_hint.rs` | `+109` | Adds 6 tests covering `host_cwd` precedence and Zsh pool eligibility, atomicity, and readiness. |

## The two features

**1. `host_cwd` — active pane cwd forwarding.**
Adds the active pane's working directory to both server render-state paths and
has the client announce it to the host terminal via `ESC ] 9 ; 9 ; <path> ESC \`,
which Windows Terminal uses for native Duplicate Tab / Duplicate Pane. The pane's
own OSC 7 / OSC 9;9 announcement wins over `pane_current_path`, because a MSYS2
foreground program can report the wrapper's stale Win32 startup cwd. Forwarding
is independent of status visibility and `set-titles`. See `psmux/docs/host-cwd.md`.

**2. `zsh-pool` — persistent MSYS2 Zsh allocator.**
Runs inside psmux as `psmux -L zsh-pool zsh-pool`. It reuses a detached, idle,
single-pane `zsh-*` session when one is available and otherwise creates a new
one, then continues through the normal native attach path — no external launcher
and no psmux subprocess calls. Reuse is guarded by an exclusive per-session lock
held for the client's whole lifetime. See `psmux/docs/zsh-pool.md`.

## The full diff

[`patches/psmux-fork-vs-7f070fe.patch`](patches/psmux-fork-vs-7f070fe.patch)
contains the complete unified diff of this fork against the upstream commit,
including the added files as new-file hunks.

To rebase these changes onto the upstream tree:

```sh
git clone https://github.com/psmux/psmux.git
cd psmux
git checkout 7f070fec5f1022d4995e3808f34666d829aee0e5
git apply /path/to/patches/psmux-fork-vs-7f070fe.patch
```

The patch preserves the line endings it was generated with. Match the upstream
repository's `core.autocrlf` setting when applying it.

## Licensing

The changes listed above are distributed under the same MIT license as the
upstream project. See [`NOTICE`](NOTICE) for the full third-party attribution,
including psmux's own vendored dependencies.
