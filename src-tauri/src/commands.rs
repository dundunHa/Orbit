use crate::history;
use crate::state::{PermissionDecision, SessionMap, PendingPermissions, Session};

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
    let _ = window.set_size(tauri::PhysicalSize::new(300, 420));
    Ok(())
}

#[tauri::command]
pub async fn collapse_window(window: tauri::WebviewWindow) -> Result<(), String> {
    let _ = window.set_size(tauri::PhysicalSize::new(300, 44));
    Ok(())
}
