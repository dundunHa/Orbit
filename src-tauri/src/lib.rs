mod adapter;
mod anomaly;
mod commands;
mod history;
mod notch;
mod socket_server;
mod state;

use tauri::Manager;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            commands::get_sessions,
            commands::get_history,
            commands::permission_decision,
            commands::expand_window,
            commands::collapse_window,
        ])
        .setup(|app| {
            let handle = app.handle().clone();

            // Position window at notch
            if let Some(window) = app.get_webview_window("main") {
                let (x, y) = notch::get_notch_position();
                let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
                let _ = window.show();
            }

            // Start socket server in background
            let app_handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                socket_server::start(app_handle).await;
            });

            // Start anomaly detector
            let app_handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                anomaly::start(app_handle).await;
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Orbit");
}
