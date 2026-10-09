use std::path::PathBuf;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

static STORE: OnceLock<PathBuf> = OnceLock::new();

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    /// rotate to the next console org when a quota is hit
    #[serde(default)]
    pub auto_rotate: bool,
    /// spawn `opencode serve` as soon as the app opens
    #[serde(default = "default_true")]
    pub auto_start: bool,
    /// override for the opencode binary, detected automatically when empty
    #[serde(default)]
    pub opencode_bin: Option<String>,
}

fn default_true() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            auto_rotate: false,
            auto_start: true,
            opencode_bin: None,
        }
    }
}

/// Called once at setup so background code without an AppHandle can still
/// reach the settings file.
pub fn init(app: &AppHandle) {
    if STORE.get().is_some() {
        return;
    }
    if let Ok(dir) = app.path().app_config_dir() {
        if std::fs::create_dir_all(&dir).is_ok() {
            let _ = STORE.set(dir.join("settings.json"));
        }
    }
}

fn settings_path(app: Option<&AppHandle>) -> Result<PathBuf, String> {
    if let Some(path) = STORE.get() {
        return Ok(path.clone());
    }
    let app = app.ok_or_else(|| "settings store not initialized".to_string())?;
    init(app);
    STORE
        .get()
        .cloned()
        .ok_or_else(|| "cannot resolve settings.json path".to_string())
}

pub fn load(app: Option<&AppHandle>) -> Settings {
    settings_path(app)
        .ok()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

pub fn save(app: Option<&AppHandle>, settings: &Settings) -> Result<(), String> {
    let path = settings_path(app)?;
    let raw = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    std::fs::write(path, raw).map_err(|e| e.to_string())
}
