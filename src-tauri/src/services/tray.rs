use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, Wry};

use super::opencode::{OpencodeManager, OpencodeStatus};

pub struct TrayState {
    serve_item: MenuItem<Wry>,
    quota_item: MenuItem<Wry>,
    toggle_item: MenuItem<Wry>,
}

pub fn build(app: &AppHandle) -> Result<TrayState, Box<dyn std::error::Error>> {
    let serve_item = MenuItem::with_id(app, "serve_status", "serve: …", false, None::<&str>)?;
    let quota_item = MenuItem::with_id(app, "quota_status", "quota: ok", false, None::<&str>)?;
    let toggle_item = MenuItem::with_id(app, "toggle_serve", "Start serve", true, None::<&str>)?;
    let show_item = MenuItem::with_id(app, "show", "Show window", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;

    let menu = Menu::with_items(
        app,
        &[
            &serve_item,
            &quota_item,
            &PredefinedMenuItem::separator(app)?,
            &toggle_item,
            &show_item,
            &PredefinedMenuItem::separator(app)?,
            &quit_item,
        ],
    )?;

    let icon = app
        .default_window_icon()
        .ok_or("no default window icon")?
        .clone();

    TrayIconBuilder::with_id("main")
        .tooltip("opencode zero limit")
        .icon(icon)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "quit" => app.exit(0),
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "toggle_serve" => {
                let handle = app.clone();
                tauri::async_runtime::spawn(async move {
                    let manager = handle.state::<OpencodeManager>();
                    let status = manager.status().await;
                    let status = if status.running {
                        manager.stop().await
                    } else {
                        manager.start().await
                    };
                    update_serve(&handle, &status);
                });
            }
            _ => {}
        })
        .build(app)?;

    Ok(TrayState {
        serve_item,
        quota_item,
        toggle_item,
    })
}

/// Called from the serve commands so the tray always reflects the latest state.
pub fn update_serve(app: &AppHandle, status: &OpencodeStatus) {
    let Some(tray) = app.try_state::<TrayState>() else {
        return;
    };
    let label = if !status.running {
        "serve: stopped"
    } else if status.healthy {
        match status.port {
            Some(port) => &format!("serve: healthy :{port}"),
            None => "serve: healthy",
        }
    } else {
        "serve: unhealthy"
    };
    let _ = tray.serve_item.set_text(label);
    let _ = tray
        .toggle_item
        .set_text(if status.running { "Stop serve" } else { "Start serve" });
}

pub fn update_quota(app: &AppHandle, text: &str) {
    let Some(tray) = app.try_state::<TrayState>() else {
        return;
    };
    let _ = tray.quota_item.set_text(format!("quota: {text}"));
}
