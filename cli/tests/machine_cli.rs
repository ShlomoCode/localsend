//! Exercises the public, non-terminal CLI through real child processes.

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const PROCESS_LIMIT: Duration = Duration::from_secs(25);
static TEST_LOCK: Mutex<()> = Mutex::new(());

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("localsend-cli-e2e-{}-{stamp}", std::process::id()));
        fs::create_dir(&root).unwrap();
        Self { root }
    }

    fn dir(&self, name: &str) -> PathBuf {
        let dir = self.root.join(name);
        fs::create_dir(&dir).unwrap();
        dir
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

struct Cli {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    stdout_reader: Option<thread::JoinHandle<()>>,
    stderr_lines: Arc<Mutex<Vec<String>>>,
    seen: Vec<String>,
    label: &'static str,
}

impl Cli {
    fn start(label: &'static str, config: &Path, args: &[&str]) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_localsend-cli"))
            .args(args)
            .env("XDG_CONFIG_HOME", config)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap_or_else(|error| panic!("{label}: spawn failed: {error}"));
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let (tx, lines) = mpsc::channel();
        let stdout_reader = thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if tx.send(line.expect("read CLI stdout")).is_err() {
                    break;
                }
            }
        });
        // Drain stderr even during long transfers so its pipe cannot block the child.
        let stderr_lines = Arc::new(Mutex::new(Vec::new()));
        let captured_stderr = stderr_lines.clone();
        thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                captured_stderr.lock().unwrap().push(line);
            }
        });
        Self {
            child,
            stdin,
            lines,
            stdout_reader: Some(stdout_reader),
            stderr_lines,
            seen: Vec::new(),
            label,
        }
    }

    fn write(&mut self, request: Value) {
        writeln!(self.stdin, "{request}").unwrap();
        self.stdin.flush().unwrap();
    }

    fn write_raw(&mut self, request: &str) {
        writeln!(self.stdin, "{request}").unwrap();
        self.stdin.flush().unwrap();
    }

    fn next_json(&mut self, deadline: Instant) -> Value {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let line = self.lines.recv_timeout(remaining).unwrap_or_else(|error| {
            panic!(
                "{}: no JSON line ({error}); stdout: {:?}; stderr: {:?}",
                self.label,
                self.seen,
                self.stderr_lines.lock().unwrap()
            )
        });
        self.seen.push(line.clone());
        serde_json::from_str(&line).unwrap_or_else(|error| {
            panic!(
                "{}: stdout contains a non-JSON line {line:?}: {error}",
                self.label
            )
        })
    }

    fn poll_json(&mut self, wait: Duration) -> Option<Value> {
        match self.lines.recv_timeout(wait) {
            Ok(line) => {
                self.seen.push(line.clone());
                Some(serde_json::from_str(&line).unwrap_or_else(|error| {
                    panic!(
                        "{}: stdout contains a non-JSON line {line:?}: {error}",
                        self.label
                    )
                }))
            }
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => panic!(
                "{}: stdout closed; stdout: {:?}; stderr: {:?}",
                self.label,
                self.seen,
                self.stderr_lines.lock().unwrap()
            ),
        }
    }

    fn until(&mut self, deadline: Instant, predicate: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = self.next_json(deadline);
            if predicate(&line) {
                return line;
            }
        }
    }

    fn exits(&mut self, deadline: Instant, success: bool) {
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                assert_eq!(
                    status.success(),
                    success,
                    "{} exited {status}; stdout: {:?}; stderr: {:?}",
                    self.label,
                    self.seen,
                    self.stderr_lines.lock().unwrap()
                );
                self.stdout_reader
                    .take()
                    .unwrap()
                    .join()
                    .expect("stdout reader panicked");
                while let Ok(line) = self.lines.try_recv() {
                    self.seen.push(line.clone());
                    serde_json::from_str::<Value>(&line).unwrap_or_else(|error| {
                        panic!(
                            "{}: stdout contains a non-JSON line {line:?}: {error}",
                            self.label
                        )
                    });
                }
                return;
            }
            assert!(
                Instant::now() < deadline,
                "{} did not exit; stdout: {:?}",
                self.label,
                self.seen
            );
            thread::sleep(Duration::from_millis(25));
        }
    }
}

impl Drop for Cli {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn wait_for_port(port: u16, deadline: Instant) {
    while Instant::now() < deadline {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return;
        }
        thread::sleep(Duration::from_millis(25));
    }
    panic!("CLI server did not bind port {port}");
}

