use crate::history;
use crate::state::{PermissionDecision, SessionMap, PendingPermissions, Session};

const PILL_WIDTH: f64 = 320.0;
const COLLAPSED_HEIGHT: f64 = 36.0;
const EXPANDED_HEIGHT: f64 = 420.0;

/// Cached screen width from initial notch detection, set during app setup
pub static SCREEN_WIDTH: std::sync::OnceLock<f64> = std::sync::OnceLock::new();

fn center_x() -> f64 {
    let sw = SCREEN_WIDTH.get().copied().unwrap_or(1440.0);
    (sw - PILL_WIDTH) / 2.0
}

#[tauri::command]
pub async fn get_sessions(
    sessions: tauri::State<'_, SessionMap>,
) -> Result<Vec<Session>, String> {
    let sessions = sessions.lock().await;
    Ok(sessions.values().cloned().collect())
}

#[tauri::command]
pub async fn get_history() -> Result<Vec<history::HistoryEntry>, String> {
    Ok(history::load_entries())
}

#[tauri::command]
pub async fn permission_decision(
    perm_id: String,
    decision: String,
    reason: Option<String>,
    pending: tauri::State<'_, PendingPermissions>,
) -> Result<(), String> {
    let mut pending = pending.lock().await;
    if let Some(perm) = pending.remove(&perm_id) {
        let _ = perm.responder.send(PermissionDecision { decision, reason });
    }
    Ok(())
}

#[tauri::command]
pub async fn expand_window(window: tauri::WebviewWindow) -> Result<(), String> {
    let x = center_x();
    let _ = window.set_position(tauri::LogicalPosition::new(x, 0.0));
    let _ = window.set_size(tauri::LogicalSize::new(PILL_WIDTH, EXPANDED_HEIGHT));
    Ok(())
}

#[tauri::command]
pub async fn collapse_window(window: tauri::WebviewWindow) -> Result<(), String> {
    let x = center_x();
    let _ = window.set_position(tauri::LogicalPosition::new(x, 0.0));
    let _ = window.set_size(tauri::LogicalSize::new(PILL_WIDTH, COLLAPSED_HEIGHT));
    Ok(())
}
