// Unit tests for issue #399: build_command must handle the POSIX
// `cd <dir> && env VAR=val ... <program> <args>` launch idiom that Claude Code
// agent-teams uses to spawn a teammate. Under PowerShell `env` is not a command,
// so without special handling the teammate launch dies with
// "env: The term 'env' is not recognized". detect_env_prefix_command parses the
// cd target and the env assignments out so the caller can apply them directly.

use super::*;

#[cfg(windows)]
#[test]
fn parses_cd_and_env_prefix() {
    // The exact shape Claude Code emits (quotes already stripped by psmux's
    // CLI -> server arg pipeline; claude.exe path has no spaces).
    let cmd = "cd C:\\cctest && env CLAUDECODE=1 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_CODE_SUBAGENT_MODEL=haiku C:\\Users\\me\\.local\\bin\\claude.exe --agent-id Bob@team --model haiku";
    let (cwd, sets, remainder) = detect_env_prefix_command(cmd).expect("should match env idiom");
    assert_eq!(cwd.as_deref(), Some("C:\\cctest"), "cd target becomes cwd override");
    assert_eq!(sets, vec![
        ("CLAUDECODE".to_string(), "1".to_string()),
        ("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS".to_string(), "1".to_string()),
        ("CLAUDE_CODE_SUBAGENT_MODEL".to_string(), "haiku".to_string()),
    ], "all env assignments are parsed");
    assert_eq!(remainder, "C:\\Users\\me\\.local\\bin\\claude.exe --agent-id Bob@team --model haiku",
        "the program + args remain, with the env prefix removed");
    assert!(!remainder.contains("env "), "the `env` token must be stripped");
}

#[cfg(windows)]
#[test]
fn parses_env_prefix_without_cd() {
    let cmd = "env FOO=bar BAZ=qux C:\\tools\\app.exe --flag";
    let (cwd, sets, remainder) = detect_env_prefix_command(cmd).expect("should match");
    assert!(cwd.is_none(), "no cd -> no cwd override");
    assert_eq!(sets, vec![("FOO".to_string(), "bar".to_string()), ("BAZ".to_string(), "qux".to_string())]);
    assert_eq!(remainder, "C:\\tools\\app.exe --flag");
}

#[cfg(windows)]
#[test]
fn strips_quotes_from_cd_target_and_values() {
    let cmd = "cd 'C:\\path with cd' && env K='v' C:\\a.exe";
    let (cwd, sets, remainder) = detect_env_prefix_command(cmd).expect("should match");
    assert_eq!(cwd.as_deref(), Some("C:\\path with cd"));
    assert_eq!(sets, vec![("K".to_string(), "v".to_string())]);
    assert_eq!(remainder, "C:\\a.exe");
}

#[cfg(windows)]
#[test]
fn non_env_commands_are_not_matched() {
    // Plain commands, bash-c wrappers, and shell one-liners must NOT be treated
    // as the env idiom (they are handled by their own paths).
    assert!(detect_env_prefix_command("pwsh -NoLogo -Command foo").is_none());
    assert!(detect_env_prefix_command("cd C:\\x && cmd /c echo hi").is_none(), "cd without env is not this idiom");
    assert!(detect_env_prefix_command("node app.js").is_none());
    assert!(detect_env_prefix_command("claude --version").is_none());
}

#[cfg(windows)]
#[test]
fn env_with_no_program_is_rejected() {
    // `env VAR=val` with nothing after it is not a runnable command.
    assert!(detect_env_prefix_command("env FOO=bar").is_none());
    assert!(detect_env_prefix_command("cd C:\\x && env FOO=bar").is_none());
}

#[cfg(windows)]
#[test]
fn build_command_env_idiom_does_not_leak_env_token() {
    // End to end at the build_command level: the resulting pwsh -Command argument
    // must invoke the program (via the `&` call operator) and must NOT contain a
    // bare `env ` prefix that PowerShell would fail on.
    let builder = build_command(
        Some("cd C:\\cctest && env CLAUDECODE=1 C:\\Users\\me\\.local\\bin\\claude.exe --agent-id Bob@team"),
        false,
        false,
    );
    let args: Vec<String> = builder.get_argv().iter().map(|s| s.to_string_lossy().to_string()).collect();
    let joined = args.join(" ");
    assert!(joined.contains("claude.exe"), "the program must be present, got: {joined}");
    assert!(joined.contains("& "), "the pwsh call operator must invoke the program, got: {joined}");
    // The literal `env ` launcher prefix must be gone (env is applied on the builder).
    assert!(!joined.contains("env CLAUDECODE"), "the env prefix must be stripped, got: {joined}");
}