fn identity_fingerprint(config: &Path) -> String {
    let identity = fs::read_to_string(config.join("localsend-cli/identity.pem")).unwrap();
    let blocks = pem::parse_many(identity).unwrap();
    let cert = blocks
        .iter()
        .find(|block| block.tag() == "CERTIFICATE")
        .unwrap();
    localsend::crypto::cert::fingerprint_from_cert_der(cert.contents())
}

fn pair_devices(config: &Path, devices: &[(&str, u16)]) {
    let directory = config.join("localsend-cli");
    fs::create_dir_all(&directory).unwrap();
    let mut stored = serde_json::Map::new();
    for (fingerprint, port) in devices {
        stored.insert(
            (*fingerprint).to_owned(),
            json!({"alias":format!("peer-{port}"),"channels":[{"host":"127.0.0.1",
                "port":port,"protocol":"HTTPS"}]}),
        );
    }
    fs::write(
        directory.join("paired-v2.json"),
        json!({"version":1,"devices":stored}).to_string(),
    )
    .unwrap();
}

#[test]
fn send_to_non_terminal_receiver_saves_the_actual_bytes() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let receiver_config = fixture.dir("receiver-config");
    let sender_config = fixture.dir("sender-config");
    let destination = fixture.dir("downloads");
    let file = fixture.root.join("payload.bin");
    let contents: Vec<u8> = (0..64_000).map(|n| (n % 251) as u8).collect();
    fs::write(&file, &contents).unwrap();
    let receiver_port = free_port();
    let mut sender_port = free_port();
    while sender_port == receiver_port {
        sender_port = free_port();
    }
    let receiver_port_text = receiver_port.to_string();
    let sender_port_text = sender_port.to_string();
    let destination_text = destination.to_str().unwrap();
    let file_text = file.to_str().unwrap();
    let deadline = Instant::now() + PROCESS_LIMIT;

    let mut receiver = Cli::start(
        "receiver",
        &receiver_config,
        &[
            "--alias",
            "E2E receiver",
            "--port",
            &receiver_port_text,
            "--destination",
            destination_text,
            "receive",
            "--auto-accept",
            "--once",
            "--timeout",
            "20",
            "--json",
        ],
    );
    wait_for_port(receiver_port, deadline);
    let mut sender = Cli::start(
        "sender",
        &sender_config,
        &[
            "--alias",
            "E2E sender",
            "--port",
            &sender_port_text,
            "send",
            "--to",
            "127.0.0.1",
            "--target-port",
            &receiver_port_text,
            "--timeout",
            "20",
            "--json",
            file_text,
        ],
    );
    let sent = sender.until(deadline, |line| line["type"] == "send_completed");
    assert_eq!(sent["success"], true, "{sent}");
    let received = receiver.until(deadline, |line| line["type"] == "receive_completed");
    assert!(received["files"].as_u64().unwrap_or(0) >= 1, "{received}");
    sender.exits(deadline, true);
    receiver.exits(deadline, true);
    assert_eq!(fs::read(destination.join("payload.bin")).unwrap(), contents);
}

#[test]
fn discover_emits_one_machine_readable_snapshot() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let config = fixture.dir("discover-config");
    let deadline = Instant::now() + PROCESS_LIMIT;
    let mut cli = Cli::start(
        "discover",
        &config,
        &["discover", "--json", "--timeout", "1"],
    );
    let snapshot = cli.next_json(deadline);
    assert_eq!(snapshot["type"], "discovery", "{snapshot}");
    let devices = snapshot["devices"]
        .as_array()
        .expect("devices must be an array");
    for device in devices {
        assert!(device["alias"].is_string(), "{device}");
        assert!(device["fingerprint"].is_string(), "{device}");
        assert!(device["host"].is_string(), "{device}");
        assert!(device["port"].as_u64().is_some(), "{device}");
        assert!(device["paired"].is_boolean(), "{device}");
    }
    cli.exits(deadline, true);
    assert_eq!(
        cli.seen.len(),
        1,
        "discover should emit exactly one JSON snapshot"
    );
}

