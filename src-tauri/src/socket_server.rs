use log::{debug, error, info};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use tauri::Emitter;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::oneshot;

use crate::history;
use crate::installer;
use crate::state::{
    ConnectionCount, HookPayload, PendingPermission, PendingPermissions, PermissionDecision,
    Session, SessionMap, StatuslineUpdate, TodayStats,
};

type PendingSpawns = Arc<tokio::sync::Mutex<Vec<(String, String, chrono::DateTime<chrono::Utc>)>>>;

fn cleanup_pending_spawns(
    pending_spawns: &mut Vec<(String, String, chrono::DateTime<chrono::Utc>)>,
    now: chrono::DateTime<chrono::Utc>,
) {
    pending_spawns.retain(|(_, _, ts)| now.signed_duration_since(*ts).num_seconds() <= 30);
}

fn match_pending_parent(
    pending_spawns: &mut Vec<(String, String, chrono::DateTime<chrono::Utc>)>,
    child_session_id: &str,
    child_cwd: &str,
    now: chrono::DateTime<chrono::Utc>,
) -> Option<String> {
    if child_cwd.is_empty() {
        return None;
    }

    let index = pending_spawns.iter().rposition(|(_, cwd, ts)| {
        cwd == child_cwd && now.signed_duration_since(*ts).num_seconds() <= 10
    });

    index.and_then(|idx| {
        let (parent_session_id, _, _) = pending_spawns.remove(idx);
        if parent_session_id == child_session_id {
            None
        } else {
            Some(parent_session_id)
        }
    })
}

fn interaction_request_id(payload: &HookPayload) -> String {
    if let Some(elicitation_id) = payload.elicitation_id.as_deref()
        && !elicitation_id.is_empty()
    {
        return format!("{}-{}", payload.session_id, elicitation_id);
    }

    if let Some(tool_use_id) = payload.tool_use_id.as_deref()
        && !tool_use_id.is_empty()
    {
        return format!("{}-{}", payload.session_id, tool_use_id);
    }

    let ts = chrono::Utc::now().timestamp_millis();
    format!("{}-interaction-{}", payload.session_id, ts)
}

pub async fn start(
    app_handle: tauri::AppHandle,
    sessions: SessionMap,
    pending: PendingPermissions,
    conn_count: ConnectionCount,
    today_stats: TodayStats,
) {
    let socket_path = installer::socket_path();
    info!("[Orbit] Starting socket server on {}", socket_path);
    let pending_spawns: PendingSpawns = Arc::new(tokio::sync::Mutex::new(Vec::new()));

    // Remove stale socket
    let _ = std::fs::remove_file(&socket_path);

    let listener = match UnixListener::bind(&socket_path) {
        Ok(l) => {
            info!("[Orbit] Socket server listening on {}", socket_path);
            l
        }
        Err(e) => {
            error!("[Orbit] Failed to bind socket: {e}");
            return;
        }
    };

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let sessions = sessions.clone();
                let pending = pending.clone();
                let handle = app_handle.clone();
                let conn_count = conn_count.clone();
                let today_stats = today_stats.clone();
                let pending_spawns = pending_spawns.clone();

                // Increment connection count
                let count = conn_count.fetch_add(1, Ordering::Relaxed) + 1;
                let _ = handle.emit("connection-count", count);

                tauri::async_runtime::spawn(async move {
                    handle_connection(
                        stream,
                        sessions,
                        pending,
                        pending_spawns,
                        &handle,
                        &today_stats,
                    )
                    .await;

                    // Decrement connection count when done (guard against underflow)
                    let prev = conn_count.load(Ordering::Relaxed);
                    let count = if prev > 0 {
                        conn_count.fetch_sub(1, Ordering::Relaxed) - 1
                    } else {
                        0
                    };
                    let _ = handle.emit("connection-count", count);
                });
            }
            Err(e) => {
                if e.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                eprintln!("Socket accept error (fatal): {e}");
                break;
            }
        }
    }
}

