use std::sync::Mutex;
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};

use super::console;
use super::opencode::OpencodeManager;
use super::settings;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaEvent {
    pub reason: String,
    pub provider: String,
    pub title: String,
    pub message: String,
    pub link: Option<String>,
    pub session_id: String,
    pub attempt: u32,
    pub next: u64,
    pub reset_at: Option<u64>,
    pub rotated_to: Option<String>,
    pub at: u64,
}

static LAST_ROTATE: Mutex<Option<Instant>> = Mutex::new(None);
const ROTATE_COOLDOWN: Duration = Duration::from_secs(120);

pub fn spawn(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        loop {
            let port = app.state::<OpencodeManager>().port();
            let outcome = match port {
                Some(port) => stream_once(&app, port).await,
                None => {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    Ok(())
                }
            };
            if let Err(error) = outcome {
                println!("[quota-watcher] {error}");
            }
            // Reconnect either way: a restart swaps the server underneath us.
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
}

async fn stream_once(app: &AppHandle, port: u16) -> Result<(), String> {
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(format!("http://127.0.0.1:{port}/event"))
        .send()
        .await
        .map_err(|e| format!("event stream connect failed: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("event stream returned {}", response.status()));
    }
    println!("[quota-watcher] connected to event stream on :{port}");

    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("event stream read failed: {e}"))?;
        buffer.push_str(&String::from_utf8_lossy(&chunk));
        while let Some(newline) = buffer.find('\n') {
            let line: String = buffer.drain(..=newline).collect();
            let line = line.trim();
            let Some(data) = line.strip_prefix("data:") else {
                continue;
            };
            let data = data.trim();
            if data.is_empty() {
                continue;
            }
            match serde_json::from_str::<Value>(data) {
                Ok(value) => handle_event(app, port, &value).await,
                Err(error) => println!("[quota-watcher] bad event payload: {error}"),
            }
        }
    }
    Err("event stream ended".to_string())
}

async fn handle_event(app: &AppHandle, port: u16, value: &Value) {
    if value.get("type").and_then(Value::as_str) != Some("session.status") {
        return;
    }
    let Some(status) = value.pointer("/properties/status") else {
        return;
    };
    if status.get("type").and_then(Value::as_str) != Some("retry") {
        return;
    }
    let Some(action) = status.get("action") else {
        return;
    };
    let Some(reason) = action.get("reason").and_then(Value::as_str) else {
        return;
    };
    if reason != "free_tier_limit" && reason != "account_rate_limit" {
        return;
    }

    let mut event = QuotaEvent {
        reason: reason.to_string(),
        provider: action
            .get("provider")
            .and_then(Value::as_str)
            .unwrap_or("opencode")
            .to_string(),
        title: action
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("Usage limit reached")
            .to_string(),
        message: action
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        link: action
            .get("link")
            .and_then(Value::as_str)
            .map(str::to_string),
        session_id: value
            .pointer("/properties/sessionID")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        attempt: status.get("attempt").and_then(Value::as_u64).unwrap_or(0) as u32,
        next: status.get("next").and_then(Value::as_u64).unwrap_or(0),
        reset_at: if reason == "free_tier_limit" {
            Some(next_utc_midnight_ms())
        } else {
            None
        },
        rotated_to: None,
        at: now_ms(),
    };

    if settings::load(Some(app)).auto_rotate {
        rotate(app, port, &mut event).await;
    }

    if let Err(error) = app.emit("quota", event.clone()) {
        println!("[quota-watcher] emit failed: {error}");
    }
}

/// Free limits reset at UTC midnight (matches the server's retry-after), the
/// account/Go limit already tells us when to come back.
fn next_utc_midnight_ms() -> u64 {
    let now_secs = now_ms() / 1000;
    let next = (now_secs / 86_400 + 1) * 86_400;
    next * 1000
}

async fn rotate(app: &AppHandle, port: u16, event: &mut QuotaEvent) {
    {
        let mut last = LAST_ROTATE.lock().unwrap();
        if let Some(at) = *last {
            if at.elapsed() < ROTATE_COOLDOWN {
                return;
            }
        }
        *last = Some(Instant::now());
    }

    let Ok(orgs) = console::orgs(port).await else {
        return;
    };
    if orgs.len() < 2 {
        return;
    }

    let mut sorted = orgs;
    sorted.sort_by(|a, b| {
        (&a.account_email, &a.org_id).cmp(&(&b.account_email, &b.org_id))
    });
    let active_index = sorted.iter().position(|org| org.active);
    let next_index = match active_index {
        Some(index) => (index + 1) % sorted.len(),
        None => 0,
    };
    let next = sorted[next_index].clone();
    if next.active {
        return;
    }

    if console::switch(port, &next.account_id, &next.org_id)
        .await
        .is_err()
    {
        return;
    }

    let manager = app.state::<OpencodeManager>();
    manager.stop().await;
    manager.start().await;
    event.rotated_to = Some(format!("{} · {}", next.org_name, next.account_email));
    println!(
        "[quota-watcher] rotated to {} ({})",
        next.org_name, next.account_email
    );
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
