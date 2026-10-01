// Issue #88 — vt100-level proof of the copy-on-exit alt-screen
// preservation.  Plan B in the design discussion: rather than try
// to drop ConPTY's alt-screen mode (which it simulates with cursor
// + erase-line + content-restore sequences regardless), we let alt
// mode work normally and copy the alt grid's visible content into
// main scrollback at exit.  Net result: capture-pane -S can see
// the last-seen TUI screen.

use super::*;

/// Default behaviour: 1049 toggles work normally and alt content is
/// ephemeral.  This pins the legacy semantics so a future change can
/// not silently start preserving every TUI's content into scrollback.
#[test]
fn default_does_not_preserve_alt_into_scrollback() {
    let mut p = vt100::Parser::new(4, 20, 2000);
    assert!(p.screen().allow_alternate_screen());

    p.process(b"M\r\n");
    p.process(b"\x1b[?1049h");
    assert!(p.screen().alternate_screen());
    p.process(b"A1\r\nA2\r\n");
    p.process(b"\x1b[?1049l");
    assert!(!p.screen().alternate_screen());

    let c = p.screen().contents();
    assert!(c.contains('M'), "M survives on main: {c:?}");
    // Visible after exit is the main grid; alt content gone.
    assert!(!c.contains("A1"), "default off: A1 should not be visible");
}

/// With the option turned off, the alt grid's visible rows are
/// copied into main scrollback at the moment of exit.
#[test]
fn off_preserves_alt_visible_into_main_scrollback() {
    // 4 rows tall so we can confirm the alt content shows up in
    // scrollback (above the visible main rows).
    let mut p = vt100::Parser::new(4, 20, 2000);
    p.screen_mut().set_allow_alternate_screen(false);

    // Main grid has 'M' on a line, then enter alt and write A1, A2.
    p.process(b"M\r\n");
    p.process(b"\x1b[?1049h");
    p.process(b"A1\r\nA2\r\n");
    p.process(b"\x1b[?1049l");

    // After exit, the alt visible rows ('A1', 'A2') should now be in
    // main grid's scrollback.  Main visible is back to pre-alt state.
    let mut full = String::new();
    let main_grid = p.screen();
    // Rendering "everything in scrollback + visible" is what
    // capture-pane -S does.  Cheapest test: scroll the parser back to
    // the top and ask for visible rows.
    let total = main_grid.scrollback_filled();
    assert!(
        total >= 2,
        "expected at least 2 rows in scrollback after alt exit, got {total}"
    );
    p.screen_mut().set_scrollback(total);
    let snap = p.screen().contents();
    full.push_str(&snap);
    assert!(full.contains("A1"), "A1 must land in scrollback: {full:?}");
    assert!(full.contains("A2"), "A2 must land in scrollback: {full:?}");
}

/// The copy must not include trailing blank rows.  Otherwise a TUI
/// that didn't fill the alt screen would leave dozens of empty lines
/// of clutter in scrollback every time the user invokes it.
#[test]
fn off_skips_trailing_blanks() {
    let mut p = vt100::Parser::new(8, 20, 2000);
    p.screen_mut().set_allow_alternate_screen(false);

    p.process(b"\x1b[?1049h");
    p.process(b"X\r\n");                // one row of content, 7 blanks below
    p.process(b"\x1b[?1049l");

    let filled = p.screen().scrollback_filled();
    assert_eq!(
        filled, 1,
        "exactly one non-blank row should land in scrollback (got {filled})"
    );
}

/// Toggling the option ON after content was already copied must NOT
/// retroactively delete that scrollback content.
#[test]
fn toggling_back_to_on_keeps_previously_copied_content() {
    let mut p = vt100::Parser::new(4, 20, 2000);
    p.screen_mut().set_allow_alternate_screen(false);

    p.process(b"\x1b[?1049h");
    p.process(b"K\r\n");
    p.process(b"\x1b[?1049l");
    assert_eq!(p.screen().scrollback_filled(), 1);

    // Re-enable.  Future alt sessions will not be preserved, but
    // existing scrollback content is unaffected.
    p.screen_mut().set_allow_alternate_screen(true);
    assert_eq!(p.screen().scrollback_filled(), 1);
}

/// If the user flips the option off WHILE a TUI is currently in alt
/// mode, the visible alt frame is copied into main scrollback right
/// then — otherwise the user would lose the current screen if they
/// changed the setting mid-session.
#[test]
fn flipping_off_while_in_alt_flushes_visible_now() {
    let mut p = vt100::Parser::new(4, 20, 2000);
    // Default on.
    p.process(b"\x1b[?1049h");
    p.process(b"L1\r\nL2\r\n");
    assert!(p.screen().alternate_screen());
    assert_eq!(p.screen().scrollback_filled(), 0);

    // Flip off mid-alt.
    p.screen_mut().set_allow_alternate_screen(false);
    let filled = p.screen().scrollback_filled();
    assert!(
        filled >= 2,
        "mid-alt flip should flush visible rows; filled={filled}"
    );
}

/// Sanity: the new push helper respects scrollback_len = 0.
#[test]
fn push_row_to_scrollback_respects_zero_cap() {
    let mut p = vt100::Parser::new(2, 10, 0);
    p.screen_mut().set_allow_alternate_screen(false);
    p.process(b"\x1b[?1049h");
    p.process(b"Z\r\n");
    p.process(b"\x1b[?1049l");
    // No scrollback at all — nothing should land.
    assert_eq!(p.screen().scrollback_filled(), 0);
}
