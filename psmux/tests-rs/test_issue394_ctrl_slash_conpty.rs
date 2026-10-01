// Issue #394: Ctrl+/ under ConPTY terminals (Alacritty/WezTerm) on Windows.
//
// Those terminals route input through ConPTY, which synthesizes the 0x1f byte
// (what Ctrl+/ produces) as VK_OEM_MINUS + Ctrl + Shift.  crossterm therefore
// delivers Ctrl+/ as `Char('-')` with CONTROL|SHIFT, and the client forwards it
// as the send-key name "C-S--".  Before the fix:
//   * encode_key_event mapped it with the naive `'-' & 0x1f == 0x0d` (CR), and
//   * the "C-S--" send-key name matched no arm in send_key_to_active and was
//     silently dropped.
// Either way neovim never received 0x1f, so its Ctrl+/ comment-toggle mapping
// (which fires on 0x1f == C-_ == C-/) never ran.
//
// These tests pin the byte-level contract: Ctrl+/ and Ctrl+Shift+- must both
// encode to 0x1f (^_), matching tmux and Ctrl+_.

use super::*;
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers};

fn key(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
    KeyEvent { code, modifiers, kind: KeyEventKind::Press, state: KeyEventState::NONE }
}

// === encode_key_event: the direct byte path ===

#[test]
fn ctrl_slash_encodes_to_unit_separator() {
    // Ctrl+/ (as delivered by native-path terminals) must be 0x1f, not 0x0f (^O).
    let ev = key(KeyCode::Char('/'), KeyModifiers::CONTROL);
    assert_eq!(encode_key_event(&ev).unwrap(), vec![0x1f]);
}

#[test]
fn ctrl_shift_minus_encodes_to_unit_separator() {
    // Ctrl+/ as ConPTY delivers it: Char('-') + CONTROL + SHIFT.  Must be 0x1f,
    // NOT the naive '-' & 0x1f == 0x0d (CR) that the old code produced.
    let ev = key(KeyCode::Char('-'), KeyModifiers::CONTROL | KeyModifiers::SHIFT);
    let bytes = encode_key_event(&ev).unwrap();
    assert_eq!(bytes, vec![0x1f], "Ctrl+Shift+- must be ^_ (0x1f), got {:02x?}", bytes);
    assert_ne!(bytes, vec![0x0d], "regression: Ctrl+Shift+- collapsed to CR");
}

#[test]
fn ctrl_underscore_encodes_to_unit_separator() {
    // The canonical spelling of the same byte.
    let ev = key(KeyCode::Char('_'), KeyModifiers::CONTROL);
    assert_eq!(encode_key_event(&ev).unwrap(), vec![0x1f]);
}

#[test]
fn ctrl_letters_are_unchanged_by_the_fix() {
    // Guard: Ctrl+<letter> must keep its usual control byte (a->0x01 … w->0x17).
    assert_eq!(encode_key_event(&key(KeyCode::Char('a'), KeyModifiers::CONTROL)).unwrap(), vec![0x01]);
    assert_eq!(encode_key_event(&key(KeyCode::Char('c'), KeyModifiers::CONTROL)).unwrap(), vec![0x03]);
    assert_eq!(encode_key_event(&key(KeyCode::Char('w'), KeyModifiers::CONTROL)).unwrap(), vec![0x17]);
}

// === ctrl_char_send_keys_byte parity used by the send-key dispatch arms ===

#[test]
fn dispatch_helper_maps_slash_and_minus_to_1f() {
    // Both spellings the three dispatch paths (input.rs, server/mod.rs,
    // commands.rs) rely on must yield 0x1f.
    assert_eq!(ctrl_char_send_keys_byte('/'), Some(0x1f));
    assert_eq!(ctrl_char_send_keys_byte('-'), Some(0x1f));
    assert_eq!(ctrl_char_send_keys_byte('_'), Some(0x1f));
    // And must NOT collide with C-o (^O 0x0f), the exact #226/#394 collision.
    assert_ne!(ctrl_char_send_keys_byte('/'), ctrl_char_send_keys_byte('o'));
}
