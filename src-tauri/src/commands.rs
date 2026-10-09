use tauri::{AppHandle, State};

use crate::services::console::{self, ConsoleOrg, ConsoleState};
use crate::services::opencode::{OpencodeManager, OpencodeStatus};
use crate::services::proxy::{self, ProxyMode, ProxyState};
use crate::services::settings::{self, Settings};
use crate::services::usage::{self, UsageSummary};

fn require_port(manager: &OpencodeManager) -> Result<u16, String> {
    manager
        .port()
        .ok_or_else(|| "opencode serve is not running".to_string())
}

#[tauri::command]
pub async fn opencode_start(
    manager: State<'_, OpencodeManager>,
) -> Result<OpencodeStatus, String> {
    Ok(manager.start().await)
}

#[tauri::command]
pub async fn opencode_status(
    manager: State<'_, OpencodeManager>,
) -> Result<OpencodeStatus, String> {
    Ok(manager.status().await)
}

#[tauri::command]
pub async fn opencode_stop(manager: State<'_, OpencodeManager>) -> Result<OpencodeStatus, String> {
    Ok(manager.stop().await)
}

/// The TUI disposes its instance after a switch so the new console config is
/// loaded — restarting our own serve child has the same effect.
#[tauri::command]
pub async fn opencode_restart(
    manager: State<'_, OpencodeManager>,
) -> Result<OpencodeStatus, String> {
    manager.stop().await;
    Ok(manager.start().await)
}

#[tauri::command]
pub async fn console_state(
    manager: State<'_, OpencodeManager>,
) -> Result<ConsoleState, String> {
    let port = require_port(&manager)?;
    console::state(port).await
}

#[tauri::command]
pub async fn console_orgs(manager: State<'_, OpencodeManager>) -> Result<Vec<ConsoleOrg>, String> {
    let port = require_port(&manager)?;
    console::orgs(port).await
}

#[tauri::command]
pub async fn console_switch(
    manager: State<'_, OpencodeManager>,
    account_id: String,
    org_id: String,
) -> Result<OpencodeStatus, String> {
    let port = require_port(&manager)?;
    console::switch(port, &account_id, &org_id).await?;
    manager.stop().await;
    Ok(manager.start().await)
}

#[tauri::command]
pub async fn console_login() -> Result<String, String> {
    console::login_in_terminal()
}

#[tauri::command]
pub async fn console_logout(email: String) -> Result<String, String> {
    console::logout(&email).await
}

#[tauri::command]
pub fn usage_summary(days: u32) -> Result<UsageSummary, String> {
    usage::summary(days.clamp(1, 365))
}

#[tauri::command]
pub fn settings_get(app: AppHandle) -> Settings {
    settings::load(Some(&app))
}

#[tauri::command]
pub fn settings_set(app: AppHandle, settings: Settings) -> Result<Settings, String> {
    settings::save(Some(&app), &settings)?;
    Ok(settings)
}

#[tauri::command]
pub fn opencode_binary() -> Option<String> {
    crate::services::opencode::resolve_binary().map(|path| path.display().to_string())
}

#[tauri::command]
pub fn proxy_list(app: AppHandle) -> Result<ProxyState, String> {
    proxy::load(Some(&app))
}

#[tauri::command]
pub fn proxy_import(text: String) -> Result<ProxyState, String> {
    proxy::import(&text)
}

#[tauri::command]
pub fn proxy_remove(id: String) -> Result<ProxyState, String> {
    proxy::remove(&id)
}

#[tauri::command]
pub fn proxy_set_enabled(id: String, enabled: bool) -> Result<ProxyState, String> {
    proxy::set_enabled(&id, enabled)
}

#[tauri::command]
pub fn proxy_set_mode(mode: ProxyMode, manual_id: Option<String>) -> Result<ProxyState, String> {
    proxy::set_mode(mode, manual_id)
}

#[tauri::command]
pub async fn proxy_check_all(app: AppHandle) -> Result<ProxyState, String> {
    proxy::check_all(&app).await
}
