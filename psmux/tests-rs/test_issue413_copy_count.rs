// Issue #413: numeric prefixes for copy-mode-vi motions have no effect.
//
// On Windows the client forwards every plain printable key in copy mode as a
// `send-text "c"` command, which the server routes through
// `send_text_to_active` -> `handle_copy_mode_char`.  That path had NO numeric
// prefix accumulation, so "5j" moved one line instead of five.  These tests
// exercise that exact path and assert the count is accumulated (digits) and
// consumed (motions).  Digit accumulation returns before any cursor movement,
// so no real pane/terminal is required.

use super::*;

fn copy_app() -> crate::types::AppState {
    let mut app = crate::types::AppState::new("t".to_string());
    app.mode = Mode::CopyMode;
    app
}

#[test]
fn send_text_digit_sets_copy_count() {
    let mut app = copy_app();
    crate::input::send_text_to_active(&mut app, "5").unwrap();
    assert_eq!(app.copy_count, Some(5), "send-text '5' in copy mode should set copy_count=5");
}

#[test]
fn send_text_digits_accumulate() {
    let mut app = copy_app();
    // Two-digit count typed as separate send-text bursts, e.g. "10j".
    crate::input::send_text_to_active(&mut app, "1").unwrap();
    crate::input::send_text_to_active(&mut app, "0").unwrap();
    assert_eq!(app.copy_count, Some(10), "'1' then '0' should accumulate to 10 (not line-start)");
}

#[test]
fn send_text_digits_accumulate_single_burst() {
    let mut app = copy_app();
    // Whole "10" delivered in one send-text (paste-style flush).
    crate::input::send_text_to_active(&mut app, "10").unwrap();
    assert_eq!(app.copy_count, Some(10), "'10' in one burst should accumulate to 10");
}

#[test]
fn send_text_find_char_preserves_count_until_target() {
    let mut app = copy_app();
    crate::input::send_text_to_active(&mut app, "3").unwrap();
    // 'f' enters find-char pending and must keep the count for the target char.
    crate::input::send_text_to_active(&mut app, "f").unwrap();
    assert_eq!(app.copy_find_char_pending, Some(0), "'f' should arm find-char forward");
    assert_eq!(app.copy_count, Some(3), "'f' must preserve the count for the target char");
}

// NOTE: the actual cursor movement (motion consuming the count, '0' as
// line-start, find-char reaching the Nth target) requires a live pane +
// terminal and is proven end-to-end in tests/test_issue413_copy_count_vi.ps1.
