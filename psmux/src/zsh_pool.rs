//! Native MSYS2 Zsh session allocator. OSC 2 idle/busy markers opt shells in.
use crate::types::{AppState, Mode, Node};
use base64::Engine;
use std::{
    env,
    fs::{File, OpenOptions},
    io,
    path::{Path, PathBuf},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub(crate) struct Reservation {
    _file: File,
    #[cfg(not(windows))]
    path: PathBuf,
}

impl Reservation {
    fn acquire(path: &Path) -> io::Result<Option<Self>> {
        let mut options = OpenOptions::new();
        options.read(true).write(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            // The kernel releases this exclusive handle on crash. Keep the
            // tiny file, so no unlink/recreate gap can allow two claimants.
            options.create(true).truncate(false).share_mode(0);
        }
        #[cfg(not(windows))]
        options.create_new(true);
        match options.open(path) {
            Ok(file) => Ok(Some(Self {
                _file: file,
                #[cfg(not(windows))]
                path: path.to_owned(),
            })),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists || e.raw_os_error() == Some(32) => {
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }
}

#[cfg(not(windows))]
impl Drop for Reservation {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

pub(crate) struct Prepared {
    pub args: Vec<String>,
    pub reservation: Option<Reservation>,
}

fn parse_cwd(args: &[String]) -> io::Result<PathBuf> {
    let path = match args {
        [] => env::current_dir()?,
        [flag, path] if flag == "-c" => PathBuf::from(path),
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "usage: psmux [-L namespace] zsh-pool [-c directory]",
            ))
        }
    };
    let path = if path.is_absolute() {
        path
    } else {
        env::current_dir()?.join(path)
    };
    if !path.is_dir() || !crate::host_cwd::valid_cwd(&path.to_string_lossy()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "zsh-pool cwd must be an existing directory without control characters",
        ));
    }
    // Resolve . / .. and junctions before comparing the shell's confirmed cwd.
    // canonicalize on Windows returns an extended path; OSC reports normal
    // drive/UNC syntax, so remove only that transport prefix.
    let canonical = std::fs::canonicalize(path)?;
    #[cfg(windows)]
    {
        let canonical = canonical.to_string_lossy();
        if let Some(rest) = canonical.strip_prefix(r"\\?\UNC\") {
            return Ok(PathBuf::from(format!(r"\\{rest}")));
        }
        if let Some(rest) = canonical.strip_prefix(r"\\?\") {
            return Ok(PathBuf::from(rest));
        }
    }
    Ok(canonical)
}

pub(crate) fn windows_path_to_msys(path: &str) -> io::Result<String> {
    let mut path = path.replace('\\', "/");
    if let Some(rest) = path.strip_prefix("//?/UNC/") {
        return Ok(format!("//{rest}"));
    }
    if let Some(rest) = path.strip_prefix("//?/") {
        path = rest.to_owned();
    }
    let bytes = path.as_bytes();
    if bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'/' {
        return Ok(format!(
            "/{}{}",
            (bytes[0] as char).to_ascii_lowercase(),
            &path[2..]
        ));
    }
    if path.starts_with("//") {
        return Ok(path);
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        "zsh-pool requires a Windows drive or UNC cwd",
    ))
}

fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

fn request(base: &str, line: &str) -> Option<String> {
    let port: u16 = std::fs::read_to_string(crate::paths::port_file(base))
        .ok()?
        .trim()
        .parse()
        .ok()?;
    let key = crate::session::read_session_key(base).ok()?;
    crate::session::fetch_authed_response(
        &format!("127.0.0.1:{port}"),
        &key,
        line.as_bytes(),
        Duration::from_millis(300),
        Duration::from_secs(2),
    )
}

