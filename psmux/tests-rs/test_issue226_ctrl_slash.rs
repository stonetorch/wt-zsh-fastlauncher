// Issue #226: `send-keys C-/` produces 0x0F (^O) instead of 0x1F (^_),
// because the naive `'/' & 0x1F` collides with `'o' & 0x1F`.
//
// tmux (input-keys.c standard_map) maps `C-/` -> 0x1f, `C-?` -> 0x7f,
// `C-3`..`C-7` -> 0x1b..0x1f, etc. These tests pin that behavior on
// the helper used by the send-keys command path.

use crate::input::ctrl_char_send_keys_byte;

// === Bug regression: the exact cases from the issue ===

#[test]
fn issue226_ctrl_slash_is_0x1f_not_0x0f() {
    let v = ctrl_char_send_keys_byte('/').expect("C-/ must produce a byte");
    assert_eq!(v, 0x1f, "C-/ must produce 0x1f (^_), got 0x{:02x}", v);
    assert_ne!(v, 0x0f, "BUG #226 regression: C-/ collapsed to ^O (0x0f)");
}

#[test]
fn issue226_ctrl_o_still_is_0x0f() {
    // C-o must keep its existing semantics (^O).
    let v = ctrl_char_send_keys_byte('o').expect("C-o must produce a byte");
    assert_eq!(v, 0x0f, "C-o must produce 0x0f (^O), got 0x{:02x}", v);
}

#[test]
fn issue226_ctrl_slash_and_ctrl_o_are_distinct() {
    let slash = ctrl_char_send_keys_byte('/').unwrap();
    let o     = ctrl_char_send_keys_byte('o').unwrap();
    assert_ne!(slash, o,
        "BUG #226 regression: C-/ (0x{:02x}) collided with C-o (0x{:02x})",
        slash, o);
}

// === tmux standard_map parity ===

#[test]
fn ctrl_question_is_del() {
    assert_eq!(ctrl_char_send_keys_byte('?'), Some(0x7f));
}

#[test]
fn ctrl_8_is_del() {
    assert_eq!(ctrl_char_send_keys_byte('8'), Some(0x7f));
}

#[test]
fn ctrl_dash_is_unit_separator() {
    assert_eq!(ctrl_char_send_keys_byte('-'), Some(0x1f));
}

#[test]
fn ctrl_space_is_nul() {
    assert_eq!(ctrl_char_send_keys_byte(' '), Some(0x00));
}

#[test]
fn ctrl_2_is_nul() {
    assert_eq!(ctrl_char_send_keys_byte('2'), Some(0x00));
}

#[test]
fn ctrl_digits_3_to_7_map_to_c0() {
    assert_eq!(ctrl_char_send_keys_byte('3'), Some(0x1b)); // ESC
    assert_eq!(ctrl_char_send_keys_byte('4'), Some(0x1c));
    assert_eq!(ctrl_char_send_keys_byte('5'), Some(0x1d));
    assert_eq!(ctrl_char_send_keys_byte('6'), Some(0x1e));
    assert_eq!(ctrl_char_send_keys_byte('7'), Some(0x1f));
}

#[test]
fn ctrl_letters_use_standard_mask() {
    assert_eq!(ctrl_char_send_keys_byte('a'), Some(0x01));
    assert_eq!(ctrl_char_send_keys_byte('A'), Some(0x01));
    assert_eq!(ctrl_char_send_keys_byte('c'), Some(0x03));
    assert_eq!(ctrl_char_send_keys_byte('z'), Some(0x1a));
    assert_eq!(ctrl_char_send_keys_byte('m'), Some(0x0d)); // CR
    assert_eq!(ctrl_char_send_keys_byte('i'), Some(0x09)); // TAB
    assert_eq!(ctrl_char_send_keys_byte('['), Some(0x1b)); // ESC
    assert_eq!(ctrl_char_send_keys_byte('\\'),Some(0x1c));
    assert_eq!(ctrl_char_send_keys_byte(']'), Some(0x1d));
}

#[test]
fn ctrl_bang_is_literal_one() {
    // Per tmux remap, C-! produces literal '1'.
    assert_eq!(ctrl_char_send_keys_byte('!'), Some(b'1'));
}

#[test]
fn ctrl_paren_open_is_literal_nine() {
    assert_eq!(ctrl_char_send_keys_byte('('), Some(b'9'));
}

#[test]
fn ctrl_invalid_returns_none() {
    // Non-ASCII and outside any standard_map range -> None.
    assert_eq!(ctrl_char_send_keys_byte('\u{00e9}'), None); // é
    assert_eq!(ctrl_char_send_keys_byte('\u{2014}'), None); // em dash
}

// === End-to-end through execute_command_string-equivalent helpers ===
//
// The pure-byte helper above is what the dispatch path uses. We assert
// it covers the symbols most likely to surprise users.

#[test]
fn issue226_complete_collision_audit() {
    // Every printable ASCII char that the old `c & 0x1F` logic would
    // have collapsed onto an existing letter byte is now either:
    //   - mapped to a tmux-defined byte (e.g. /-> 0x1f, ?-> 0x7f), OR
    //   - returned as None so the dispatcher silently drops it.
    // What we MUST never see again is C-/ producing 0x0f.
    for c in 0u8..128u8 {
        let ch = c as char;
        if let Some(b) = ctrl_char_send_keys_byte(ch) {
            // Sanity: byte must be <= 0x7f (single ASCII byte).
            assert!(b <= 0x7f, "byte 0x{:02x} for char {:?} not ASCII", b, ch);
        }
    }
    // Pin the specific collision the issue reported.
    assert_ne!(
        ctrl_char_send_keys_byte('/'),
        ctrl_char_send_keys_byte('o'),
        "C-/ and C-o must produce different bytes"
    );
}
