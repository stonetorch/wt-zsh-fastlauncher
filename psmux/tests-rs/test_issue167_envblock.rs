// Issue #167 - environment_block() must not emit entries that make
// CreateProcessW fail with ERROR_INVALID_PARAMETER (87).
//
// Tangibly reproduced on Windows 11 build 26200 (tests/test_issue167_envblock_probe.ps1):
// a ConPTY spawn with passthrough mode rejects the call with err 87 when the
// environment block contains ANY of:
//   * an entry whose value has an interior NUL  (corrupt REG_SZ/REG_EXPAND_SZ)
//   * an entry whose name is empty              ("=value")
//   * an entry whose name begins with '='       (cmd.exe "=C:" drive vars)
//   * an entry with no '=' at all
//
// environment_block() emits get_base_env()'s contents verbatim, and that data
// comes from externally-controlled sources (the parent process env and the
// HKLM/HKCU Environment registry keys via reg_value_to_string, which strips
// only TRAILING nulls). So a single corrupt value poisons the WHOLE block and
// the warm pane silently fails to spawn ("flashes black, returns to prompt").
//
// These tests pin the requirement that the emitted block is always well-formed
// regardless of what junk lands in the env map.

#![cfg(windows)]

use super::*;
use std::os::windows::ffi::OsStringExt;

/// Split a CreateProcessW environment block (NUL-separated entries, terminated
/// by a final empty entry) into its raw UTF-16 entries.  An interior NUL inside
/// a value therefore shows up here as a spurious extra entry, exactly as
/// CreateProcessW would (mis)parse it.
fn parse_block(block: &[u16]) -> Vec<Vec<u16>> {
    let mut entries = vec![];
    let mut cur = vec![];
    for &c in block {
        if c == 0 {
            if cur.is_empty() {
                break; // double-NUL: end of block
            }
            entries.push(std::mem::take(&mut cur));
        } else {
            cur.push(c);
        }
    }
    entries
}

/// True if every entry in the block is something CreateProcessW accepts:
/// non-empty name, name not starting with '=', and contains a '=' separator.
fn block_is_well_formed(block: &[u16]) -> Result<(), String> {
    // Must be terminated by a final NUL (double-NUL overall).
    if block.last() != Some(&0) {
        return Err("block is not NUL terminated".into());
    }
    for entry in parse_block(block) {
        let eq = '=' as u16;
        let pos = entry.iter().position(|&c| c == eq);
        match pos {
            None => {
                return Err(format!(
                    "entry without '=': {:?}",
                    String::from_utf16_lossy(&entry)
                ));
            }
            Some(0) => {
                return Err(format!(
                    "entry with empty/`=`-prefixed name: {:?}",
                    String::from_utf16_lossy(&entry)
                ));
            }
            Some(_) => {}
        }
    }
    Ok(())
}

fn os_with_interior_nul() -> OsString {
    // "foo\0bar" - the kind of thing a corrupt REG_SZ value yields.
    OsString::from_wide(&['f' as u16, 'o' as u16, 'o' as u16, 0, 'b' as u16, 'a' as u16, 'r' as u16])
}

#[test]
fn block_well_formed_with_clean_env() {
    let mut cmd = CommandBuilder::new("dummy");
    cmd.env("ALPHA", "one");
    cmd.env("BETA", "two");
    let block = cmd.environment_block();
    block_is_well_formed(&block).expect("clean env must produce a well-formed block");
}

#[test]
fn interior_nul_in_value_does_not_poison_block() {
    let mut cmd = CommandBuilder::new("dummy");
    cmd.env("GOODVAR", "fine");
    cmd.env("BADVAR", os_with_interior_nul());
    let block = cmd.environment_block();
    block_is_well_formed(&block)
        .expect("interior NUL in a value must not produce a malformed block (issue #167)");
    // GOODVAR must survive.
    let joined = String::from_utf16_lossy(&block);
    assert!(joined.contains("GOODVAR=fine"), "unrelated vars must be preserved");
}

#[test]
fn empty_name_entry_is_dropped() {
    let mut cmd = CommandBuilder::new("dummy");
    cmd.env("", "orphan");
    cmd.env("KEEP", "yes");
    let block = cmd.environment_block();
    block_is_well_formed(&block)
        .expect("empty-name entry must be dropped, not emitted as `=orphan` (issue #167)");
    let joined = String::from_utf16_lossy(&block);
    assert!(joined.contains("KEEP=yes"), "valid vars must be preserved");
}

#[test]
fn equals_prefixed_name_entry_is_dropped() {
    let mut cmd = CommandBuilder::new("dummy");
    // cmd.exe drive vars look like "=C:" -> "C:\\path".
    cmd.env("=C:", "C:\\some\\dir");
    cmd.env("REAL", "value");
    let block = cmd.environment_block();
    block_is_well_formed(&block)
        .expect("`=`-prefixed name must be dropped (CreateProcessW err 87 on build 26200)");
    let joined = String::from_utf16_lossy(&block);
    assert!(joined.contains("REAL=value"), "valid vars must be preserved");
}

#[test]
fn block_stays_double_nul_terminated() {
    let mut cmd = CommandBuilder::new("dummy");
    cmd.env("BADVAR", os_with_interior_nul());
    let block = cmd.environment_block();
    assert_eq!(block.last(), Some(&0), "block must end with a NUL terminator");
}