#[test]
fn serve_stays_alive_across_requests_and_reports_errors() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let config = fixture.dir("serve-config");
    let port = free_port();
    let port_text = port.to_string();
    let deadline = Instant::now() + PROCESS_LIMIT;
    let mut cli = Cli::start(
        "serve",
        &config,
        &["--port", &port_text, "serve", "--stdio"],
    );
    let ready = cli.until(deadline, |line| line["event"] == "ready");
    assert_eq!(ready["port"], port, "{ready}");
    cli.write(json!({"id":"status-1","command":"status"}));
    let status = cli.until(deadline, |line| line["id"] == "status-1");
    assert_eq!(status["ok"], true, "{status}");
    cli.write(json!({"id":"devices-1","command":"devices"}));
    let devices = cli.until(deadline, |line| line["id"] == "devices-1");
    assert_eq!(devices["ok"], true, "{devices}");
    assert!(devices["result"]["devices"].is_array(), "{devices}");
    cli.write(json!({"id":"unknown-1","command":"no-such-command"}));
    let unknown = cli.until(deadline, |line| line["id"] == "unknown-1");
    assert_eq!(unknown["ok"], false, "{unknown}");
    cli.write_raw("{broken json");
    let malformed = cli.until(deadline, |line| line["ok"] == false);
    assert!(malformed["error"].is_string(), "{malformed}");
    cli.write(json!({"id":"status-2","command":"status"}));
    let status_again = cli.until(deadline, |line| line["id"] == "status-2");
    assert_eq!(status_again["ok"], true, "{status_again}");
    cli.write(json!({"id":"stop","command":"shutdown"}));
    let stopped = cli.until(deadline, |line| line["id"] == "stop");
    assert_eq!(stopped["ok"], true, "{stopped}");
    cli.exits(deadline, true);
}

#[test]
fn serve_accepts_two_transfers_without_restarting() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let receiver_config = fixture.dir("serve-receiver-config");
    let sender_config = fixture.dir("serve-sender-config");
    let destination = fixture.dir("serve-downloads");
    let receiver_port = free_port();
    let mut sender_port = free_port();
    while sender_port == receiver_port {
        sender_port = free_port();
    }
    let receiver_port_text = receiver_port.to_string();
    let sender_port_text = sender_port.to_string();
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut receiver = Cli::start(
        "persistent receiver",
        &receiver_config,
        &[
            "--port",
            &receiver_port_text,
            "--destination",
            destination.to_str().unwrap(),
            "serve",
            "--stdio",
        ],
    );
    assert_eq!(
        receiver.until(deadline, |line| line["event"] == "ready")["port"],
        receiver_port
    );

    for (index, bytes) in [(1, &b"first transfer"[..]), (2, &b"second transfer"[..])] {
        let name = format!("serve-{index}.bin");
        let file = fixture.root.join(&name);
        fs::write(&file, bytes).unwrap();
        let mut sender = Cli::start(
            "serve sender",
            &sender_config,
            &[
                "--port",
                &sender_port_text,
                "send",
                "--to",
                "127.0.0.1",
                "--target-port",
                &receiver_port_text,
                "--timeout",
                "20",
                "--json",
                file.to_str().unwrap(),
            ],
        );
        let request = receiver.until(deadline, |line| line["event"] == "receive_request");
        let session_id = request["session_id"]
            .as_str()
            .expect("receive request session ID");
        assert!(
            request["files"]
                .as_array()
                .is_some_and(|files| files.len() == 1),
            "{request}"
        );
        receiver.write(
            json!({"id":format!("accept-{index}"),"command":"receive_decision",
            "session_id":session_id,"accept":true}),
        );
        let accepted = receiver.until(deadline, |line| line["id"] == format!("accept-{index}"));
        assert_eq!(accepted["ok"], true, "{accepted}");
        assert_eq!(accepted["result"]["accepted"], true, "{accepted}");
        let sent = sender.until(deadline, |line| line["type"] == "send_completed");
        assert_eq!(sent["success"], true, "{sent}");
        let received = receiver.until(deadline, |line| line["event"] == "receive_completed");
        assert_eq!(received["success"], true, "{received}");
        sender.exits(deadline, true);
        assert_eq!(fs::read(destination.join(name)).unwrap(), bytes);

        receiver.write(json!({"id":format!("status-{index}"),"command":"status"}));
        let status = receiver.until(deadline, |line| line["id"] == format!("status-{index}"));
        assert_eq!(status["ok"], true, "{status}");
        assert!(status["result"]["receiving"].is_null(), "{status}");
    }

    receiver.write(json!({"id":"stop","command":"shutdown"}));
    assert_eq!(
        receiver.until(deadline, |line| line["id"] == "stop")["ok"],
        true
    );
    receiver.exits(deadline, true);
}

