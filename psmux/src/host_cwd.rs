//! Forward the active pane's native cwd to the host terminal (ConEmu OSC 9;9).

use std::io::{self, Write};

/// Empty paths and control characters must never enter an OSC payload.
pub(crate) fn valid_cwd(cwd: &str) -> bool {
    !cwd.is_empty() && !cwd.chars().any(char::is_control)
}

/// A missing value resets the cache so reappearing cwd is announced again.
/// Cache only successful writes, allowing the next frame to retry an I/O error.
pub(crate) fn emit_host_cwd(
    out: &mut impl Write,
    cwd: Option<&str>,
    last: &mut Option<String>,
) -> io::Result<()> {
    let cwd = cwd.filter(|cwd| valid_cwd(cwd));
    if cwd == last.as_deref() {
        return Ok(());
    }
    if let Some(cwd) = cwd {
        write!(out, "\x1b]9;9;{}\x1b\\", cwd)?;
        out.flush()?;
    }
    *last = cwd.map(str::to_owned);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forwards_unicode_spaces_and_semicolons_with_st_terminator() {
        let mut out = Vec::new();
        let mut last = None;
        emit_host_cwd(&mut out, Some(r"C:\测试 dir;name"), &mut last).unwrap();
        assert_eq!(out, "\x1b]9;9;C:\\测试 dir;name\x1b\\".as_bytes());
    }

    #[test]
    fn debounces_changes_and_reannounces_after_missing_state() {
        let mut out = Vec::new();
        let mut last = None;
        for cwd in [
            Some(r"C:\A"),
            Some(r"C:\A"),
            Some(r"D:\B"),
            None,
            Some(r"D:\B"),
        ] {
            emit_host_cwd(&mut out, cwd, &mut last).unwrap();
        }
        assert_eq!(
            out,
            b"\x1b]9;9;C:\\A\x1b\\\x1b]9;9;D:\\B\x1b\\\x1b]9;9;D:\\B\x1b\\"
        );
    }

    #[test]
    fn refuses_empty_and_control_character_payloads() {
        for cwd in [
            "",
            "C:\\bad\x1b]0;injected",
            "C:\\bad\x07",
            "C:\\bad\n",
            "C:\\bad\u{009c}",
        ] {
            let mut out = Vec::new();
            emit_host_cwd(&mut out, Some(cwd), &mut None).unwrap();
            assert!(out.is_empty());
        }
    }

    #[test]
    fn failed_write_does_not_advance_cache() {
        let mut last = None;
        let mut out = io::Cursor::new([0u8; 0]);
        assert!(emit_host_cwd(&mut out, Some(r"C:\A"), &mut last).is_err());
        assert_eq!(last, None);
    }
}
