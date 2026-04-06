use crate::state::TodayStats;
use std::{thread, time::Duration};
use tauri::{
    AppHandle, Manager, Runtime,
    image::Image,
    menu::{MenuBuilder, MenuItem},
    tray::TrayIconBuilder,
};

const TRAY_ID: &str = "orbit-tray";
const TOKEN_STATS_MENU_ID: &str = "tray-token-stats";
const TOGGLE_WINDOW_MENU_ID: &str = "tray-toggle-window";
const QUIT_MENU_ID: &str = "tray-quit";
const TOKEN_REFRESH_INTERVAL: Duration = Duration::from_secs(3);

pub fn init<R: tauri::Runtime>(app: &AppHandle<R>, today_stats: TodayStats) -> tauri::Result<()> {
    let token_stats_item = MenuItem::with_id(
        app,
        TOKEN_STATS_MENU_ID,
        token_stats_text(&today_stats),
        false,
        None::<&str>,
    )?;
    let toggle_window_item = MenuItem::with_id(
        app,
        TOGGLE_WINDOW_MENU_ID,
        "显示/隐藏 Orbit",
        true,
        None::<&str>,
    )?;
    let quit_item = MenuItem::with_id(app, QUIT_MENU_ID, "退出", true, None::<&str>)?;

    let menu = MenuBuilder::new(app)
        .item(&token_stats_item)
        .separator()
        .item(&toggle_window_item)
        .item(&quit_item)
        .build()?;

    let icon = load_tray_icon();

    let mut builder = TrayIconBuilder::with_id(TRAY_ID)
        .menu(&menu)
        .tooltip("Orbit")
        .icon_as_template(true)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| {
            if event.id() == TOGGLE_WINDOW_MENU_ID {
                toggle_main_window(app);
            } else if event.id() == QUIT_MENU_ID {
                app.exit(0);
            }
        });

    if let Some(icon) = icon {
        builder = builder.icon(icon);
    } else if let Some(icon) = app.default_window_icon().cloned() {
        builder = builder.icon(icon);
    }

    builder.build(app)?;
    spawn_token_sync(app.clone(), token_stats_item, today_stats);

    Ok(())
}

fn spawn_token_sync<R: tauri::Runtime>(
    app: AppHandle<R>,
    token_stats_item: MenuItem<R>,
    today_stats: TodayStats,
) {
    let _ = app;
    thread::spawn(move || {
        loop {
            thread::sleep(TOKEN_REFRESH_INTERVAL);
            let text = token_stats_text(&today_stats);
            let _ = token_stats_item.set_text(text);
        }
    });
}

fn load_tray_icon() -> Option<Image<'static>> {
    let bytes = include_bytes!("../icons/tray-icon@2x.png");
    Image::from_bytes(bytes).ok()
}

fn token_stats_text(today_stats: &TodayStats) -> String {
    let stats = today_stats.lock();
    let rate_str = if stats.out_rate > 0.1 {
        format!(" ({:.1} tok/s)", stats.out_rate)
    } else {
        String::new()
    };
    format!(
        "today: ↓{} ↑{}{}",
        format_tokens(stats.tokens_in),
        format_tokens(stats.tokens_out),
        rate_str
    )
}

fn format_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

fn toggle_main_window<R: Runtime>(app: &AppHandle<R>) {
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            let _ = window.hide();
        } else {
            let _ = window.show();
            let _ = window.set_focus();
        }
    }
}