#[test]
fn unpaired_sender_is_rejected_by_default() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let receiver_config = fixture.dir("private-receiver-config");
    let sender_config = fixture.dir("private-sender-config");
    let destination = fixture.dir("private-downloads");
    let file = fixture.root.join("private.bin");
    fs::write(&file, b"must not be saved").unwrap();
    let receiver_port = free_port();
    let mut sender_port = free_port();
    while sender_port == receiver_port {
        sender_port = free_port();
    }
    let receiver_port_text = receiver_port.to_string();
    let sender_port_text = sender_port.to_string();
    let deadline = Instant::now() + PROCESS_LIMIT;
    let mut receiver = Cli::start(
        "private receiver",
        &receiver_config,
        &[
            "--port",
            &receiver_port_text,
            "--destination",
            destination.to_str().unwrap(),
            "receive",
            "--once",
            "--timeout",
            "8",
            "--json",
        ],
    );
    wait_for_port(receiver_port, deadline);
    let mut sender = Cli::start(
        "unpaired sender",
        &sender_config,
        &[
            "--port",
            &sender_port_text,
            "send",
            "--to",
            "127.0.0.1",
            "--target-port",
            &receiver_port_text,
            "--timeout",
            "8",
            "--json",
            file.to_str().unwrap(),
        ],
    );
    let declined = receiver.until(deadline, |line| line["event"] == "receive_declined");
    assert_eq!(declined["reason"], "unpaired", "{declined}");
    sender.exits(deadline, false);
    receiver.exits(deadline, false);
    assert!(!destination.join("private.bin").exists());
}

#[test]
fn receive_once_times_out_without_a_sender() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let config = fixture.dir("timeout-config");
    let port = free_port().to_string();
    let deadline = Instant::now() + PROCESS_LIMIT;
    let mut receiver = Cli::start(
        "timed receiver",
        &config,
        &[
            "--port",
            &port,
            "receive",
            "--once",
            "--timeout",
            "1",
            "--json",
        ],
    );
    receiver.exits(deadline, false);
}

#[test]
fn persistent_serve_can_send_twice_to_a_direct_ip() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let sender_config = fixture.dir("serve-sender-config");
    let receiver_config = fixture.dir("serve-target-config");
    let destination = fixture.dir("serve-target-downloads");
    let sender_port = free_port();
    let mut receiver_port = free_port();
    while receiver_port == sender_port {
        receiver_port = free_port();
    }
    let sender_port_text = sender_port.to_string();
    let receiver_port_text = receiver_port.to_string();
    let deadline = Instant::now() + Duration::from_secs(70);
    let mut sender = Cli::start(
        "persistent sender",
        &sender_config,
        &["--port", &sender_port_text, "serve", "--stdio"],
    );
    assert_eq!(
        sender.until(deadline, |line| line["event"] == "ready")["port"],
        sender_port
    );

    for (index, bytes) in [(1, &b"one"[..]), (2, &b"two"[..])] {
        let name = format!("direct-{index}.txt");
        let file = fixture.root.join(&name);
        fs::write(&file, bytes).unwrap();
        let mut receiver = Cli::start(
            "direct receiver",
            &receiver_config,
            &[
                "--port",
                &receiver_port_text,
                "--destination",
                destination.to_str().unwrap(),
                "receive",
                "--auto-accept",
                "--once",
                "--timeout",
                "20",
                "--json",
            ],
        );
        wait_for_port(receiver_port, deadline);
        sender.write(
            json!({"id":format!("send-{index}"),"command":"send","to":"127.0.0.1",
            "target_port":receiver_port,"timeout":20,"paths":[file]}),
        );
        let reply = sender.until(deadline, |line| line["id"] == format!("send-{index}"));
        assert_eq!(reply["ok"], true, "{reply}");
        let transfer_id = reply["result"]["transfer_id"]
            .as_str()
            .expect("transfer ID")
            .to_owned();
        let sent = sender.until(deadline, |line| {
            line["type"] == "send_completed" && line["transfer_id"] == transfer_id
        });
        assert_eq!(sent["success"], true, "{sent}");
        let received = receiver.until(deadline, |line| line["type"] == "receive_completed");
        assert_eq!(received["success"], true, "{received}");
        receiver.exits(deadline, true);
        assert_eq!(fs::read(destination.join(name)).unwrap(), bytes);
    }

    sender.write(json!({"id":"stop","command":"shutdown"}));
    assert_eq!(
        sender.until(deadline, |line| line["id"] == "stop")["ok"],
        true
    );
    sender.exits(deadline, true);
}

