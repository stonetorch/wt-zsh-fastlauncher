use std::env;
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};
use std::time::{SystemTime, UNIX_EPOCH};

const PANE_FORMAT: &str =
    "#{session_name}|#{session_attached}|#{pane_id}|#{pane_title}|#{pane_dead}";

#[derive(Debug)]
struct Pane {
    session: String,
    pane_id: String,
}

fn main() {
    if let Err(err) = run() {
        eprintln!("wt-zsh-fastlauncher: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let psmux = find_psmux();
    let msys_root = env::var_os("MSYS2_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\msys64"));
    let msys_shell = msys_root.join("msys2_shell.cmd");

    if !msys_shell.is_file() {
        return Err(format!(
            "MSYS2 launcher not found: {} (set MSYS2_ROOT if MSYS2 is elsewhere)",
            msys_shell.display()
        )
        .into());
    }

    let target_win = env::current_dir()?;
    let target_msys = windows_path_to_msys(&target_win)?;

    debug(format!("psmux      = {}", psmux.to_string_lossy()));
    debug(format!("target win = {}", target_win.display()));
    debug(format!("target msys= {target_msys}"));

    if let Some(pane) = find_idle_pane(&psmux)? {
        debug(format!("reuse {} {}", pane.session, pane.pane_id));

        // "builtin cd" bypasses zoxide's cd wrapper.
        let cd_command = format!("builtin cd -- {} && clear", shell_quote(&target_msys));
        inject_command(&psmux, &pane.pane_id, &cd_command)?;

        let status = psmux_command(&psmux)
            .arg("attach")
            .arg("-t")
            .arg(&pane.session)
            .status()?;

        exit_with(status);
    }

    let session = unique_session_name();
    debug(format!("create {session}"));

    // No reusable zsh exists. Create + attach in one psmux invocation,
    // avoiding a separate new-session -> attach round trip.
    let status = psmux_command(&psmux)
        .arg("new-session")
        .arg("-s")
        .arg(&session)
        .arg("-c")
        .arg(&target_win)
        .arg("--")
        .arg("cmd.exe")
        .arg("/d")
        .arg("/c")
        .arg(&msys_shell)
        .args([
            "-defterm",
            "-ucrt64",
            "-no-start",
            "-here",
            "-use-full-path",
            "-shell",
            "zsh",
        ])
        .status()?;

    exit_with(status);
}

fn find_idle_pane(psmux: &OsStr) -> Result<Option<Pane>, Box<dyn Error>> {
    // One psmux call scans every pane in every session.
    let output = psmux_command(psmux)
        .args(["list-panes", "-a", "-F", PANE_FORMAT])
        .output()?;

    // "No server" / "no sessions" just means we create a fresh session.
    if !output.status.success() {
        debug(format!(
            "list-panes returned {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
        return Ok(None);
    }

    let stdout = String::from_utf8(output.stdout)?;
    for line in stdout.lines() {
        let mut fields = line.splitn(5, '|');
        let Some(session) = fields.next() else { continue };
        let Some(attached) = fields.next() else { continue };
        let Some(pane_id) = fields.next() else { continue };
        let Some(title) = fields.next() else { continue };
        let Some(dead) = fields.next() else { continue };

        if session.starts_with("zsh-")
            && attached == "0"
            && dead == "0"
            && title == "zsh-idle"
        {
            return Ok(Some(Pane {
                session: session.to_owned(),
                pane_id: pane_id.to_owned(),
            }));
        }
    }

    Ok(None)
}

fn inject_command(psmux: &OsStr, pane_id: &str, command: &str) -> Result<(), Box<dyn Error>> {
    let payload = base64_encode(command.as_bytes());

    // send-paste accepts exactly one positional Base64 payload.
    // Do NOT append a tmux-style command separator here: the CLI parser would
    // treat it as another positional argument to send-paste.
    //
    // send-paste transports UTF-8 as Base64, so Chinese paths and shell
    // punctuation do not pass through a Windows code page.
    let paste_status = psmux_command(psmux)
        .arg("send-paste")
        .arg("-t")
        .arg(pane_id)
        .arg(payload)
        .status()?;

    if !paste_status.success() {
        return Err(format!(
            "failed to paste cd command to pane {pane_id}: {paste_status}"
        )
        .into());
    }

    let enter_status = psmux_command(psmux)
        .arg("send-keys")
        .arg("-t")
        .arg(pane_id)
        .arg("Enter")
        .status()?;

    if !enter_status.success() {
        return Err(format!(
            "failed to press Enter in pane {pane_id}: {enter_status}"
        )
        .into());
    }

    Ok(())
}

fn psmux_command(psmux: &OsStr) -> Command {
    let mut cmd = Command::new(psmux);

    // If the launcher is ever invoked from a psmux pane, prevent inherited
    // nesting markers from confusing these controller subprocesses.
    for name in [
        "TMUX",
        "TMUX_PANE",
        "PSMUX_SESSION",
        "PSMUX_ACTIVE",
        "PSMUX_TARGET_SESSION",
        "PSMUX_TARGET_FULL",
    ] {
        cmd.env_remove(name);
    }

    cmd
}

fn find_psmux() -> OsString {
    if let Some(path) = env::var_os("PSMUX_EXE") {
        return path;
    }

    // Prefer the installed copy (the one containing unreleased fixes).
    if let Some(local) = env::var_os("LOCALAPPDATA") {
        let installed = PathBuf::from(local).join(r"psmux\psmux.exe");
        if installed.is_file() {
            return installed.into_os_string();
        }
    }

    OsString::from("psmux.exe")
}

fn windows_path_to_msys(path: &Path) -> Result<String, Box<dyn Error>> {
    // Stay entirely inside Rust Unicode strings; do not call cygpath, avoiding
    // PowerShell/console code-page corruption such as 前沿 -> 鍓嶆部.
    let mut s = path.as_os_str().to_string_lossy().replace('\\', "/");

    // Extended-length UNC: \\?\UNC\server\share -> //server/share
    if let Some(rest) = s.strip_prefix("//?/UNC/") {
        return Ok(format!("//{rest}"));
    }

    // Extended-length drive path: \\?\C:\x -> C:/x
    if let Some(rest) = s.strip_prefix("//?/") {
        s = rest.to_owned();
    }

    let bytes = s.as_bytes();
    if bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic() {
        let drive = (bytes[0] as char).to_ascii_lowercase();
        let rest = &s[2..];
        return Ok(format!("/{drive}{rest}"));
    }

    if s.starts_with("//") || s.starts_with('/') {
        return Ok(s);
    }

    Err(format!("unsupported working directory: {}", path.display()).into())
}

fn shell_quote(s: &str) -> String {
    // POSIX/zsh single-quote escaping:
    //   abc'def -> 'abc'\''def'
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn unique_session_name() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("zsh-{}-{millis}", std::process::id())
}

fn exit_with(status: ExitStatus) -> ! {
    std::process::exit(status.code().unwrap_or(1));
}

fn debug(message: String) {
    if env::var_os("PSMUX_ZSH_DEBUG").is_some() {
        eprintln!("[wt-zsh-fastlauncher] {message}");
    }
}

// Tiny dependency-free Base64 encoder for psmux send-paste.
fn base64_encode(input: &[u8]) -> String {
    const TABLE: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    let mut out = String::with_capacity(((input.len() + 2) / 3) * 4);
    let mut i = 0;

    while i + 3 <= input.len() {
        let n = ((input[i] as u32) << 16)
            | ((input[i + 1] as u32) << 8)
            | input[i + 2] as u32;
        out.push(TABLE[((n >> 18) & 0x3f) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3f) as usize] as char);
        out.push(TABLE[((n >> 6) & 0x3f) as usize] as char);
        out.push(TABLE[(n & 0x3f) as usize] as char);
        i += 3;
    }

    match input.len() - i {
        1 => {
            let n = (input[i] as u32) << 16;
            out.push(TABLE[((n >> 18) & 0x3f) as usize] as char);
            out.push(TABLE[((n >> 12) & 0x3f) as usize] as char);
            out.push('=');
            out.push('=');
        }
        2 => {
            let n = ((input[i] as u32) << 16) | ((input[i + 1] as u32) << 8);
            out.push(TABLE[((n >> 18) & 0x3f) as usize] as char);
            out.push(TABLE[((n >> 12) & 0x3f) as usize] as char);
            out.push(TABLE[((n >> 6) & 0x3f) as usize] as char);
            out.push('=');
        }
        _ => {}
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_known_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(
            base64_encode("前沿应用作业".as_bytes()),
            "5YmN5rK/5bqU55So5L2c5Lia"
        );
    }

    #[test]
    fn quote_single_quotes() {
        assert_eq!(shell_quote("abc"), "'abc'");
        assert_eq!(shell_quote("a'b"), "'a'\\''b'");
    }
}