pub(crate) fn prepare(args: &[String], namespace: Option<&str>) -> io::Result<Prepared> {
    let cwd = parse_cwd(args)?.to_string_lossy().into_owned();
    windows_path_to_msys(&cwd)?;
    // Preserve the launcher convention, including nested launch protection.
    for name in [
        "TMUX",
        "TMUX_PANE",
        "PSMUX_SESSION",
        "PSMUX_ACTIVE",
        "PSMUX_TARGET_SESSION",
        "PSMUX_TARGET_FULL",
    ] {
        env::remove_var(name);
    }
    let pid = std::process::id();
    let payload = base64::engine::general_purpose::STANDARD.encode(cwd.as_bytes());
    for base in crate::session::list_session_names_ns(namespace) {
        let session = namespace
            .and_then(|ns| base.strip_prefix(&format!("{ns}__")))
            .unwrap_or(&base);
        if !session.starts_with("zsh-") {
            continue;
        }
        let lock_path =
            PathBuf::from(crate::paths::psmux_dir()).join(format!("{base}.zsh-pool.lock"));
        let Some(reservation) = Reservation::acquire(&lock_path)? else {
            continue;
        };
        match request(&base, &format!("zsh-pool-claim {pid} {payload}\n")).as_deref() {
            Some("CLAIMED") => {
                let deadline = Instant::now() + Duration::from_secs(8);
                loop {
                    match request(&base, &format!("zsh-pool-ready {pid}\n")).as_deref() {
                        Some("READY") => break,
                        Some("WAIT") if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
                        _ => return Err(io::Error::other(format!("zsh-pool: claimed {session}, but Zsh did not confirm cd to {cwd}; session left intact"))),
                    }
                }
                debug(&format!("reuse {session} cwd={cwd}"));
                return Ok(Prepared {
                    args: vec!["attach-session".into(), "-t".into(), session.into()],
                    reservation: Some(reservation),
                });
            }
            Some(reply) if reply.starts_with("FAILED") => {
                return Err(io::Error::other(reply.to_owned()))
            }
            _ => {} // Busy, attached, incompatible, or stale server: leave intact.
        }
    }
    let root = env::var_os("MSYS2_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\msys64"));
    let shell = root.join("msys2_shell.cmd");
    if !shell.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "MSYS2 launcher not found: {} (set MSYS2_ROOT)",
                shell.display()
            ),
        ));
    }
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let name = format!("zsh-{pid}-{nanos}");
    let data = PathBuf::from(crate::paths::psmux_dir());
    std::fs::create_dir_all(&data)?;
    let base = namespace
        .map(|ns| format!("{ns}__{name}"))
        .unwrap_or_else(|| name.clone());
    // Reserve new sessions too: their prompt can become idle before the
    // creating client registers its attach, so another launch must skip them.
    let reservation = Reservation::acquire(&data.join(format!("{base}.zsh-pool.lock")))?
        .ok_or_else(|| io::Error::other("zsh-pool: new session reservation collision"))?;
    debug(&format!("create {name} cwd={cwd}"));
    Ok(Prepared {
        args: vec![
            "new-session".into(),
            "-s".into(),
            name,
            "-c".into(),
            cwd,
            "--".into(),
            "cmd.exe".into(),
            "/d".into(),
            "/c".into(),
            shell.to_string_lossy().into_owned(),
            "-defterm".into(),
            "-ucrt64".into(),
            "-no-start".into(),
            "-here".into(),
            "-use-full-path".into(),
            "-shell".into(),
            "zsh".into(),
        ],
        reservation: Some(reservation),
    })
}

fn debug(message: &str) {
    if env::var_os("PSMUX_ZSH_DEBUG").is_some() {
        eprintln!("[psmux zsh-pool] {message}");
    }
}

pub(crate) struct Claim {
    pid: u32,
    cwd: String,
    version: u64,
}

fn idle_pane(app: &AppState) -> Option<&crate::types::Pane> {
    if !app.session_name.starts_with("zsh-")
        || app.attached_clients != 0
        || app.windows.len() != 1
        || !matches!(app.mode, Mode::Passthrough)
    {
        return None;
    }
    let win = &app.windows[0];
    if !win.floating.is_empty() {
        return None;
    }
    let Node::Leaf(pane) = &win.root else {
        return None;
    };
    if pane.dead {
        return None;
    }
    let term = pane.term.lock().ok()?;
    if term.screen().title() != "zsh-idle" || term.screen().alternate_screen() {
        return None;
    }
    Some(pane)
}

