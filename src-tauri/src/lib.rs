mod adapter;
mod anomaly;
mod commands;
mod history;
mod notch;
mod socket_server;
mod state;


#[cfg(test)]
mod tests;

use tauri::Manager;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            commands::get_sessions,
            commands::get_history,
            commands::get_notch_info,
            commands::permission_decision,
            commands::expand_window,
            commands::set_expanded_height,
            commands::collapse_window,
            commands::resume_session,
        ])
        .setup(|app| {
            // Create shared state BEFORE spawning background tasks
            let app_state = state::AppState::new();
            app.manage(app_state.sessions.clone());
            app.manage(app_state.pending_permissions.clone());
            app.manage(app_state.connection_count.clone());

            let handle = app.handle().clone();

            // Position window at notch
            if let Some(window) = app.get_webview_window("main") {
                let notch = notch::get_notch_geometry();
                if commands::NOTCH_GEOMETRY.set(notch).is_err() {
                    eprintln!("[Orbit] Failed to set NOTCH_GEOMETRY, already initialized");
                }

                // Set window level above menu bar so it can overlap the notch area
                // Also set collection behavior to show on all Spaces (Mission Control desktops)
                #[cfg(target_os = "macos")]
                {
                    use objc2_app_kit::{NSView, NSWindowCollectionBehavior};
                    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
                    match window.window_handle() {
                        Ok(wh) => {
                            if let RawWindowHandle::AppKit(appkit) = wh.as_raw() {
                                let ns_view = appkit.ns_view.as_ptr() as *mut NSView;
                                unsafe {
                                    if let Some(ns_window) = (*ns_view).window() {
                                        ns_window.setLevel(25);
                                        ns_window.setCollectionBehavior(
                                            NSWindowCollectionBehavior::CanJoinAllSpaces,
                                        );
                                    } else {
                                        eprintln!("[Orbit] Failed to get NSWindow from NSView");
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            eprintln!("[Orbit] Failed to get window handle: {}", e);
                        }
                    }
                }

                // Position at physical screen top and show.
                // Width is derived from the configurable left/right zones plus the notch width.
                commands::set_window_frame_pub(
                    &window,
                    commands::current_pill_width(),
                    notch.notch_height,
                );
                let _ = window.show();
            }

            // Start socket server in background
            let sessions = app_state.sessions.clone();
            let pending = app_state.pending_permissions.clone();
            let conn_count = app_state.connection_count.clone();
            let app_handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                socket_server::start(app_handle, sessions, pending, conn_count).await;
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
