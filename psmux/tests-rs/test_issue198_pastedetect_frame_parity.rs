// Regression test for issue #198 (paste-detection off still pastes on Ctrl+V).
//
// ROOT CAUSE (proven via live wezterm repro + client-side trace):
// The server emits dump-state frames from TWO inline serializers in
// src/server/mod.rs:
//   1. the client-polled dump-state handler, and
//   2. the event-driven server-push frame builder.
// The push-frame builder was MISSING the `paste_detection` field. The
// client's DumpState deserializes a missing `paste_detection` to its serde
// default (`true`). The two frame sources alternate, so `paste_detection`
// on the client flip-flopped between the correct `false` (polled frame) and
// the wrong `true` (push frame). Whichever frame arrived last before a
// Ctrl+V keypress won, so with paste-detection OFF the client still read the
// clipboard and injected it (send-paste) instead of forwarding raw C-v.
//
// FIX: add `"paste_detection":{}` to the push-frame builder so both frame
// sources carry the field.
//
// This test guards against ANY dump-state frame builder dropping the field
// again: every inline frame serializer (identified by the `"layout":`
// frame prefix) MUST include `"paste_detection":`.

#[test]
fn every_dump_state_frame_builder_includes_paste_detection() {
    // Read the server source at compile time so the test has no runtime deps.
    let src = include_str!("../src/server/mod.rs");

    // Each full dump-state frame begins with the literal `{"layout":` prefix
    // in a format-string passed to write_fmt. Count those frame builders and
    // ensure each one also serializes the paste_detection field.
    let frame_marker = r#"{\"layout\":"#;
    let pd_field = r#"\"paste_detection\":"#;

    let frame_builders = src.matches(frame_marker).count();
    let pd_occurrences = src.matches(pd_field).count();

    assert!(
        frame_builders >= 2,
        "expected at least 2 dump-state frame builders in server/mod.rs, found {}",
        frame_builders
    );

    assert_eq!(
        frame_builders, pd_occurrences,
        "every dump-state frame builder must serialize \"paste_detection\": \
         found {} frame builders but {} paste_detection fields. A frame \
         builder that omits paste_detection makes the client default it to \
         true, re-introducing issue #198 (Ctrl+V pastes even when \
         paste-detection is off).",
        frame_builders, pd_occurrences
    );
}
