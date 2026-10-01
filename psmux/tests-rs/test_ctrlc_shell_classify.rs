// Unit coverage for the Ctrl+C foreground classifier (issue: Ctrl+C kills
// raw-mode TUI apps like Copilot CLI instead of letting them handle the key).
//
// `is_shell_exe` decides whether a pane's foreground process expects a console
// CTRL_C_EVENT (shells) or should instead receive raw 0x03 and handle Ctrl+C
// itself (live raw-mode TUIs).  Misclassifying a TUI as a shell reintroduces
// the bug, so lock the classification down here.

use super::process_info::is_shell_exe;

#[test]
fn shells_are_classified_as_shell() {
    for s in [
        "pwsh.exe", "pwsh", "powershell.exe", "powershell",
        "cmd.exe", "cmd", "bash", "bash.exe", "sh", "dash",
        "zsh", "fish.exe", "nu.exe", "busybox.exe",
    ] {
        assert!(is_shell_exe(s), "{s:?} should be classified as a shell");
    }
}

#[test]
fn raw_mode_tui_apps_are_not_shells() {
    // These get raw 0x03 and decide copy-vs-interrupt themselves.
    for s in [
        "copilot.exe", "copilot", "node.exe", "node",
        "vim.exe", "nvim.exe", "nvim", "python.exe", "btop.exe",
    ] {
        assert!(!is_shell_exe(s), "{s:?} must NOT be classified as a shell");
    }
}

#[test]
fn cooked_console_app_is_not_shell() {
    // ping is a cooked console app; it leaves ENABLE_PROCESSED_INPUT ON, so it
    // still gets the signal via the processed-input branch, not via shell
    // classification.  It must not be classified as a shell.
    assert!(!is_shell_exe("ping.exe"));
}
