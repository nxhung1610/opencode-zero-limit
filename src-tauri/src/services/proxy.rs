use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use futures_util::future;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

static STORE: OnceLock<PathBuf> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ProxyMode {
    #[default]
    Off,
    Manual,
    Auto,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyHealth {
    pub ok: bool,
    pub latency_ms: Option<u64>,
    pub checked_at: u64,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyEntry {
    pub id: String,
    pub label: String,
    pub url: String,
    pub enabled: bool,
    #[serde(default)]
    pub health: Option<ProxyHealth>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyState {
    pub mode: ProxyMode,
    #[serde(default)]
    pub manual_id: Option<String>,
    #[serde(default)]
    pub proxies: Vec<ProxyEntry>,
    /// account id → proxy id, keeps one sticky IP per account
    #[serde(default)]
    pub bindings: HashMap<String, String>,
}

impl Default for ProxyState {
    fn default() -> Self {
        Self {
            mode: ProxyMode::Off,
            manual_id: None,
            proxies: Vec::new(),
            bindings: HashMap::new(),
        }
    }
}

/// Called once at app setup so the serve child (which has no AppHandle) can
/// still find the store.
pub fn init(app: &AppHandle) {
    if STORE.get().is_some() {
        return;
    }
    if let Ok(dir) = app.path().app_config_dir() {
        if std::fs::create_dir_all(&dir).is_ok() {
            let _ = STORE.set(dir.join("proxies.json"));
        }
    }
}

fn store_path(app: Option<&AppHandle>) -> Result<PathBuf, String> {
    if let Some(path) = STORE.get() {
        return Ok(path.clone());
    }
    let app = app.ok_or_else(|| "proxy store not initialized".to_string())?;
    init(app);
    STORE
        .get()
        .cloned()
        .ok_or_else(|| "cannot resolve proxies.json path".to_string())
}

pub fn load(app: Option<&AppHandle>) -> Result<ProxyState, String> {
    let path = store_path(app)?;
    if !path.is_file() {
        return Ok(ProxyState::default());
    }
    let raw = std::fs::read_to_string(&path).map_err(|e| format!("read proxies.json: {e}"))?;
    serde_json::from_str(&raw).map_err(|e| format!("parse proxies.json: {e}"))
}

pub fn save(app: Option<&AppHandle>, state: &ProxyState) -> Result<(), String> {
    let path = store_path(app)?;
    let raw = serde_json::to_string_pretty(state).map_err(|e| e.to_string())?;
    std::fs::write(path, raw).map_err(|e| format!("write proxies.json: {e}"))
}

fn entry_id(url: &str) -> String {
    let mut hasher = DefaultHasher::new();
    url.hash(&mut hasher);
    format!("px_{:016x}", hasher.finish())
}

fn label_for(url: &str) -> String {
    let without_scheme = url.split("://").nth(1).unwrap_or(url);
    let host_part = without_scheme.rsplit('@').next().unwrap_or(without_scheme);
    host_part.to_string()
}

pub fn import(text: &str) -> Result<ProxyState, String> {
    let mut state = load(None)?;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let url = if line.contains("://") {
            line.to_string()
        } else if line.contains('@') || line.contains(':') {
            format!("http://{line}")
        } else {
            continue;
        };
        if url.split("://").nth(1).map(|rest| rest.contains(':')) != Some(true) {
            continue;
        }
        let id = entry_id(&url);
        if state.proxies.iter().any(|entry| entry.id == id) {
            continue;
        }
        state.proxies.push(ProxyEntry {
            label: label_for(&url),
            id,
            url,
            enabled: true,
            health: None,
        });
    }
    save(None, &state)?;
    Ok(state)
}

pub fn remove(id: &str) -> Result<ProxyState, String> {
    let mut state = load(None)?;
    state.proxies.retain(|entry| entry.id != id);
    if state.manual_id.as_deref() == Some(id) {
        state.manual_id = None;
    }
    state.bindings.retain(|_, proxy_id| proxy_id != id);
    save(None, &state)?;
    Ok(state)
}

pub fn set_enabled(id: &str, enabled: bool) -> Result<ProxyState, String> {
    let mut state = load(None)?;
    if let Some(entry) = state.proxies.iter_mut().find(|entry| entry.id == id) {
        entry.enabled = enabled;
    }
    save(None, &state)?;
    Ok(state)
}

pub fn set_mode(mode: ProxyMode, manual_id: Option<String>) -> Result<ProxyState, String> {
    let mut state = load(None)?;
    state.mode = mode;
    state.manual_id = manual_id.filter(|id| state.proxies.iter().any(|entry| entry.id == *id));
    if state.mode == ProxyMode::Manual && state.manual_id.is_none() {
        state.mode = ProxyMode::Off;
    }
    save(None, &state)?;
    Ok(state)
}

pub async fn check(url: &str) -> ProxyHealth {
    let started = Instant::now();
    let checked_at = now_ms();
    let proxy = match reqwest::Proxy::all(url) {
        Ok(proxy) => proxy,
        Err(error) => {
            return ProxyHealth {
                ok: false,
                latency_ms: None,
                checked_at,
                error: Some(error.to_string()),
            }
        }
    };
    let client = match reqwest::Client::builder()
        .proxy(proxy)
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(8))
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            return ProxyHealth {
                ok: false,
                latency_ms: None,
                checked_at,
                error: Some(error.to_string()),
            }
        }
    };

    match client
        .get("https://www.gstatic.com/generate_204")
        .send()
        .await
    {
        Ok(response) if response.status().is_success() => ProxyHealth {
            ok: true,
            latency_ms: Some(started.elapsed().as_millis() as u64),
            checked_at,
            error: None,
        },
        Ok(response) => ProxyHealth {
            ok: false,
            latency_ms: None,
            checked_at,
            error: Some(format!("HTTP {}", response.status())),
        },
        Err(error) => ProxyHealth {
            ok: false,
            latency_ms: None,
            checked_at,
            error: Some(error.to_string()),
        },
    }
}