async fn handle_connection(
    stream: tokio::net::UnixStream,
    sessions: SessionMap,
    pending: PendingPermissions,
    pending_spawns: PendingSpawns,
    app_handle: &tauri::AppHandle,
    today_stats: &TodayStats,
) {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut buf = String::new();

    // Read exactly one newline-terminated JSON line
    if reader.read_line(&mut buf).await.is_err() {
        return;
    }

    let buf = buf.trim();
    if buf.is_empty() {
        return;
    }

    debug!("[Orbit] Raw socket payload: {}", buf);

    if let Ok(control) = serde_json::from_str::<serde_json::Value>(buf) {
        if control.get("type").and_then(|v| v.as_str()) == Some("PermissionRequestHandledByCli") {
            let session_id = control
                .get("session_id")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let tool_use_id = control
                .get("tool_use_id")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            let perm_id = format!("{}-{}", session_id, tool_use_id);

            info!("[Orbit] Permission handled by helper: {}", perm_id);

            let mut pending = pending.lock().await;
            if pending.remove(&perm_id).is_some() {
                let _ = app_handle.emit("interaction-resolved", &perm_id);
            }
            return;
        }

        if control.get("type").and_then(|v| v.as_str()) == Some("StatuslineUpdate") {
            if let Ok(update) = serde_json::from_str::<StatuslineUpdate>(buf) {
                debug!(
                    "[Orbit] StatuslineUpdate: session={}, tokens_in={}, tokens_out={}, cost=${}",
                    update.session_id, update.tokens_in, update.tokens_out, update.cost_usd
                );
                let mut sessions_guard = sessions.lock().await;
                if let Some(session) = sessions_guard.get_mut(&update.session_id) {
                    session.apply_statusline_update(&update);
                    let _ = app_handle.emit("session-update", session.clone());
                }
                refresh_today_stats(&sessions_guard, today_stats);
            }
            return;
        }
    }

    let payload: HookPayload = match serde_json::from_str::<HookPayload>(buf) {
        Ok(p) => {
            info!(
                "[Orbit] Hook event received: {} (session: {})",
                p.hook_event_name, p.session_id
            );
            p
        }
        Err(e) => {
            error!("[Orbit] Failed to parse hook payload: {e}");
            return;
        }
    };

    let is_permission_request = payload.hook_event_name == "PermissionRequest";
    let is_elicitation_request = payload.hook_event_name == "Elicitation";
    let is_permission_prompt = payload.hook_event_name == "Notification"
        && payload.notification_type.as_deref() == Some("permission_prompt");
    let is_session_end = payload.hook_event_name == "SessionEnd";
    let is_stop = payload.hook_event_name == "Stop" || payload.hook_event_name == "SubagentStop";
    let is_task_pre_tool_use =
        payload.hook_event_name == "PreToolUse" && payload.tool_name.as_deref() == Some("Task");
    let session_id = payload.session_id.clone();

    let parent_for_new_session = {
        let sessions_guard = sessions.lock().await;
        if sessions_guard.contains_key(&session_id) {
            None
        } else {
            drop(sessions_guard);
            let now = chrono::Utc::now();
            let mut pending_spawns_guard = pending_spawns.lock().await;
            cleanup_pending_spawns(&mut pending_spawns_guard, now);
            match_pending_parent(
                &mut pending_spawns_guard,
                &session_id,
                &payload.cwd,
                now,
            )
        }
    };

    if is_session_end {
        info!(
            "[Orbit] Session ending: {} (SessionEnd hook received)",
            session_id
        );
    }
    if is_stop {
        info!(
            "[Orbit] LLM generation stopped: {} (Stop/SubagentStop hook received)",
            session_id
        );
    }

    // Update session state
    let mut pending_parent_candidate: Option<(String, String, chrono::DateTime<chrono::Utc>)> = None;
    {
        let mut sessions_guard = sessions.lock().await;
        let session = sessions_guard.entry(session_id.clone()).or_insert_with(|| {
            let mut session = Session::new(
                session_id.clone(),
                payload.cwd.clone(),
                payload.pid,
                payload.tty.clone(),
            );
            session.parent_session_id = parent_for_new_session.clone();
            session
        });
        session.apply_event(&payload);

        if is_task_pre_tool_use {
            pending_parent_candidate = Some((
                session.id.clone(),
                session.cwd.clone(),
                chrono::Utc::now(),
            ));
        }

        if session.title.is_none() {
            session.refresh_title_from_claude();
        }

        // Emit update to frontend
        let _ = app_handle.emit("session-update", session.clone());
    }

    if let Some(candidate) = pending_parent_candidate {
        let now = chrono::Utc::now();
        let mut pending_spawns_guard = pending_spawns.lock().await;
        cleanup_pending_spawns(&mut pending_spawns_guard, now);
        pending_spawns_guard.push(candidate);
    }

    if is_permission_prompt {
        let _ = app_handle.emit(
            "permission-prompt",
            serde_json::json!({
                "session_id": payload.session_id,
                "message": payload.message,
            }),
        );
    }

    // Write history outside the lock to avoid blocking tokio worker
    let history_entry = if is_session_end {
        let sessions_guard = sessions.lock().await;
        if let Some(session) = sessions_guard.get(&session_id) {
            let duration = (session.last_event_at - session.started_at)
                .num_seconds()
                .max(0);
            Some(history::HistoryEntry {
                session_id: session.id.clone(),
                parent_session_id: session.parent_session_id.clone(),
                cwd: session.cwd.clone(),
                started_at: session.started_at,
                ended_at: session.last_event_at,
                tool_count: session.tool_count,
                duration_secs: duration,
                title: session.title.clone().unwrap_or_default(),
                tokens_in: session.tokens_in,
                tokens_out: session.tokens_out,
                cost_usd: session.cost_usd,
                model: session.model.clone(),
            })
        } else {
            None
        }
    } else {
        None
    };

    if let Some(entry) = history_entry {
        history::save_entry(entry);
    }

    // Handle permission request / elicitation: wait for Orbit UI to answer.
    if is_permission_request || is_elicitation_request {
        let (tx, rx) = oneshot::channel::<PermissionDecision>();

        let perm_id = interaction_request_id(&payload);

        let kind = if is_permission_request {
            "permission"
        } else {
            "elicitation"
        };
        let tool_name = if is_permission_request {
            payload.tool_name.clone().unwrap_or_default()
        } else {
            payload
                .mcp_server_name
                .clone()
                .unwrap_or_else(|| "Question".to_string())
        };
        let tool_input = if is_permission_request {
            payload
                .tool_input
                .clone()
                .unwrap_or(serde_json::Value::Null)
        } else {
            serde_json::json!({
                "mode": payload.mode.clone(),
                "requested_schema": payload.requested_schema.clone(),
                "url": payload.url.clone(),
                "message": payload.message.clone(),
            })
        };

        {
            let mut pending = pending.lock().await;
            pending.insert(
                perm_id.clone(),
                PendingPermission {
                    session_id: payload.session_id.clone(),
                    tool_name: tool_name.clone(),
                    tool_input: tool_input.clone(),
                    responder: tx,
                },
            );
        }

        // Emit interaction request to frontend with full details.
        let _ = app_handle.emit(
            "interaction-request",
            serde_json::json!({
                "request_id": perm_id,
                "session_id": payload.session_id,
                "kind": kind,
                "tool_name": tool_name,
                "tool_input": tool_input,
                "message": payload.message,
                "mode": payload.mode,
                "url": payload.url,
                "mcp_server_name": payload.mcp_server_name,
                "requested_schema": payload.requested_schema,
            }),
        );

        // Wait for user decision (timeout 5 min).
        match tokio::time::timeout(std::time::Duration::from_secs(300), rx).await {
            Ok(Ok(decision)) => {
                let response = if is_permission_request {
                    match decision.decision.as_str() {
                        "allow" => Some(serde_json::json!({
                            "hookSpecificOutput": {
                                "hookEventName": "PermissionRequest",
                                "decision": { "behavior": "allow" }
                            }
                        })),
                        "deny" => Some(serde_json::json!({
                            "hookSpecificOutput": {
                                "hookEventName": "PermissionRequest",
                                "decision": {
                                    "behavior": "deny",
                                    "message": decision.reason.unwrap_or_else(|| "Denied via Orbit".to_string())
                                }
                            }
                        })),
                        _ => Some(serde_json::json!({
                            "hookSpecificOutput": {
                                "hookEventName": "PermissionRequest",
                                "decision": { "behavior": "ask" }
                            }
                        })),
                    }
                } else {
                    match decision.decision.as_str() {
                        "accept" => Some(serde_json::json!({
                            "hookSpecificOutput": {
                                "hookEventName": "Elicitation",
                                "action": "accept",
                                "content": decision.content.unwrap_or_else(|| serde_json::json!({}))
                            }
                        })),
                        "decline" => Some(serde_json::json!({
                            "hookSpecificOutput": {
                                "hookEventName": "Elicitation",
                                "action": "decline"
                            }
                        })),
                        "cancel" => Some(serde_json::json!({
                            "hookSpecificOutput": {
                                "hookEventName": "Elicitation",
                                "action": "cancel"
                            }
                        })),
                        _ => None,
                    }
                };

                if let Some(response) = response {
                    let response_bytes = serde_json::to_vec(&response).unwrap_or_default();
                    let _ = writer.write_all(&response_bytes).await;
                }
            }
            _ => {
                // Timeout or error, remove pending and notify frontend.
                let mut pending = pending.lock().await;
                pending.remove(&perm_id);
                let _ = app_handle.emit("interaction-timeout", &perm_id);
            }
        }
    }
}

