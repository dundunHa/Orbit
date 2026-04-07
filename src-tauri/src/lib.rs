mod anomaly;
mod app;
mod commands;
mod history;
pub mod installer;
mod notch;
mod socket_server;
mod state;
mod tray;

#[cfg(test)]
mod tests;

use tauri::{Emitter, Manager};

#[cfg(target_os = "macos")]
fn register_screen_change_monitor(
    app_handle: tauri::AppHandle,
    initial_geometry: notch::NotchGeometry,
) {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    let last_geometry = Arc::new(std::sync::Mutex::new(initial_geometry));
    let running = Arc::new(AtomicBool::new(true));

    let geometry_clone = last_geometry.clone();
    let running_clone = running.clone();
    let app_handle_clone = app_handle.clone();
    std::thread::spawn(move || {
        let mut last = *geometry_clone.lock().unwrap();
        while running_clone.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_secs(2));

            let current_geometry = notch::get_notch_geometry();
            let should_update = geometry_changed_significantly(&current_geometry, &last);

            if should_update {
                let last_has_notch = last.notch_height > 28.0;
                let current_has_notch = current_geometry.notch_height > 28.0;

                if last_has_notch != current_has_notch {
                    println!(
                        "[Orbit] Display type changed: has_notch={} -> has_notch={}",
                        last_has_notch, current_has_notch
                    );
                } else {
                    println!("[Orbit] Screen configuration changed, updating geometry...");
                }

                *geometry_clone.lock().unwrap() = current_geometry;
                last = current_geometry;
                commands::update_notch_geometry(current_geometry);

                let handle = app_handle_clone.clone();
                tauri::async_runtime::spawn(async move {
                    update_window_for_screen_change(handle, current_geometry).await;
                });
            }
        }
    });

    app_handle.manage(running);
}

#[cfg(target_os = "macos")]
async fn update_window_for_screen_change(
    app_handle: tauri::AppHandle,
    current_geometry: notch::NotchGeometry,
) {
    let current_has_notch = current_geometry.notch_height > 28.0;

    if let Some(window) = app_handle.get_webview_window("main") {
        let pill_width = commands::pill_width_for_geometry(current_geometry);
        let current_height =
            commands::current_window_height_pub(&window).unwrap_or(current_geometry.notch_height);

        commands::set_window_frame_for_geometry_pub(
            &window,
            current_geometry,
            pill_width,
            current_height,
        );

        let _ = app_handle.emit(
            "screen-changed",
            serde_json::json!({
                "notch_height": current_geometry.notch_height,
                "screen_width": current_geometry.screen_width,
                "notch_left": current_geometry.notch_left,
                "notch_right": current_geometry.notch_right,
                "notch_width": current_geometry.notch_width,
                "left_safe_width": current_geometry.left_safe_width,
                "right_safe_width": current_geometry.right_safe_width,
                "has_notch": current_has_notch,
                "pill_width": pill_width,
                "left_zone_width": commands::LEFT_ZONE_WIDTH,
                "right_zone_width": commands::RIGHT_ZONE_WIDTH,
                "mascot_left_inset": commands::MASCOT_LEFT_INSET,
            }),
        );
    }
}

#[cfg(target_os = "macos")]
fn geometry_changed_significantly(a: &notch::NotchGeometry, b: &notch::NotchGeometry) -> bool {
    const THRESHOLD: f64 = 0.1;
    (a.screen_width - b.screen_width).abs() > THRESHOLD
        || (a.notch_height - b.notch_height).abs() > THRESHOLD
        || (a.notch_left - b.notch_left).abs() > THRESHOLD
        || (a.notch_right - b.notch_right).abs() > THRESHOLD
        || (a.notch_width - b.notch_width).abs() > THRESHOLD
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            commands::get_sessions,
            commands::get_history,
            commands::get_notch_info,
            commands::get_onboarding_state,
            commands::permission_decision,
            commands::expand_window,
            commands::set_expanded_height,
            commands::collapse_window,
            commands::retry_onboarding_install,
            commands::resume_session,
        ])
        .setup(|app| {
            // Create shared state BEFORE spawning background tasks
            let app_state = state::AppState::new();
            app.manage(app_state.sessions.clone());
            app.manage(app_state.pending_permissions.clone());
            app.manage(app_state.connection_count.clone());

            let today_stats: state::TodayStats = std::sync::Arc::new(parking_lot::Mutex::new(
                state::TodayTokenStats::load_from_disk(),
            ));
            app.manage(today_stats.clone());

            let orbit_helper_path = installer::resolve_orbit_helper_path();
            let onboarding = app::onboarding::OnboardingManager::new(orbit_helper_path);
            onboarding.start_background_check_with_emitter(app.handle().clone());
            app::conflict_monitor::start_monitor(onboarding.clone());
            app.manage(onboarding.clone());
            tray::init(app.handle(), today_stats.clone())?;

            let handle = app.handle().clone();

            // Position window at notch
            if let Some(window) = app.get_webview_window("main") {
                let notch = notch::get_notch_geometry();
                commands::update_notch_geometry(notch);

                #[cfg(target_os = "macos")]
                register_screen_change_monitor(app.handle().clone(), notch);

                // Set window level above menu bar so it can overlap the notch area
                // Also set collection behavior to show on all Spaces (Mission Control desktops)
                // Hide dock icon - only show in menubar
                #[cfg(target_os = "macos")]
                {
                    use objc2_app_kit::{
                        NSApplication, NSApplicationActivationPolicy, NSView,
                        NSWindowCollectionBehavior,
                    };
                    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

                    // Hide dock icon by setting activation policy to accessory
                    if let Some(mtm) = objc2::MainThreadMarker::new() {
                        let ns_app = NSApplication::sharedApplication(mtm);
                        ns_app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);
                    }

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
                let _ = window.show();
                commands::set_window_frame_for_geometry_pub(
                    &window,
                    notch,
                    commands::pill_width_for_geometry(notch),
                    notch.notch_height,
                );
            }

            // Start socket server in background
            let sessions = app_state.sessions.clone();
            let pending = app_state.pending_permissions.clone();
            let conn_count = app_state.connection_count.clone();
            let today_stats_clone = today_stats.clone();
            let app_handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                socket_server::start(app_handle, sessions, pending, conn_count, today_stats_clone)
                    .await;
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

#[cfg(test)]
mod geometry_tests {
    use super::*;

    #[test]
    fn unchanged_geometry_does_not_trigger_update() {
        let geometry = notch::NotchGeometry::fallback();

        assert!(!geometry_changed_significantly(&geometry, &geometry));
    }
}