#[test]
fn receive_once_reports_failed_save_and_exits_unsuccessfully() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let receiver_config = fixture.dir("failed-save-receiver-config");
    let sender_config = fixture.dir("failed-save-sender-config");
    let destination = fixture.root.join("not-a-directory");
    fs::write(&destination, b"existing regular file").unwrap();
    let file = fixture.root.join("failed-save.txt");
    fs::write(&file, b"cannot land under regular file").unwrap();
    let receiver_port = free_port();
    let mut sender_port = free_port();
    while sender_port == receiver_port {
        sender_port = free_port();
    }
    let receiver_port_text = receiver_port.to_string();
    let sender_port_text = sender_port.to_string();
    let deadline = Instant::now() + Duration::from_secs(35);
    let mut receiver = Cli::start(
        "failed-save receiver",
        &receiver_config,
        &[
            "--port",
            &receiver_port_text,
            "--destination",
            destination.to_str().unwrap(),
            "receive",
            "--auto-accept",
            "--once",
            "--timeout",
            "25",
            "--json",
        ],
    );
    wait_for_port(receiver_port, deadline);
    let mut sender = Cli::start(
        "failed-save sender",
        &sender_config,
        &[
            "--port",
            &sender_port_text,
            "send",
            "--to",
            "127.0.0.1",
            "--target-port",
            &receiver_port_text,
            "--timeout",
            "25",
            "--json",
            file.to_str().unwrap(),
        ],
    );
    let completed = receiver.until(deadline, |line| line["type"] == "receive_completed");
    assert_eq!(completed["success"], false, "{completed}");
    assert!(
        completed["failed_files"].as_u64().unwrap_or(0) > 0,
        "{completed}"
    );
    receiver.exits(deadline, false);
    sender.exits(deadline, false);
    assert_eq!(fs::read(&destination).unwrap(), b"existing regular file");
}

