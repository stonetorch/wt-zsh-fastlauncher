// Issue #361: OSC 8 hyperlink support in the vt100-psmux parser.
// Verifies that an OSC 8 sequence sets a per-cell hyperlink id that resolves to
// the URI via the screen's hyperlink store, and that the link closes correctly.
use crate::Parser;

#[test]
fn osc8_st_terminated_sets_cell_hyperlink() {
    let mut p: Parser = Parser::new(5, 40, 0);
    // OSC 8 ; ; https://example.com ST  "Link"  OSC 8 ; ; ST
    p.process(b"\x1b]8;;https://example.com\x1b\\Link\x1b]8;;\x1b\\");
    let s = p.screen();
    for col in 0..4u16 {
        let cell = s.cell(0, col).expect("cell exists");
        let id = cell.hyperlink_id();
        assert_ne!(id, 0, "cell {col} should carry a hyperlink id");
        assert_eq!(s.hyperlink_uri(id), Some("https://example.com"));
    }
    // The cell after the closed link must have no hyperlink.
    if let Some(c) = s.cell(0, 4) {
        assert_eq!(c.hyperlink_id(), 0, "cell after close has no link");
    }
}

#[test]
fn osc8_bel_terminated() {
    let mut p: Parser = Parser::new(5, 40, 0);
    p.process(b"\x1b]8;;https://a.test\x07X\x1b]8;;\x07");
    let s = p.screen();
    let c = s.cell(0, 0).unwrap();
    assert_eq!(s.hyperlink_uri(c.hyperlink_id()), Some("https://a.test"));
}

#[test]
fn osc8_uri_with_semicolon_is_rejoined() {
    let mut p: Parser = Parser::new(5, 60, 0);
    p.process(b"\x1b]8;;https://x.test/a?b=1;c=2\x1b\\Y\x1b]8;;\x1b\\");
    let s = p.screen();
    let c = s.cell(0, 0).unwrap();
    assert_eq!(s.hyperlink_uri(c.hyperlink_id()), Some("https://x.test/a?b=1;c=2"));
}

#[test]
fn osc8_with_id_param_keys_on_uri() {
    let mut p: Parser = Parser::new(5, 40, 0);
    p.process(b"\x1b]8;id=foo;https://id.test\x1b\\Z\x1b]8;;\x1b\\");
    let s = p.screen();
    let c = s.cell(0, 0).unwrap();
    assert_eq!(s.hyperlink_uri(c.hyperlink_id()), Some("https://id.test"));
}

#[test]
fn osc8_dedups_same_uri_to_one_id() {
    let mut p: Parser = Parser::new(5, 40, 0);
    p.process(b"\x1b]8;;u://1\x1b\\A\x1b]8;;\x1b\\ \x1b]8;;u://1\x1b\\B\x1b]8;;\x1b\\");
    let s = p.screen();
    let a = s.cell(0, 0).unwrap().hyperlink_id();
    let b = s.cell(0, 2).unwrap().hyperlink_id();
    assert_ne!(a, 0);
    assert_eq!(a, b, "the same URI should reuse one hyperlink id");
}

#[test]
fn no_osc8_means_no_hyperlink() {
    let mut p: Parser = Parser::new(5, 40, 0);
    p.process(b"plain text");
    let s = p.screen();
    assert_eq!(s.cell(0, 0).unwrap().hyperlink_id(), 0);
}
