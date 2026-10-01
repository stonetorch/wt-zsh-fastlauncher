//! Isolated live server + client ConPTY test. Does not use the default registry.
//! cargo run --example verify_host_cwd -- target/release/psmux.exe
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::{
    io::Read,
    path::PathBuf,
    process::Command,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

struct Test {
    exe: PathBuf,
    data: PathBuf,
    ns: String,
}
impl Test {
    fn command(&self, args: &[&str]) -> Command {
        let mut c = Command::new(&self.exe);
        c.env("PSMUX_DATA_DIR", &self.data)
            .env("PSMUX_NO_WARM", "1")
            .args(["-L", &self.ns])
            .args(args);
        c
    }
    fn run(&self, args: &[&str]) -> String {
        let out = self.command(args).output().unwrap();
        assert!(
            out.status.success(),
            "{:?}: {}",
            args,
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_owned()
    }
    fn wait_cwd(&self, expected: &str) {
        let deadline = Instant::now() + Duration::from_secs(12);
        loop {
            let dump = self.run(&["dump-state", "-t", "cwd"]);
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&dump) {
                if v["host_cwd"].as_str().is_some_and(|s| same(s, expected)) {
                    return;
                }
            }
            assert!(
                Instant::now() < deadline,
                "missing host_cwd {expected}: {dump}"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}
impl Drop for Test {
    fn drop(&mut self) {
        let _ = self.command(&["kill-server"]).output();
    }
}
fn same(a: &str, b: &str) -> bool {
    a.trim_end_matches('\\')
        .eq_ignore_ascii_case(b.trim_end_matches('\\'))
}
fn wait_osc(bytes: &Arc<Mutex<Vec<u8>>>, path: &str) {
    let needle = format!("\x1b]9;9;{path}\x1b\\");
    let deadline = Instant::now() + Duration::from_secs(12);
    loop {
        if bytes
            .lock()
            .unwrap()
            .windows(needle.len())
            .any(|w| w == needle.as_bytes())
        {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "client did not emit OSC 9;9 for {path}"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}
fn main() {
    let exe = std::fs::canonicalize(std::env::args_os().nth(1).expect("psmux.exe path")).unwrap();
    let data = std::env::current_dir()
        .unwrap()
        .join("target")
        .join(format!("host-cwd-live-{}", std::process::id()));
    std::fs::create_dir_all(&data).unwrap();
    let a = data.join("active space 测试");
    let b = data.join("background");
    let c = data.join("background changed");
    for p in [&a, &b, &c] {
        std::fs::create_dir_all(p).unwrap();
    }
    let a = a.to_str().unwrap();
    let b = b.to_str().unwrap();
    let c = c.to_str().unwrap();
    let t = Test {
        exe,
        data: data.clone(),
        ns: format!("hostcwd-{}", std::process::id()),
    };
    let shell = data.join("shell.ps1");
    std::fs::write(&shell, "function global:prompt { [Environment]::CurrentDirectory = (Get-Location).Path; [Console]::Write(([char]27).ToString() + ']9;9;' + (Get-Location).Path + [char]27 + '\\'); 'cwd-test> ' }\n").unwrap();
    let shell = shell.to_str().unwrap();
    t.run(&[
        "new-session",
        "-d",
        "-s",
        "cwd",
        "-c",
        a,
        "--",
        "powershell.exe",
        "-NoProfile",
        "-NoExit",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        shell,
    ]);
    t.run(&["set", "-t", "cwd", "status", "off"]);
    t.run(&["set", "-t", "cwd", "set-titles", "off"]);
    t.wait_cwd(a);
    println!("PASS initial dump-state cwd (spaces + Unicode, status/set-titles off)");

    let pair = native_pty_system()
        .openpty(PtySize {
            rows: 24,
            cols: 100,
            pixel_width: 0,
            pixel_height: 0,
        })
        .unwrap();
    let mut cmd = CommandBuilder::new(&t.exe);
    cmd.env("PSMUX_DATA_DIR", &data);
    cmd.env("PSMUX_NO_WARM", "1");
    cmd.args(["-L", &t.ns, "attach", "-t", "cwd"]);
    let mut child = pair.slave.spawn_command(cmd).unwrap();
    drop(pair.slave);
    let mut reader = pair.master.try_clone_reader().unwrap();
    let bytes = Arc::new(Mutex::new(Vec::new()));
    let collected = bytes.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        while let Ok(n) = reader.read(&mut buf) {
            if n == 0 {
                break;
            }
            collected.lock().unwrap().extend_from_slice(&buf[..n]);
        }
    });
    wait_osc(&bytes, a);
    println!("PASS actual attached client OSC 9;9 bytes");
    t.run(&[
        "split-window",
        "-d",
        "-t",
        "cwd:0.0",
        "-c",
        b,
        "--",
        "powershell.exe",
        "-NoProfile",
        "-NoExit",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        shell,
    ]);
    let deadline = Instant::now() + Duration::from_secs(12);
    while !t
        .run(&["capture-pane", "-p", "-t", "cwd:0.1"])
        .contains("cwd-test>")
    {
        assert!(
            Instant::now() < deadline,
            "background shell did not reach prompt"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    use base64::Engine;
    let payload = base64::engine::general_purpose::STANDARD
        .encode(format!("Set-Location -LiteralPath '{c}'"));
    t.run(&["send-paste", "-t", "cwd:0.1", &payload]);
    t.run(&["send-keys", "-t", "cwd:0.1", "Enter"]);
    std::thread::sleep(Duration::from_secs(1));
    t.wait_cwd(a);
    assert!(!String::from_utf8_lossy(&bytes.lock().unwrap()).contains(&format!("\x1b]9;9;{c}")));
    println!("PASS inactive pane cwd cannot overwrite host cwd");
    t.run(&["select-pane", "-t", "cwd:0.1"]);
    t.wait_cwd(c);
    wait_osc(&bytes, c);
    println!("PASS select-pane updates server state and host OSC");
    t.run(&[
        "new-window",
        "-t",
        "cwd",
        "-c",
        b,
        "--",
        "powershell.exe",
        "-NoProfile",
        "-NoExit",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        shell,
    ]);
    t.wait_cwd(b);
    wait_osc(&bytes, b);
    println!("PASS active window switch updates host OSC");
    t.run(&["select-window", "-t", "cwd:0"]);
    t.wait_cwd(c);
    if std::path::Path::new(r"C:\msys64\msys2_shell.cmd").is_file() {
        // Do not allow an earlier window's matching OSC to satisfy this check.
        bytes.lock().unwrap().clear();
        t.run(&[
            "new-window",
            "-t",
            "cwd",
            "-c",
            b,
            "--",
            "cmd.exe",
            "/d",
            "/c",
            r"C:\msys64\msys2_shell.cmd",
            "-defterm",
            "-ucrt64",
            "-no-start",
            "-here",
            "-use-full-path",
            "-shell",
            "zsh",
        ]);
        let deadline = Instant::now() + Duration::from_secs(20);
        while t.run(&["display-message", "-p", "-t", "cwd:2.0", "#{pane_title}"]) != "zsh-idle" {
            assert!(Instant::now() < deadline, "MSYS2 Zsh idle marker missing");
            std::thread::sleep(Duration::from_millis(100));
        }
        let msys = format!("/c/{}", c[3..].replace('\\', "/"));
        let payload =
            base64::engine::general_purpose::STANDARD.encode(format!("builtin cd -- '{msys}'"));
        t.run(&["send-paste", "-t", "cwd:2.0", &payload]);
        t.run(&["send-keys", "-t", "cwd:2.0", "Enter"]);
        t.wait_cwd(c);
        wait_osc(&bytes, c);
        println!("PASS real MSYS2 UCRT64 Zsh cd updates host cwd");
        let payload = base64::engine::general_purpose::STANDARD
            .encode("printf '\\e[?1049h'; sleep 4; printf '\\e[?1049l'");
        t.run(&["send-paste", "-t", "cwd:2.0", &payload]);
        t.run(&["send-keys", "-t", "cwd:2.0", "Enter"]);
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let dump: serde_json::Value =
                serde_json::from_str(&t.run(&["dump-state", "-t", "cwd"])).unwrap();
            if dump["layout"]["alternate_screen"] == true {
                assert!(
                    same(dump["host_cwd"].as_str().unwrap(), c),
                    "alternate-screen host cwd: {} expected {c}",
                    dump["host_cwd"]
                );
                break;
            }
            assert!(
                Instant::now() < deadline,
                "alternate-screen program did not start"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
        println!("PASS foreground alternate-screen program retains Zsh cwd");
    }
    let _ = child.kill();
    let _ = child.wait();
    drop(pair.master);
    let pair = native_pty_system()
        .openpty(PtySize {
            rows: 24,
            cols: 100,
            pixel_width: 0,
            pixel_height: 0,
        })
        .unwrap();
    let mut cmd = CommandBuilder::new(&t.exe);
    cmd.env("PSMUX_DATA_DIR", &data);
    cmd.args(["-L", &t.ns, "attach", "-t", "cwd"]);
    let mut child = pair.slave.spawn_command(cmd).unwrap();
    drop(pair.slave);
    let mut reader = pair.master.try_clone_reader().unwrap();
    let bytes = Arc::new(Mutex::new(Vec::new()));
    let collected = bytes.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        while let Ok(n) = reader.read(&mut buf) {
            if n == 0 {
                break;
            }
            collected.lock().unwrap().extend_from_slice(&buf[..n]);
        }
    });
    wait_osc(&bytes, c);
    println!("PASS fresh attach reannounces current cwd");
    let _ = child.kill();
    let _ = child.wait();
    drop(pair.master);
    println!("PASS isolated live test complete; test namespace cleaned on exit");
}
