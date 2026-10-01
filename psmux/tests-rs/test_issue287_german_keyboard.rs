// Tests for issue #287: German/foreign keyboard AltGr key normalization
// Verifies that normalize_key_for_binding strips Ctrl+Alt (AltGr) from
// non-lowercase-letter Char events on Windows so that bindings like `[`,
// `]`, `@`, `\` work on German/Czech/etc. keyboards.

use crossterm::event::{KeyCode, KeyModifiers};

#[test]
fn altgr_bracket_normalized_to_plain() {
    // German AltGr+8 produces '[' with Ctrl+Alt modifiers
    let key = (KeyCode::Char('['), KeyModifiers::CONTROL | KeyModifiers::ALT);
    let norm = super::normalize_key_for_binding(key);
    assert_eq!(
        norm,
        (KeyCode::Char('['), KeyModifiers::NONE),
        "AltGr+8 ([) should normalize to plain '[' for binding lookup"
    );
}

#[test]
fn altgr_close_bracket_normalized_to_plain() {
    // German AltGr+9 produces ']' with Ctrl+Alt modifiers
    let key = (KeyCode::Char(']'), KeyModifiers::CONTROL | KeyModifiers::ALT);
    let norm = super::normalize_key_for_binding(key);
    assert_eq!(
        norm,
        (KeyCode::Char(']'), KeyModifiers::NONE),
        "AltGr+9 (]) should normalize to plain ']'"
    );
}

#[test]
fn altgr_curly_braces_normalized() {
    // German AltGr+7 = '{', AltGr+0 = '}'
    for ch in ['{', '}'] {
        let key = (KeyCode::Char(ch), KeyModifiers::CONTROL | KeyModifiers::ALT);
        let norm = super::normalize_key_for_binding(key);
        assert_eq!(
            norm,
            (KeyCode::Char(ch), KeyModifiers::NONE),
            "AltGr-produced '{}' should normalize to plain", ch
        );
    }
}

#[test]
fn altgr_at_sign_normalized() {
    // German AltGr+Q = '@'
    let key = (KeyCode::Char('@'), KeyModifiers::CONTROL | KeyModifiers::ALT);
    let norm = super::normalize_key_for_binding(key);
    assert_eq!(
        norm,
        (KeyCode::Char('@'), KeyModifiers::NONE),
        "AltGr-produced '@' should normalize to plain"
    );
}

#[test]
fn altgr_backslash_normalized() {
    // German AltGr+- = '\'
    let key = (KeyCode::Char('\\'), KeyModifiers::CONTROL | KeyModifiers::ALT);
    let norm = super::normalize_key_for_binding(key);
    assert_eq!(
        norm,
        (KeyCode::Char('\\'), KeyModifiers::NONE),
        "AltGr-produced backslash should normalize to plain"
    );
}

#[test]
fn altgr_pipe_normalized() {
    // German AltGr+< = '|'
    let key = (KeyCode::Char('|'), KeyModifiers::CONTROL | KeyModifiers::ALT);
    let norm = super::normalize_key_for_binding(key);
    assert_eq!(
        norm,
        (KeyCode::Char('|'), KeyModifiers::NONE),
        "AltGr-produced pipe should normalize to plain"
    );
}

#[test]
fn altgr_tilde_normalized() {
    // German AltGr++ = '~'
    let key = (KeyCode::Char('~'), KeyModifiers::CONTROL | KeyModifiers::ALT);
    let norm = super::normalize_key_for_binding(key);
    assert_eq!(
        norm,
        (KeyCode::Char('~'), KeyModifiers::NONE),
        "AltGr-produced tilde should normalize to plain"
    );
}

#[test]
fn real_ctrl_alt_lowercase_preserved() {
    // Real Ctrl+Alt+a should NOT be stripped (lowercase letter = not AltGr)
    let key = (KeyCode::Char('a'), KeyModifiers::CONTROL | KeyModifiers::ALT);
    let norm = super::normalize_key_for_binding(key);
    assert!(
        norm.1.contains(KeyModifiers::CONTROL) && norm.1.contains(KeyModifiers::ALT),
        "Real Ctrl+Alt+a should preserve modifiers, got: {:?}", norm.1
    );
}

#[test]
fn plain_char_unchanged() {
    let key = (KeyCode::Char('['), KeyModifiers::NONE);
    let norm = super::normalize_key_for_binding(key);
    assert_eq!(norm, (KeyCode::Char('['), KeyModifiers::NONE));
}

#[test]
fn shift_still_stripped() {
    let key = (KeyCode::Char('='), KeyModifiers::SHIFT);
    let norm = super::normalize_key_for_binding(key);
    assert_eq!(
        norm,
        (KeyCode::Char('='), KeyModifiers::NONE),
        "Shift should still be stripped from '='"
    );
}

#[test]
fn binding_lookup_matches_altgr_bracket() {
    // Simulate what happens in the prefix binding dispatch:
    // The registered binding is `[` -> copy-mode (stored as Char('['), NONE)
    // The incoming key from German keyboard is Char('[') with Ctrl+Alt
    // After normalization both should match
    let registered = super::normalize_key_for_binding(
        (KeyCode::Char('['), KeyModifiers::NONE)
    );
    let incoming = super::normalize_key_for_binding(
        (KeyCode::Char('['), KeyModifiers::CONTROL | KeyModifiers::ALT)
    );
    assert_eq!(
        registered, incoming,
        "Registered '[' binding should match AltGr-produced '[' after normalization"
    );
}

#[test]
fn equals_with_shift_matches_default_binding() {
    // German keyboard: = is Shift+0, so it arrives as Char('=') + SHIFT
    // The default binding is `=` -> choose-buffer (stored as Char('='), NONE)
    let registered = super::normalize_key_for_binding(
        (KeyCode::Char('='), KeyModifiers::NONE)
    );
    let incoming = super::normalize_key_for_binding(
        (KeyCode::Char('='), KeyModifiers::SHIFT)
    );
    assert_eq!(
        registered, incoming,
        "German Shift+0 (=) should match the '=' binding after normalization"
    );
}