pub async fn check_all(app: &AppHandle) -> Result<ProxyState, String> {
    let mut state = load(Some(app))?;
    let targets: Vec<(String, String)> = state
        .proxies
        .iter()
        .filter(|entry| entry.enabled)
        .map(|entry| (entry.id.clone(), entry.url.clone()))
        .collect();

    let checks = targets
        .into_iter()
        .map(|(id, url)| async move { (id, check(&url).await) });
    let results = future::join_all(checks).await;

    for (id, health) in results {
        if let Some(entry) = state.proxies.iter_mut().find(|entry| entry.id == id) {
            entry.health = Some(health);
        }
    }
    save(Some(app), &state)?;
    Ok(state)
}

/// Proxy for the next `opencode serve` spawn. Never returns an env the server
/// itself would loop through — `NO_PROXY` is set separately by the spawner.
pub fn select_for_spawn() -> Option<String> {
    let state = load(None).ok()?;
    match state.mode {
        ProxyMode::Off => None,
        ProxyMode::Manual => state
            .manual_id
            .as_ref()
            .and_then(|id| state.proxies.iter().find(|entry| &entry.id == id))
            .filter(|entry| entry.enabled)
            .map(|entry| entry.url.clone()),
        ProxyMode::Auto => {
            let account = active_account_key();
            let mut state = state;
            // owned copies so the binding can be written back without
            // fighting the borrow checker over `state.proxies`
            let usable: Vec<(String, String)> = state
                .proxies
                .iter()
                .filter(|entry| {
                    entry.enabled && entry.health.as_ref().map(|h| h.ok).unwrap_or(true)
                })
                .map(|entry| (entry.id.clone(), entry.url.clone()))
                .collect();
            if usable.is_empty() {
                return None;
            }

            if let Some(bound_id) = state.bindings.get(&account) {
                if let Some((_, url)) = usable.iter().find(|(id, _)| id == bound_id) {
                    return Some(url.clone());
                }
            }

            // Sticky per account: take a proxy nobody else holds, else first.
            let free = usable
                .iter()
                .find(|(id, _)| !state.bindings.values().any(|bound| bound == id));
            let (chosen_id, chosen_url) = free.unwrap_or(&usable[0]);

            state.bindings.insert(account, chosen_id.clone());
            if save(None, &state).is_err() {
                println!("[proxy] failed to persist binding");
            }
            Some(chosen_url.clone())
        }
    }
}

fn active_account_key() -> String {
    let path = crate::services::usage::db_path();
    let Ok(conn) = rusqlite::Connection::open_with_flags(
        &path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    ) else {
        return "anonymous".to_string();
    };
    conn.query_row(
        "SELECT active_account_id FROM account_state WHERE id = 1",
        [],
        |row| row.get::<_, Option<String>>(0),
    )
    .ok()
    .flatten()
    .unwrap_or_else(|| "anonymous".to_string())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