fn refresh_today_stats(
    sessions: &std::collections::HashMap<String, Session>,
    today_stats: &TodayStats,
) {
    let mut stats = today_stats.lock();
    stats.reset_if_new_day();

    let today = chrono::Local::now().date_naive();
    let (mut total_in, mut total_out) = (0u64, 0u64);
    for s in sessions.values() {
        let session_date = s.last_event_at.with_timezone(&chrono::Local).date_naive();
        if session_date == today {
            let (delta_in, delta_out) = stats.session_today_delta(&s.id, s.tokens_in, s.tokens_out);
            total_in += delta_in;
            total_out += delta_out;
        }
    }

    stats.tokens_in = total_in;
    stats.tokens_out = total_out;
    stats.update_rate(total_out);
    stats.save_to_disk();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{HookPayload, Session, SessionStatus};

    fn create_hook_payload(event: &str, session_id: &str) -> HookPayload {
        HookPayload {
            session_id: session_id.to_string(),
            hook_event_name: event.to_string(),
            cwd: "/tmp".to_string(),
            tool_name: None,
            tool_input: None,
            tool_use_id: None,
            tool_response: None,
            mcp_server_name: None,
            notification_type: None,
            message: None,
            mode: None,
            url: None,
            elicitation_id: None,
            requested_schema: None,
            action: None,
            content: None,
            pid: None,
            tty: None,
            status: None,
        }
    }

    #[test]
    fn test_hook_payload_session_end_parsing() {
        let json = r#"{
            "session_id": "test-session-123",
            "hook_event_name": "SessionEnd",
            "cwd": "/home/user/project"
        }"#;

        let payload: HookPayload = serde_json::from_str(json).unwrap();
        assert_eq!(payload.session_id, "test-session-123");
        assert_eq!(payload.hook_event_name, "SessionEnd");
        assert_eq!(payload.cwd, "/home/user/project");
    }

    #[test]
    fn test_hook_payload_stop_parsing() {
        let json = r#"{
            "session_id": "test-session-456",
            "hook_event_name": "Stop",
            "cwd": "/tmp"
        }"#;

        let payload: HookPayload = serde_json::from_str(json).unwrap();
        assert_eq!(payload.hook_event_name, "Stop");
    }

    #[test]
    fn test_hook_payload_subagent_stop_parsing() {
        let json = r#"{
            "session_id": "test-session-789",
            "hook_event_name": "SubagentStop",
            "cwd": "/workspace"
        }"#;

        let payload: HookPayload = serde_json::from_str(json).unwrap();
        assert_eq!(payload.hook_event_name, "SubagentStop");
    }

    #[test]
    fn test_hook_payload_statusline_update_parsing() {
        let json = r#"{
            "type": "StatuslineUpdate",
            "session_id": "test-session-abc",
            "tokens_in": 1500,
            "tokens_out": 800,
            "cost_usd": 0.02,
            "model": "claude-sonnet-4-20250514"
        }"#;

        let update: StatuslineUpdate = serde_json::from_str(json).unwrap();
        assert_eq!(update.session_id, "test-session-abc");
        assert_eq!(update.tokens_in, 1500);
        assert_eq!(update.tokens_out, 800);
        assert_eq!(update.cost_usd, 0.02);
        assert_eq!(update.model, Some("claude-sonnet-4-20250514".to_string()));
    }

    #[test]
    fn test_hook_payload_elicitation_parsing() {
        let json = r#"{
            "session_id": "test-session-elicitation",
            "hook_event_name": "Elicitation",
            "cwd": "/tmp",
            "mcp_server_name": "compound",
            "message": "请选择方案",
            "mode": "form",
            "elicitation_id": "elicit-123",
            "requested_schema": {
                "type": "object",
                "properties": {
                    "choice": {
                        "type": "string",
                        "enum": ["plan_a", "plan_b"]
                    }
                }
            }
        }"#;

        let payload: HookPayload = serde_json::from_str(json).unwrap();
        assert_eq!(payload.hook_event_name, "Elicitation");
        assert_eq!(payload.mcp_server_name.as_deref(), Some("compound"));
        assert_eq!(payload.mode.as_deref(), Some("form"));
        assert_eq!(payload.elicitation_id.as_deref(), Some("elicit-123"));
    }

    #[test]
    fn test_session_applies_session_end_event() {
        let mut session = Session::new("test-123".to_string(), "/tmp".to_string(), None, None);
        let payload = create_hook_payload("SessionEnd", "test-123");

        session.apply_event(&payload);

        assert!(matches!(session.status, SessionStatus::Ended));
    }

    #[test]
    fn test_session_applies_stop_event() {
        let mut session = Session::new("test-456".to_string(), "/tmp".to_string(), None, None);

        session.apply_event(&create_hook_payload("UserPromptSubmit", "test-456"));
        assert!(matches!(session.status, SessionStatus::Processing));

        session.apply_event(&create_hook_payload("Stop", "test-456"));
        assert!(matches!(session.status, SessionStatus::WaitingForInput));
    }

    #[test]
    fn test_session_applies_subagent_stop_event() {
        let mut session = Session::new("test-789".to_string(), "/tmp".to_string(), None, None);

        session.apply_event(&create_hook_payload("UserPromptSubmit", "test-789"));
        assert!(matches!(session.status, SessionStatus::Processing));

        session.apply_event(&create_hook_payload("SubagentStop", "test-789"));
        assert!(matches!(session.status, SessionStatus::WaitingForInput));
    }

    #[test]
    fn test_session_applies_elicitation_event() {
        let mut session = Session::new("test-elicit".to_string(), "/tmp".to_string(), None, None);
        let mut payload = create_hook_payload("Elicitation", "test-elicit");
        payload.mcp_server_name = Some("compound".to_string());
        payload.message = Some("请选择方案".to_string());
        payload.mode = Some("form".to_string());
        payload.requested_schema = Some(serde_json::json!({
            "type": "object",
            "properties": {
                "choice": { "type": "string", "enum": ["a", "b"] }
            }
        }));

        session.apply_event(&payload);

        assert!(matches!(
            session.status,
            SessionStatus::WaitingForApproval { .. }
        ));
    }

    #[test]
    fn test_statusline_update_default_model() {
        let json = r#"{
            "session_id": "test-session",
            "tokens_in": 100,
            "tokens_out": 200,
            "cost_usd": 0.01
        }"#;

        let update: StatuslineUpdate = serde_json::from_str(json).unwrap();
        assert_eq!(update.model, None);
        assert_eq!(update.tokens_in, 100);
    }

    #[test]
    fn test_permission_request_handled_by_cli_parsing() {
        let json = r#"{
            "type": "PermissionRequestHandledByCli",
            "session_id": "session-xyz",
            "tool_use_id": "toolu_abc123"
        }"#;

        let control: serde_json::Value = serde_json::from_str(json).unwrap();
        assert_eq!(
            control.get("type").and_then(|v| v.as_str()),
            Some("PermissionRequestHandledByCli")
        );
        assert_eq!(
            control.get("session_id").and_then(|v| v.as_str()),
            Some("session-xyz")
        );
    }
}