#[test]
fn timed_out_serve_send_does_not_poison_the_next_transfer() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let sender_config = fixture.dir("retry-sender-config");
    let receiver_config = fixture.dir("retry-receiver-config");
    let destination = fixture.dir("retry-downloads");
    let warmup_file = fixture.root.join("warmup.txt");
    let first_file = fixture.root.join("timed-out.txt");
    let second_file = fixture.root.join("accepted.txt");
    fs::write(&warmup_file, b"connection established").unwrap();
    fs::write(&first_file, b"never accepted").unwrap();
    fs::write(&second_file, b"accepted after timeout").unwrap();
    let sender_port = free_port();
    let mut receiver_port = free_port();
    while receiver_port == sender_port {
        receiver_port = free_port();
    }
    let sender_port_text = sender_port.to_string();
    let receiver_port_text = receiver_port.to_string();
    let deadline = Instant::now() + Duration::from_secs(90);
    let mut receiver = Cli::start(
        "retry receiver",
        &receiver_config,
        &[
            "--port",
            &receiver_port_text,
            "--destination",
            destination.to_str().unwrap(),
            "serve",
            "--stdio",
        ],
    );
    assert_eq!(
        receiver.until(deadline, |line| line["event"] == "ready")["port"],
        receiver_port
    );
    let mut sender = Cli::start(
        "retry sender",
        &sender_config,
        &["--port", &sender_port_text, "serve", "--stdio"],
    );
    assert_eq!(
        sender.until(deadline, |line| line["event"] == "ready")["port"],
        sender_port
    );
    sender.until(deadline, |line| line["event"] == "discovery_completed");

    // Establish the direct channel before timing an unanswered upload request.
    // Otherwise a slow discovery pass could consume the send timeout first.
    sender.write(json!({"id":"warmup","command":"send","to":"127.0.0.1",
        "target_port":receiver_port,"timeout":25,"paths":[warmup_file]}));
    let warmup_reply = sender.until(deadline, |line| line["id"] == "warmup");
    assert_eq!(warmup_reply["ok"], true, "{warmup_reply}");
    let warmup_id = warmup_reply["result"]["transfer_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let warmup_request = receiver.until(deadline, |line| line["event"] == "receive_request");
    let warmup_session = warmup_request["session_id"].as_str().unwrap().to_owned();
    receiver.write(json!({"id":"warmup-accept","command":"receive_decision",
        "session_id":warmup_session,"accept":true}));
    let warmup_accepted = receiver.until(deadline, |line| line["id"] == "warmup-accept");
    assert_eq!(
        warmup_accepted["result"]["accepted"], true,
        "{warmup_accepted}"
    );
    let warmup_sent = sender.until(deadline, |line| {
        line["event"] == "send_completed" && line["transfer_id"] == warmup_id
    });
    assert_eq!(warmup_sent["success"], true, "{warmup_sent}");
    let warmup_received = receiver.until(deadline, |line| {
        line["event"] == "receive_completed" && line["session_id"] == warmup_session
    });
    assert_eq!(warmup_received["success"], true, "{warmup_received}");
    assert_eq!(
        fs::read(destination.join("warmup.txt")).unwrap(),
        b"connection established"
    );

    sender.write(json!({"id":"first","command":"send","to":"127.0.0.1",
        "target_port":receiver_port,"timeout":10,"paths":[first_file]}));
    let first_reply = sender.until(deadline, |line| line["id"] == "first");
    assert_eq!(first_reply["ok"], true, "{first_reply}");
    let first_id = first_reply["result"]["transfer_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let first_request = loop {
        if let Some(line) = receiver.poll_json(Duration::from_millis(100))
            && line["event"] == "receive_request"
        {
            break line;
        }
        while let Some(line) = sender.poll_json(Duration::ZERO) {
            if line["event"] == "send_completed" && line["transfer_id"] == first_id {
                panic!(
                    "sender finished before receiver saw prepare request: {line}; sender: {:?}; receiver: {:?}",
                    sender.seen, receiver.seen
                );
            }
        }
        assert!(
            Instant::now() < deadline,
            "receiver never saw prepare request; sender: {:?}; receiver: {:?}",
            sender.seen,
            receiver.seen
        );
    };
    let first_session = first_request["session_id"].as_str().unwrap().to_owned();
    let first_result = sender.until(deadline, |line| {
        line["event"] == "send_completed" && line["transfer_id"] == first_id
    });
    assert_eq!(first_result["success"], false, "{first_result}");
    assert!(
        first_result["error"]
            .as_str()
            .is_some_and(|error| error.contains("Timed out")),
        "{first_result}"
    );
    let aborted = receiver.until(deadline, |line| {
        line["event"] == "receive_aborted" && line["session_id"] == first_session
    });
    assert_eq!(aborted["session_id"], first_session, "{aborted}");

    // Cancellation is asynchronous. Wait until the worker has fully released the send slot.
    let mut status_index = 0;
    loop {
        status_index += 1;
        let id = format!("status-{status_index}");
        sender.write(json!({"id":id.clone(),"command":"status"}));
        let status = sender.until(deadline, |line| line["id"] == id);
        assert_eq!(status["ok"], true, "{status}");
        if status["result"]["sending"].is_null() && status["result"]["queued_send"].is_null() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "send slot remained occupied: {status}"
        );
        thread::sleep(Duration::from_millis(50));
    }

    sender.write(json!({"id":"second","command":"send","to":"127.0.0.1",
        "target_port":receiver_port,"timeout":20,"paths":[second_file]}));
    let second_reply = sender.until(deadline, |line| line["id"] == "second");
    assert_eq!(second_reply["ok"], true, "{second_reply}");
    let second_id = second_reply["result"]["transfer_id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(first_id, second_id);
    let second_request = receiver.until(deadline, |line| line["event"] == "receive_request");
    let second_session = second_request["session_id"].as_str().unwrap().to_owned();
    assert_ne!(first_session, second_session);
    receiver.write(json!({"id":"accept","command":"receive_decision",
        "session_id":second_session,"accept":true}));
    let accepted = receiver.until(deadline, |line| line["id"] == "accept");
    assert_eq!(accepted["result"]["accepted"], true, "{accepted}");
    let second_result = sender.until(deadline, |line| {
        line["event"] == "send_completed" && line["transfer_id"] == second_id
    });
    assert_eq!(second_result["success"], true, "{second_result}");
    let received = receiver.until(deadline, |line| {
        line["event"] == "receive_completed" && line["session_id"] == second_session
    });
    assert_eq!(received["success"], true, "{received}");
    assert!(!destination.join("timed-out.txt").exists());
    assert_eq!(
        fs::read(destination.join("accepted.txt")).unwrap(),
        b"accepted after timeout"
    );

    for cli in [&mut sender, &mut receiver] {
        cli.write(json!({"id":"stop","command":"shutdown"}));
        assert_eq!(cli.until(deadline, |line| line["id"] == "stop")["ok"], true);
        cli.exits(deadline, true);
    }
}