/// Validate and inject in the single server event-loop turn. No list/target race.
pub(crate) fn claim(app: &mut AppState, lease: &mut Option<Claim>, pid: u32, cwd: &str) -> String {
    if lease
        .as_ref()
        .is_some_and(|c| crate::platform::process_is_alive(c.pid))
    {
        return "SKIP\n".into();
    }
    let Some(pane) = idle_pane(app) else {
        return "SKIP\n".into();
    };
    let version = pane.data_version.load(std::sync::atomic::Ordering::Relaxed);
    if !crate::host_cwd::valid_cwd(cwd) || !Path::new(cwd).is_dir() {
        return "FAILED invalid cwd\n".into();
    }
    let Ok(msys) = windows_path_to_msys(cwd) else {
        return "FAILED unsupported cwd\n".into();
    };
    *lease = Some(Claim {
        pid,
        cwd: cwd.into(),
        version,
    });
    app.active_idx = 0;
    app.windows[0].active_path.clear();
    let command = format!("builtin cd -- {} && clear", shell_quote(&msys));
    let result = crate::input::send_paste_to_active(app, &command)
        .and_then(|_| crate::input::send_key_to_active(app, "enter"));
    match result {
        Ok(()) => "CLAIMED\n".into(),
        Err(e) => format!("FAILED pool input: {e}\n"),
    }
}

pub(crate) fn ready(app: &AppState, lease: Option<&Claim>, pid: u32) -> String {
    let Some(lease) = lease.filter(|c| c.pid == pid) else {
        return "FAILED no pool claim\n".into();
    };
    let Some(pane) = idle_pane(app) else {
        return "WAIT\n".into();
    };
    let announced = pane
        .term
        .lock()
        .ok()
        .and_then(|t| t.screen().path().map(str::to_owned));
    let current = announced
        .as_deref()
        .and_then(|p| crate::wsl_path::osc_cwd_to_windows(p, None))
        .unwrap_or_else(|| crate::format::expand_format("#{pane_current_path}", app));
    if pane.data_version.load(std::sync::atomic::Ordering::Relaxed) > lease.version
        && crate::util::same_dir(&current, &lease.cwd)
    {
        "READY\n".into()
    } else {
        "WAIT\n".into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pool_paths_and_shell_quoting() {
        assert_eq!(
            windows_path_to_msys(r"D:\测试 dir\it's").unwrap(),
            "/d/测试 dir/it's"
        );
        assert_eq!(windows_path_to_msys(r"\\?\C:\dir").unwrap(), "/c/dir");
        assert_eq!(
            windows_path_to_msys(r"\\?\UNC\host\share").unwrap(),
            "//host/share"
        );
        assert_eq!(shell_quote("it's $HOME;`cmd`"), "'it'\\''s $HOME;`cmd`'");
        assert!(windows_path_to_msys("C:relative").is_err());
    }
    #[test]
    fn pool_arguments_reject_extra_and_missing_values() {
        for args in [
            vec!["-c".into()],
            vec!["extra".into()],
            vec!["--unknown".into()],
        ] {
            assert!(parse_cwd(&args).is_err());
        }
        assert!(parse_cwd(&[]).unwrap().is_dir());
        assert_eq!(
            parse_cwd(&["-c".into(), ".".into()]).unwrap(),
            parse_cwd(&[]).unwrap()
        );
    }
    #[cfg(windows)]
    #[test]
    fn pool_reservation_is_exclusive_and_released_on_drop() {
        let path = env::temp_dir().join(format!("psmux-pool-lock-{}.test", std::process::id()));
        let first = Reservation::acquire(&path).unwrap().unwrap();
        assert!(Reservation::acquire(&path).unwrap().is_none());
        drop(first);
        drop(Reservation::acquire(&path).unwrap().unwrap());
        std::fs::remove_file(path).unwrap();
    }
}
