// Issue #426: split-pane / splitp are tmux default command-aliases for
// split-window. psmux was missing them, so `psmux split-pane` errored with
// "unknown command" and Claude Code agent-team / manual claude panes fell
// back to a bare PowerShell prompt. These tests prove the command-prompt
// parse path (parse_command_to_action) treats the aliases exactly like
// split-window across the bare, -h, and command-argument forms.

use super::*;

#[test]
fn split_pane_bare_maps_to_split_vertical() {
    // Bare split-window is a vertical split; split-pane must match.
    assert!(matches!(parse_command_to_action("split-window"), Some(Action::SplitVertical)));
    assert!(matches!(parse_command_to_action("split-pane"),   Some(Action::SplitVertical)));
    assert!(matches!(parse_command_to_action("splitp"),       Some(Action::SplitVertical)));
}

#[test]
fn split_pane_dash_h_maps_to_split_horizontal() {
    assert!(matches!(parse_command_to_action("split-window -h"), Some(Action::SplitHorizontal)));
    assert!(matches!(parse_command_to_action("split-pane -h"),   Some(Action::SplitHorizontal)));
    assert!(matches!(parse_command_to_action("splitp -h"),       Some(Action::SplitHorizontal)));
}

#[test]
fn split_pane_with_command_preserves_full_string() {
    // Extra args (a shell command, -c, -d, -P ...) must be preserved verbatim
    // as Action::Command so the alias behaves identically to split-window.
    match parse_command_to_action("split-pane -h -P -F #{pane_id}") {
        Some(Action::Command(s)) => assert_eq!(s, "split-pane -h -P -F #{pane_id}"),
        _ => panic!("expected Action::Command for split-pane with extra args"),
    }
    match parse_command_to_action("splitp -c C:/tmp claude") {
        Some(Action::Command(s)) => assert_eq!(s, "splitp -c C:/tmp claude"),
        _ => panic!("expected Action::Command for splitp with a command argument"),
    }
    // Parity check: split-window with the same extras behaves the same way.
    match parse_command_to_action("split-window -h -P -F #{pane_id}") {
        Some(Action::Command(_)) => {}
        _ => panic!("split-window baseline changed"),
    }
}
