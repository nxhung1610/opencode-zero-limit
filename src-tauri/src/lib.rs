mod commands;
mod services;

pub use services::opencode::OpencodeManager;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(OpencodeManager::new())
        .setup(|app| {
            let handle = app.handle().clone();
            services::settings::init(&handle);
            services::proxy::init(&handle);
            services::watcher::spawn(handle.clone());
            // Keep opencode serve running whenever the app is open — quota
            // monitoring and account switching both go through it.
            if services::settings::load(Some(&handle)).auto_start {
                tauri::async_runtime::spawn(async move {
                    let status = handle.state::<OpencodeManager>().start().await;
                    if let Some(error) = status.error {
                        println!("[opencode] serve failed: {error}");
                    }
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::opencode_start,
            commands::opencode_status,
            commands::opencode_stop,
            commands::opencode_restart,
            commands::console_state,
            commands::console_orgs,
            commands::console_switch,
            commands::console_login,
            commands::console_logout,
            commands::usage_summary,
            commands::settings_get,
            commands::settings_set,
            commands::opencode_binary,
            commands::proxy_list,
            commands::proxy_import,
            commands::proxy_remove,
            commands::proxy_set_enabled,
            commands::proxy_set_mode,
            commands::proxy_check_all,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
