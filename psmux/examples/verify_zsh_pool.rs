//! Live pool lifecycle checks, private data directory and unique namespace.
//! cargo run --example verify_zsh_pool -- target/pool-final/release/psmux.exe
use base64::Engine;
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::{
    io::{BufRead, Read, Write},
    path::PathBuf,
    process::Command,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

struct Test {
    exe: PathBuf,
    data: PathBuf,
    ns: String,
    config: PathBuf,
}
impl Test {
    fn command(&self, args: &[&str]) -> Command {
        let mut cmd = Command::new(&self.exe);
        cmd.env("PSMUX_DATA_DIR", &self.data)
            .env("PSMUX_NO_WARM", "1")
            .env("PSMUX_SESSION_DEBUG", "1")
            .args(["-L", &self.ns])
            .args(args);
        cmd
    }
    fn run(&self, args: &[&str]) -> String {
        let out = self.command(args).output().unwrap();
        assert!(
            out.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap().trim().into()
    }
    fn sessions(&self) -> Vec<String> {
        let out = self
            .command(&["list-sessions", "-F", "#{session_name}"])
            .output()
            .unwrap();
        if !out.status.success() {
            return vec![];
        }
        String::from_utf8(out.stdout)
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect()
    }
    fn wait(&self, what: &str, mut condition: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if condition() {
                return;
            }
            assert!(Instant::now() < deadline, "timeout: {what}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    fn idle(&self, name: &str, attached: &str) {
        self.wait("idle shell", || {
            // Observe detach completion on the server's control socket before
            // invoking more CLI processes (which also run registry cleanup).
            self.direct(
                name,
                "display-message -p '#{pane_title}|#{session_attached}'\n",
            )
            .as_deref()
                == Some(format!("zsh-idle|{attached}").as_str())
        });
    }
    fn direct(&self, name: &str, line: &str) -> Option<String> {
        let base = self.data.join(format!("{}__{name}", self.ns));
        let port: u16 = std::fs::read_to_string(base.with_extension("port"))
            .ok()?
            .trim()
            .parse()
            .ok()?;
        let key = std::fs::read_to_string(base.with_extension("key")).ok()?;
        let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).ok()?;
        stream
            .set_read_timeout(Some(Duration::from_millis(500)))
            .ok()?;
        write!(stream, "AUTH {}\n{line}", key.trim()).ok()?;
        let mut reader = std::io::BufReader::new(stream);
        let mut auth = String::new();
        reader.read_line(&mut auth).ok()?;
        let mut reply = String::new();
        reader.read_line(&mut reply).ok()?;
        Some(reply.trim().into())
    }
    fn send(&self, name: &str, command: &str) {
        // Full session target; never rely on an unqualified pane id.
        let payload = base64::engine::general_purpose::STANDARD.encode(command);
        self.run(&["send-paste", "-t", name, &payload]);
        self.run(&["send-keys", "-t", name, "Enter"]);
    }
    fn pool(&self, dir: &str) -> Client {
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 28,
                cols: 120,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let mut cmd = CommandBuilder::new(&self.exe);
        cmd.env("PSMUX_DATA_DIR", &self.data);
        cmd.env("PSMUX_NO_WARM", "1");
        cmd.env("PSMUX_ZSH_DEBUG", "1");
        cmd.env("PSMUX_SERVER_DEBUG", "1");
        cmd.env("PSMUX_SESSION_DEBUG", "1");
        cmd.env("WT_SESSION", "isolated-zsh-pool-test");
        cmd.args([
            "-L",
            &self.ns,
            "-f",
            self.config.to_str().unwrap(),
            "zsh-pool",
            "-c",
            dir,
        ]);
        let child = pair.slave.spawn_command(cmd).unwrap();
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
        Client {
            child,
            _master: pair.master,
            bytes,
        }
    }
}
impl Drop for Test {
    fn drop(&mut self) {
        let _ = self.command(&["kill-server"]).output();
    }
}
struct Client {
    child: Box<dyn portable_pty::Child + Send + Sync>,
    _master: Box<dyn MasterPty + Send>,
    bytes: Arc<Mutex<Vec<u8>>>,
}
impl Client {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.bytes.lock().unwrap()).into_owned()
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn main() {
    let exe = std::fs::canonicalize(std::env::args_os().nth(1).expect("psmux exe")).unwrap();
    let data = std::env::current_dir()
        .unwrap()
        .join("target")
        .join(format!("zsh-pool-live-{}", std::process::id()));
    std::fs::create_dir_all(&data).unwrap();
    let config = data.join("test.conf");
    std::fs::write(&config, "set -g status off\nset -g allow-set-title on\nset -g destroy-unattached off\nset -g warm-pool-size 0\n").unwrap();
    let a = data.join("A");
    let b = data.join("B 空格 it's");
    for dir in [&a, &b] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let a = a.to_str().unwrap();
    let b = b.to_str().unwrap();
    let t = Test {
        exe,
        data: data.clone(),
        ns: format!("zshpool-{}", std::process::id()),
        config,
    };

    let client = t.pool(a);
    t.wait("first session", || t.sessions().len() == 1);
    let first = t.sessions()[0].clone();
    t.idle(&first, "1");
    let shell_pid = t.run(&["display-message", "-p", "-t", &first, "#{pane_pid}"]);
    t.send(
        &first,
        "export PSMUX_POOL_SENTINEL=kept; print -r -- POOL_SENTINEL_SET",
    );
    t.wait("sentinel command", || {
        t.run(&["capture-pane", "-p", "-t", &first])
            .contains("POOL_SENTINEL_SET")
    });
    t.idle(&first, "1");
    println!("PASS empty pool creates and attaches real MSYS2 Zsh");

    let attached_other = t.pool(a);
    t.wait("attached session skipped", || t.sessions().len() == 2);
    let second = t.sessions().into_iter().find(|n| n != &first).unwrap();
    t.idle(&second, "1");
    println!("PASS attached idle session is not reused");
    drop(attached_other);
    t.idle(&second, "0");
    // Keep the other session busy so the detached original is the sole candidate.
    t.send(&second, "sleep 60");
    t.wait("second busy", || {
        t.run(&["display-message", "-p", "-t", &second, "#{pane_title}"]) == "zsh-busy"
    });
    drop(client);
    t.idle(&first, "0");

    let reused = t.pool(b);
    t.wait("original reused", || {
        t.run(&["display-message", "-p", "-t", &first, "#{session_attached}"]) == "1"
    });
    assert_eq!(t.sessions().len(), 2);
    assert_eq!(
        t.run(&["display-message", "-p", "-t", &first, "#{pane_pid}"]),
        shell_pid
    );
    let dump: serde_json::Value =
        serde_json::from_str(&t.run(&["dump-state", "-t", &first])).unwrap();
    assert!(dump["host_cwd"]
        .as_str()
        .unwrap()
        .trim_end_matches('\\')
        .eq_ignore_ascii_case(b));
    t.send(&first, "print -r -- POOL_SAVED_STATE=$PSMUX_POOL_SENTINEL");
    t.wait("state survived reuse", || {
        t.run(&["capture-pane", "-p", "-t", &first])
            .contains("POOL_SAVED_STATE=kept")
    });
    t.idle(&first, "1");
    assert!(reused.text().contains("reuse "));
    println!("PASS same shell PID and variables survive reuse; quoted Unicode cwd is correct");
    println!("PASS detached busy session is skipped");

    drop(reused);
    t.idle(&first, "0");
    let left = t.pool(a);
    let right = t.pool(b);
    t.wait("concurrent clients", || {
        t.sessions().len() == 3
            && t.sessions()
                .iter()
                .filter(|n| {
                    t.run(&["display-message", "-p", "-t", n, "#{session_attached}"]) == "1"
                })
                .count()
                == 2
    });
    t.wait("concurrent decisions", || {
        (left.text().contains("reuse ") || left.text().contains("create "))
            && (right.text().contains("reuse ") || right.text().contains("create "))
    });
    let reuse_count = [&left, &right]
        .iter()
        .filter(|c| c.text().contains("reuse "))
        .count();
    assert_eq!(
        reuse_count, 1,
        "two clients must not claim one detached shell"
    );
    println!("PASS simultaneous pool launches claim distinct sessions");
    drop(left);
    drop(right);
    t.idle(&first, "0");
    // Make the third session busy, then verify a crashed/killed client's lock
    // has been released and the original shell can be claimed again.
    let third = t
        .sessions()
        .into_iter()
        .find(|n| n != &first && n != &second)
        .unwrap();
    t.idle(&third, "0");
    t.send(&third, "sleep 60");
    t.wait("third busy", || {
        t.run(&["display-message", "-p", "-t", &third, "#{pane_title}"]) == "zsh-busy"
    });
    let final_client = t.pool(a);
    t.wait("released reservation reused", || {
        t.run(&["display-message", "-p", "-t", &first, "#{session_attached}"]) == "1"
    });
    assert_eq!(t.sessions().len(), 3);
    println!("PASS client termination releases reservation for later reuse");
    drop(final_client);
    println!("PASS isolated pool lifecycle complete; test namespace cleaned on exit");
}