#[test]
fn explicit_target_port_selects_one_of_two_devices_on_the_same_ip() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let first_config = fixture.dir("same-ip-first-config");
    let second_config = fixture.dir("same-ip-second-config");
    let sender_config = fixture.dir("same-ip-sender-config");
    let first_destination = fixture.dir("same-ip-first-downloads");
    let second_destination = fixture.dir("same-ip-second-downloads");
    let file = fixture.root.join("chosen.txt");
    fs::write(&file, b"only the specified port receives this").unwrap();
    let first_port = free_port();
    let mut second_port = free_port();
    while second_port == first_port {
        second_port = free_port();
    }
    let mut sender_port = free_port();
    while sender_port == first_port || sender_port == second_port {
        sender_port = free_port();
    }
    let first_port_text = first_port.to_string();
    let second_port_text = second_port.to_string();
    let sender_port_text = sender_port.to_string();
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut first = Cli::start(
        "same IP first receiver",
        &first_config,
        &[
            "--port",
            &first_port_text,
            "--destination",
            first_destination.to_str().unwrap(),
            "receive",
            "--auto-accept",
            "--once",
            "--timeout",
            "50",
            "--json",
        ],
    );
    let mut second = Cli::start(
        "same IP second receiver",
        &second_config,
        &[
            "--port",
            &second_port_text,
            "--destination",
            second_destination.to_str().unwrap(),
            "receive",
            "--auto-accept",
            "--once",
            "--timeout",
            "50",
            "--json",
        ],
    );
    wait_for_port(first_port, deadline);
    wait_for_port(second_port, deadline);
    let first_fingerprint = identity_fingerprint(&first_config);
    let second_fingerprint = identity_fingerprint(&second_config);
    assert_ne!(first_fingerprint, second_fingerprint);
    pair_devices(
        &sender_config,
        &[
            (&first_fingerprint, first_port),
            (&second_fingerprint, second_port),
        ],
    );

    let mut discovery = Cli::start(
        "same IP discovery",
        &sender_config,
        &[
            "--port",
            &sender_port_text,
            "discover",
            "--json",
            "--timeout",
            "10",
        ],
    );
    let snapshot = discovery.until(deadline, |line| line["type"] == "discovery");
    let devices = snapshot["devices"].as_array().unwrap();
    assert!(
        devices.iter().any(
            |device| device["fingerprint"] == first_fingerprint && device["port"] == first_port
        ),
        "{snapshot}"
    );
    assert!(
        devices
            .iter()
            .any(|device| device["fingerprint"] == second_fingerprint
                && device["port"] == second_port),
        "{snapshot}"
    );
    discovery.exits(deadline, true);

    let mut sender = Cli::start(
        "same IP sender",
        &sender_config,
        &[
            "--port",
            &sender_port_text,
            "send",
            "--to",
            "127.0.0.1",
            "--target-port",
            &second_port_text,
            "--timeout",
            "30",
            "--json",
            file.to_str().unwrap(),
        ],
    );
    let sent = sender.until(deadline, |line| line["type"] == "send_completed");
    assert_eq!(sent["success"], true, "{sent}");
    let received = second.until(deadline, |line| line["type"] == "receive_completed");
    assert_eq!(received["success"], true, "{received}");
    sender.exits(deadline, true);
    second.exits(deadline, true);
    assert_eq!(
        fs::read(second_destination.join("chosen.txt")).unwrap(),
        b"only the specified port receives this"
    );
    assert!(!first_destination.join("chosen.txt").exists());
    assert!(
        first.child.try_wait().unwrap().is_none(),
        "other receiver exited before the chosen transfer"
    );
}

