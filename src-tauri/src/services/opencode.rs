use std::net::TcpListener;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use tokio::process::{Child, Command};

#[derive(Debug, Clone, Serialize)]
pub struct OpencodeStatus {
    pub running: bool,
    pub healthy: bool,
    pub port: Option<u16>,
    pub version: Option<String>,
    pub error: Option<String>,
}

struct Inner {
    child: Option<Child>,
    port: Option<u16>,
    error: Option<String>,
}

pub struct OpencodeManager {
    inner: Mutex<Inner>,
}

impl OpencodeManager {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner {
                child: None,
                port: None,
                error: None,
            }),
        }
    }

    pub fn port(&self) -> Option<u16> {
        self.inner.lock().unwrap().port
    }

    fn snapshot(&self) -> (Option<u16>, bool, Option<String>) {
        let inner = self.inner.lock().unwrap();
        (inner.port, inner.child.is_some(), inner.error.clone())
    }

    fn spawn(&self) -> Result<u16, String> {
        let bin = resolve_binary().ok_or_else(|| {
            "opencode binary not found (install opencode or set OPENCODE_BIN)".to_string()
        })?;
        let port = free_port().ok_or_else(|| "no free local port".to_string())?;

        let mut cmd = Command::new(bin);
        cmd.args(["serve", "--port", &port.to_string(), "--hostname", "127.0.0.1"])
            // opencode talks back to its own server over localhost: never route it
            // through an upstream proxy (docs/network warns about routing loops).
            .env("NO_PROXY", "localhost,127.0.0.1")
            .env("no_proxy", "localhost,127.0.0.1")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true);

        // Apply the selected pool proxy, or scrub any proxy inherited from the
        // launching shell so "off" really means direct.
        if let Some(proxy) = crate::services::proxy::select_for_spawn() {
            println!("[opencode] spawning with proxy {proxy}");
            cmd.env("HTTPS_PROXY", &proxy)
                .env("https_proxy", &proxy)
                .env("HTTP_PROXY", &proxy)
                .env("http_proxy", &proxy);
        } else {
            cmd.env_remove("HTTPS_PROXY")
                .env_remove("https_proxy")
                .env_remove("HTTP_PROXY")
                .env_remove("http_proxy");
        }

        let child = cmd.spawn().map_err(|e| format!("failed to spawn opencode serve: {e}"))?;

        let mut inner = self.inner.lock().unwrap();
        inner.child = Some(child);
        inner.port = Some(port);
        inner.error = None;
        Ok(port)
    }

    pub async fn start(&self) -> OpencodeStatus {
        let (port, has_child, _) = self.snapshot();

        // A server we spawned earlier may still be booting — give it a chance
        // before spawning a second one on another port.
        if let (Some(port), true) = (port, has_child) {
            if let Some(version) = wait_healthy(port, 20, 250).await {
                return OpencodeStatus {
                    running: true,
                    healthy: true,
                    port: Some(port),
                    version: Some(version),
                    error: None,
                };
            }
            self.stop().await;
        }

        match self.spawn() {
            Ok(port) => match wait_healthy(port, 40, 250).await {
                Some(version) => OpencodeStatus {
                    running: true,
                    healthy: true,
                    port: Some(port),
                    version: Some(version),
                    error: None,
                },
                None => {
                    let error = "opencode serve did not become healthy in time".to_string();
                    self.set_error(Some(error.clone()));
                    OpencodeStatus {
                        running: true,
                        healthy: false,
                        port: Some(port),
                        version: None,
                        error: Some(error),
                    }
                }
            },
            Err(error) => {
                self.set_error(Some(error.clone()));
                OpencodeStatus {
                    running: false,
                    healthy: false,
                    port: None,
                    version: None,
                    error: Some(error),
                }
            }
        }
    }

    pub async fn status(&self) -> OpencodeStatus {
        let (port, has_child, error) = self.snapshot();
        let Some(port) = port else {
            return OpencodeStatus {
                running: false,
                healthy: false,
                port: None,
                version: None,
                error,
            };
        };

        match probe(port).await {
            Some(version) => OpencodeStatus {
                running: true,
                healthy: true,
                port: Some(port),
                version: Some(version),
                error: None,
            },
            None => OpencodeStatus {
                running: has_child,
                healthy: false,
                port: Some(port),
                version: None,
                error,
            },
        }
    }

    pub async fn stop(&self) -> OpencodeStatus {
        let child = self.inner.lock().unwrap().child.take();
        if let Some(mut child) = child {
            let _ = child.kill().await;
        }
        let mut inner = self.inner.lock().unwrap();
        inner.port = None;
        OpencodeStatus {
            running: false,
            healthy: false,
            port: None,
            version: None,
            error: inner.error.clone(),
        }
    }

    fn set_error(&self, error: Option<String>) {
        self.inner.lock().unwrap().error = error;
    }
}

async fn probe(port: u16) -> Option<String> {
    let url = format!("http://127.0.0.1:{port}/global/health");
    let client = reqwest::Client::builder()
        .timeout(Duration::from_millis(800))
        .build()
        .ok()?;
    let response = client.get(url).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body: serde_json::Value = response.json().await.ok()?;
    body.get("healthy")?.as_bool()?;
    Some(body.get("version")?.as_str()?.to_string())
}

async fn wait_healthy(port: u16, tries: u32, delay_ms: u64) -> Option<String> {
    for _ in 0..tries {
        if let Some(version) = probe(port).await {
            return Some(version);
        }
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
    }
    None
}

fn free_port() -> Option<u16> {
    TcpListener::bind("127.0.0.1:0")
        .ok()?
        .local_addr()
        .ok()
        .map(|addr| addr.port())
}

pub fn resolve_binary() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("OPENCODE_BIN") {
        let path = PathBuf::from(explicit);
        if path.is_file() {
            return Some(path);
        }
    }

    if let Some(configured) = crate::services::settings::load(None).opencode_bin {
        if !configured.is_empty() {
            let path = PathBuf::from(&configured);
            if path.is_file() {
                return Some(path);
            }
        }
    }

    // GUI apps inherit a stripped-down PATH, so ask a login shell first.
    if let Ok(output) = std::process::Command::new("/bin/sh")
        .args(["-lc", "command -v opencode"])
        .output()
    {
        if output.status.success() {
            let found = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !found.is_empty() {
                let path = PathBuf::from(&found);
                if path.is_file() {
                    return Some(path);
                }
            }
        }
    }

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(paths) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&paths).map(|dir| dir.join("opencode")));
    }
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        candidates.push(PathBuf::from(dir).join("opencode"));
    }
    if let Ok(home) = std::env::var("HOME") {
        for rel in [
            ".local/bin",
            ".bun/bin",
            ".cargo/bin",
            ".npm-global/bin",
            ".yarn/bin",
        ] {
            candidates.push(PathBuf::from(&home).join(rel).join("opencode"));
        }
        // nvm: pick the newest installed node version that ships opencode
        if let Ok(versions) = std::fs::read_dir(format!("{home}/.nvm/versions/node")) {
            let mut nodes: Vec<PathBuf> = versions.filter_map(|e| e.ok()).map(|e| e.path()).collect();
            nodes.sort();
            nodes.reverse();
            for node in nodes {
                let bin = node.join("bin").join("opencode");
                if bin.is_file() {
                    candidates.push(bin);
                    break;
                }
            }
        }
    }

    candidates.into_iter().find(|path| path.is_file())
}
