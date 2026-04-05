//! System tray integration for Orbit.
//!
//! Keeps the tray menu and title aligned with the current onboarding state.

use crate::app::{
    onboarding::{OnboardingManager, OnboardingState},
    settings,
};
use std::{thread, time::Duration};
use tauri::{
    AppHandle, Manager, Runtime,
    menu::{MenuBuilder, MenuItem},
    tray::{TrayIcon, TrayIconBuilder},
};

const TRAY_ID: &str = "orbit-tray";
const STATUS_MENU_ID: &str = "tray-status";
const OPEN_MENU_ID: &str = "tray-open-main";
const QUIT_MENU_ID: &str = "tray-quit";
const TRAY_POLL_INTERVAL: Duration = Duration::from_millis(500);

pub fn init<R: tauri::Runtime>(
    app: &AppHandle<R>,
    onboarding: OnboardingManager,
) -> tauri::Result<()> {
    let initial_state = onboarding.state();
    let status_item = MenuItem::with_id(
        app,
        STATUS_MENU_ID,
        status_menu_text(&initial_state),
        false,
        None::<&str>,
    )?;
    let open_item = MenuItem::with_id(app, OPEN_MENU_ID, "打开主窗口", true, None::<&str>)?;
    let settings_submenu = settings::build_submenu(app)?;
    let quit_item = MenuItem::with_id(app, QUIT_MENU_ID, "退出", true, None::<&str>)?;

    let menu = MenuBuilder::new(app)
        .item(&status_item)
        .separator()
        .item(&open_item)
        .item(&settings_submenu)
        .item(&quit_item)
        .build()?;

    let mut builder = TrayIconBuilder::with_id(TRAY_ID)
        .menu(&menu)
        .tooltip(initial_state.tray_status().tooltip())
        .title(initial_state.tray_status().emoji())
        .icon_as_template(true)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| {
            if settings::handle_menu_event(app, event.id()) {
                return;
            }

            if event.id() == OPEN_MENU_ID {
                show_main_window(app);
            } else if event.id() == QUIT_MENU_ID {
                app.exit(0);
            }
        });

    if let Some(icon) = app.default_window_icon().cloned() {
        builder = builder.icon(icon);
    }

    let tray = builder.build(app)?;
    apply_state(&tray, &status_item, &initial_state);
    spawn_state_sync(app.clone(), onboarding, status_item);

    Ok(())
}

fn spawn_state_sync<R: tauri::Runtime>(
    app: AppHandle<R>,
    onboarding: OnboardingManager,
    status_item: MenuItem<R>,
) {
    thread::spawn(move || {
        let mut last_state = onboarding.state();

        loop {
            let current_state = onboarding.state();
            if current_state != last_state {
                if let Some(tray) = app.tray_by_id(TRAY_ID) {
                    apply_state(&tray, &status_item, &current_state);
                }
                last_state = current_state;
            }

            thread::sleep(TRAY_POLL_INTERVAL);
        }
    });
}

fn apply_state<R: tauri::Runtime>(
    tray: &TrayIcon<R>,
    status_item: &MenuItem<R>,
    state: &OnboardingState,
) {
    let tray_status = state.tray_status();

    let _ = tray.set_tooltip(Some(tray_status.tooltip()));
    let _ = tray.set_title(Some(tray_status.emoji()));
    let _ = status_item.set_text(status_menu_text(state));
}

fn status_menu_text(state: &OnboardingState) -> String {
    format!("{} {}", state.tray_status().emoji(), state.status_text())
}

fn show_main_window<R: Runtime>(app: &AppHandle<R>) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}