#[test]
fn send_mode_rejects_an_incoming_paired_sender() {
    let _serial = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new();
    let sender_config = fixture.dir("paired-sender-config");
    let receiver_config = fixture.dir("paired-send-mode-config");
    let sink_config = fixture.dir("paired-send-mode-sink-config");
    let destination = fixture.dir("paired-send-mode-downloads");
    let sink_destination = fixture.dir("paired-send-mode-sink-downloads");
    let control_file = fixture.root.join("paired-control.txt");
    let file = fixture.root.join("paired.txt");
    let outgoing_file = fixture.root.join("outgoing.txt");
    fs::write(&control_file, b"paired receive control").unwrap();
    fs::write(&file, b"paired send must be rejected during outgoing send").unwrap();
    fs::write(&outgoing_file, b"outgoing transfer stays pending").unwrap();
    let sender_port = free_port();
    let mut receiver_port = free_port();
    while receiver_port == sender_port {
        receiver_port = free_port();
    }
    let mut sink_port = free_port();
    while sink_port == sender_port || sink_port == receiver_port {
        sink_port = free_port();
    }
    let sender_port_text = sender_port.to_string();
    let receiver_port_text = receiver_port.to_string();
    let sink_port_text = sink_port.to_string();
    let deadline = Instant::now() + Duration::from_secs(75);
    let mut sender = Cli::start(
        "paired sender",
        &sender_config,
        &["--port", &sender_port_text, "serve", "--stdio"],
    );
    sender.until(deadline, |line| line["event"] == "ready");
    sender.until(deadline, |line| line["event"] == "discovery_completed");
    let sender_fingerprint = identity_fingerprint(&sender_config);
    pair_devices(&receiver_config, &[(&sender_fingerprint, sender_port)]);
    let mut control = Cli::start(
        "paired receive control",
        &receiver_config,
        &[
            "--port",
            &receiver_port_text,
            "--destination",
            destination.to_str().unwrap(),
            "receive",
            "--once",
            "--timeout",
            "25",
            "--json",
        ],
    );
    wait_for_port(receiver_port, deadline);
    sender.write(
        json!({"id":"control-send","command":"send","to":"127.0.0.1",
        "target_port":receiver_port,"timeout":20,"paths":[control_file]}),
    );
    let control_reply = sender.until(deadline, |line| line["id"] == "control-send");
    assert_eq!(control_reply["ok"], true, "{control_reply}");
    let control_id = control_reply["result"]["transfer_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let control_sent = sender.until(deadline, |line| {
        line["type"] == "send_completed" && line["transfer_id"] == control_id
    });
    assert_eq!(
        control_sent["success"], true,
        "paired fixture did not authorize receive: {control_sent}"
    );
    let control_received = control.until(deadline, |line| line["type"] == "receive_completed");
    assert_eq!(control_received["success"], true, "{control_received}");
    control.exits(deadline, true);
    assert_eq!(
        fs::read(destination.join("paired-control.txt")).unwrap(),
        b"paired receive control"
    );

    let mut sink = Cli::start(
        "outgoing receiver",
        &sink_config,
        &[
            "--port",
            &sink_port_text,
            "--destination",
            sink_destination.to_str().unwrap(),
            "serve",
            "--stdio",
        ],
    );
    sink.until(deadline, |line| line["event"] == "ready");
    let mut receiver = Cli::start(
        "paired send-mode target",
        &receiver_config,
        &[
            "--port",
            &receiver_port_text,
            "--destination",
            destination.to_str().unwrap(),
            "send",
            "--to",
            "127.0.0.1",
            "--target-port",
            &sink_port_text,
            "--json",
            "--timeout",
            "35",
            outgoing_file.to_str().unwrap(),
        ],
    );
    wait_for_port(receiver_port, deadline);
    let outgoing_request = sink.until(deadline, |line| line["event"] == "receive_request");
    let outgoing_session = outgoing_request["session_id"].as_str().unwrap().to_owned();
    assert!(
        receiver.child.try_wait().unwrap().is_none(),
        "send-mode target exited before policy check"
    );
    sender.write(json!({"id":"paired-send","command":"send","to":"127.0.0.1",
        "target_port":receiver_port,"timeout":20,"paths":[file]}));
    let queued = sender.until(deadline, |line| line["id"] == "paired-send");
    assert_eq!(queued["ok"], true, "{queued}");
    let transfer_id = queued["result"]["transfer_id"].as_str().unwrap().to_owned();
    let completed = sender.until(deadline, |line| {
        line["type"] == "send_completed" && line["transfer_id"] == transfer_id
    });
    assert_eq!(completed["success"], false, "{completed}");
    let decline_deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if sender
            .stderr_lines
            .lock()
            .unwrap()
            .iter()
            .any(|line| line.contains(": Declined"))
        {
            break;
        }
        assert!(
            Instant::now() < decline_deadline,
            "sender did not receive an HTTP 403 decline; stdout: {:?}; stderr: {:?}",
            sender.seen,
            sender.stderr_lines.lock().unwrap()
        );
        thread::sleep(Duration::from_millis(10));
    }
    sink.write(json!({"id":"accept-outgoing","command":"receive_decision",
        "session_id":outgoing_session,"accept":true}));
    let accepted = sink.until(deadline, |line| line["id"] == "accept-outgoing");
    assert_eq!(accepted["result"]["accepted"], true, "{accepted}");
    let outgoing_sent = receiver.until(deadline, |line| line["type"] == "send_completed");
    assert_eq!(outgoing_sent["success"], true, "{outgoing_sent}");
    let outgoing_received = sink.until(deadline, |line| line["event"] == "receive_completed");
    assert_eq!(outgoing_received["success"], true, "{outgoing_received}");
    receiver.exits(deadline, true);
    assert!(!destination.join("paired.txt").exists());
    assert_eq!(
        fs::read(sink_destination.join("outgoing.txt")).unwrap(),
        b"outgoing transfer stays pending"
    );
    sink.write(json!({"id":"stop","command":"shutdown"}));
    assert_eq!(
        sink.until(deadline, |line| line["id"] == "stop")["ok"],
        true
    );
    sink.exits(deadline, true);
    sender.write(json!({"id":"stop","command":"shutdown"}));
    assert_eq!(
        sender.until(deadline, |line| line["id"] == "stop")["ok"],
        true
    );
    sender.exits(deadline, true);
}
