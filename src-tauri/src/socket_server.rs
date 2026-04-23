use log::{debug, error, info};
use std::sync::atomic::{AtomicU64, Ordering};
use tauri::Emitter;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::oneshot;

use crate::history;
use crate::hook_debug;
use crate::installer;
use crate::state::{
    ConnectionCount, HookPayload, PendingPermission, PendingPermissions, PermissionDecision,
    Session, SessionMap, StatuslineUpdate, TodayStats,
};

static INTERACTION_ID_COUNTER: AtomicU64 = AtomicU64::new(1);

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
    let seq = INTERACTION_ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{}-interaction-{}-{}", payload.session_id, ts, seq)
}

fn build_interaction_response(
    payload: &HookPayload,
    decision: &PermissionDecision,
) -> Option<serde_json::Value> {
    match payload.hook_event_name.as_str() {
        "PermissionRequest" => build_permission_request_response(
            decision,
            payload.tool_name.as_deref(),
            payload.tool_input.as_ref(),
        ),
        "Elicitation" => build_elicitation_response(&payload.hook_event_name, decision),
        _ => None,
    }
}

fn build_permission_request_response(
    decision: &PermissionDecision,
    tool_name: Option<&str>,
    tool_input: Option<&serde_json::Value>,
) -> Option<serde_json::Value> {
    match decision.normalized_decision() {
        "allow" => {
            let mut response = serde_json::json!({
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": { "behavior": "allow" }
                }
            });

            if tool_name == Some("AskUserQuestion")
                && let Some(updated_input) =
                    build_ask_user_question_updated_input(tool_input, decision.content.as_ref())
            {
                response["hookSpecificOutput"]["decision"]["updatedInput"] = updated_input;
            }

            Some(response)
        }
        "deny" => Some(serde_json::json!({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": { "behavior": "deny" }
            }
        })),
        "passthrough" => None,
        _ => None,
    }
}

fn build_ask_user_question_updated_input(
    tool_input: Option<&serde_json::Value>,
    content: Option<&serde_json::Value>,
) -> Option<serde_json::Value> {
    let mut updated_input = tool_input?.as_object()?.clone();
    let answers = content?.get("answers")?.clone();
    updated_input.insert("answers".to_string(), answers);
    Some(serde_json::Value::Object(updated_input))
}

fn build_elicitation_response(
    hook_event_name: &str,
    decision: &PermissionDecision,
) -> Option<serde_json::Value> {
    match decision.normalized_decision() {
        "accept" => Some(serde_json::json!({
            "hookSpecificOutput": {
                "hookEventName": hook_event_name,
                "action": "accept",
                "content": decision.content.clone().unwrap_or_else(|| serde_json::json!({}))
            }
        })),
        "decline" => Some(serde_json::json!({
            "hookSpecificOutput": {
                "hookEventName": hook_event_name,
                "action": "decline"
            }
        })),
        "cancel" => Some(serde_json::json!({
            "hookSpecificOutput": {
                "hookEventName": hook_event_name,
                "action": "cancel"
            }
        })),
        "passthrough" => None,
        _ => None,
    }
}

fn interaction_decision_for_debug(decision: &PermissionDecision) -> String {
    match (decision.normalized_decision(), decision.reason.as_deref()) {
        ("deny", Some(reason)) if !reason.is_empty() => format!("deny:{reason}"),
        (normalized, _) => normalized.to_string(),
    }
}

async fn write_optional_hook_response(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    response: Option<&serde_json::Value>,
) {
    if let Some(response) = response
        && let Ok(response_bytes) = serde_json::to_vec(response)
    {
        let _ = writer.write_all(&response_bytes).await;
        let _ = writer.flush().await;
    }

    let _ = writer.shutdown().await;
}

fn hook_debug_payload_summary(input: &str) -> String {
    const MAX_CHARS: usize = 2000;
    let mut summary: String = input.chars().take(MAX_CHARS).collect();
    if input.chars().count() > MAX_CHARS {
        summary.push_str("…<truncated>");
    }
    summary
}

async fn clear_session_waiting_for_approval(
    sessions: &SessionMap,
    app_handle: &tauri::AppHandle,
    session_id: &str,
) {
    let mut sessions = sessions.lock().await;
    if let Some(session) = sessions.get_mut(session_id)
        && session.clear_waiting_for_approval()
    {
        let _ = app_handle.emit("session-update", session.clone());
    }
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

                // Increment connection count
                let count = conn_count.fetch_add(1, Ordering::Relaxed) + 1;
                let _ = handle.emit("connection-count", count);

                tauri::async_runtime::spawn(async move {
                    handle_connection(stream, sessions, pending, &handle, &today_stats).await;

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

            let removed = {
                let mut pending = pending.lock().await;
                pending.remove(&perm_id).is_some()
            };
            if removed {
                let _ = app_handle.emit("interaction-resolved", &perm_id);
            }
            clear_session_waiting_for_approval(&sessions, app_handle, session_id).await;
            return;
        }

        if control.get("type").and_then(|v| v.as_str()) == Some("StatuslineUpdate") {
            if let Ok(update) = serde_json::from_str::<StatuslineUpdate>(buf) {
                debug!(
                    "[Orbit] StatuslineUpdate: session={}, tokens_in={}, tokens_out={}, cost=${}",
                    update.session_id, update.tokens_in, update.tokens_out, update.cost_usd
                );
                let mut sessions_guard = sessions.lock().await;
                let session = sessions_guard
                    .entry(update.session_id.clone())
                    .or_insert_with(|| {
                        Session::new(
                            update.session_id.clone(),
                            update.cwd.clone().unwrap_or_default(),
                            update.pid,
                            update.tty.clone(),
                        )
                    });
                session.apply_statusline_update(&update);
                let _ = app_handle.emit("session-update", session.clone());
                refresh_today_stats(&sessions_guard, today_stats);
            }
            return;
        }
    }

    let payload_summary = hook_debug_payload_summary(buf);
    let payload: HookPayload = match serde_json::from_str::<HookPayload>(buf) {
        Ok(p) => {
            info!(
                "[Orbit] Hook event received: {} (session: {})",
                p.hook_event_name, p.session_id
            );
            hook_debug::append_hook_debug_log(
                "socket_server",
                Some(&p.session_id),
                Some(&p.hook_event_name),
                None,
                "hook-received",
                None,
                Some(payload_summary.as_str()),
            );
            p
        }
        Err(e) => {
            error!("[Orbit] Failed to parse hook payload: {e}");
            hook_debug::append_hook_debug_log(
                "socket_server",
                None,
                None,
                None,
                "parse-failed",
                None,
                Some(payload_summary.as_str()),
            );
            return;
        }
    };

    let is_permission_request = payload.hook_event_name == "PermissionRequest";
    let is_elicitation_request = payload.hook_event_name == "Elicitation";
    let is_permission_prompt = payload.hook_event_name == "Notification"
        && payload.notification_type.as_deref() == Some("permission_prompt");
    let is_session_end = payload.hook_event_name == "SessionEnd";
    let is_stop = payload.hook_event_name == "Stop" || payload.hook_event_name == "SubagentStop";
    let session_id = payload.session_id.clone();
    // When payload.agent_id is present, the hook originates from a subagent
    // inside this session (parent/child relationship is authoritative — not a guess).
    let is_subagent_event = payload.agent_id.is_some();

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
    {
        let mut sessions_guard = sessions.lock().await;
        let session = sessions_guard.entry(session_id.clone()).or_insert_with(|| {
            Session::new(
                session_id.clone(),
                payload.cwd.clone(),
                payload.pid,
                payload.tty.clone(),
            )
        });

        if is_subagent_event {
            // Subagent event: update only the per-agent record; parent session's
            // status/tool_count/tokens intentionally unchanged.
            session.apply_subagent_event(&payload);
        } else {
            session.apply_event(&payload);
        }

        if session.title.is_none() {
            session.refresh_title_from_claude();
        }

        // Emit update to frontend
        let _ = app_handle.emit("session-update", session.clone());
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
        sessions_guard
            .get(&session_id)
            .map(|s| s.to_history_entry())
    } else {
        None
    };

    if let Some(entry) = history_entry {
        history::save_entry(entry);
    }

    // Handle permission request / elicitation: wait for Orbit UI to answer.
    if is_permission_request || is_elicitation_request {
        let (tx, rx) = oneshot::channel::<PermissionDecision>();

        let base_perm_id = interaction_request_id(&payload);
        let mut perm_id = base_perm_id.clone();

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

        let mut id_collision = false;
        {
            let mut pending = pending.lock().await;
            while pending.contains_key(&perm_id) {
                id_collision = true;
                let seq = INTERACTION_ID_COUNTER.fetch_add(1, Ordering::Relaxed);
                perm_id = format!("{base_perm_id}-collision-{seq}");
            }

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

        if id_collision {
            hook_debug::append_hook_debug_log(
                "socket_server",
                Some(&payload.session_id),
                Some(&payload.hook_event_name),
                Some(&perm_id),
                "request-id-collision",
                None,
                None,
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
                "cwd": payload.cwd,
                "mode": payload.mode,
                "url": payload.url,
                "mcp_server_name": payload.mcp_server_name,
                "requested_schema": payload.requested_schema,
            }),
        );

        // Wait for user decision (timeout 5 min).
        match tokio::time::timeout(std::time::Duration::from_secs(300), rx).await {
            Ok(Ok(decision)) => {
                let response = build_interaction_response(&payload, &decision);
                let response_json = response.as_ref().map(|value| value.to_string());
                let debug_decision = interaction_decision_for_debug(&decision);

                hook_debug::append_hook_debug_log(
                    "socket_server",
                    Some(&payload.session_id),
                    Some(&payload.hook_event_name),
                    Some(&perm_id),
                    &debug_decision,
                    response_json.as_deref(),
                    None,
                );

                write_optional_hook_response(&mut writer, response.as_ref()).await;
            }
            Ok(Err(_)) => {
                // The responder was dropped before a UI decision arrived.
                let removed = {
                    let mut pending = pending.lock().await;
                    pending.remove(&perm_id).is_some()
                };
                if removed {
                    let _ = app_handle.emit("interaction-timeout", &perm_id);
                    clear_session_waiting_for_approval(&sessions, app_handle, &payload.session_id)
                        .await;
                }
                hook_debug::append_hook_debug_log(
                    "socket_server",
                    Some(&payload.session_id),
                    Some(&payload.hook_event_name),
                    Some(&perm_id),
                    "channel-closed",
                    None,
                    None,
                );
                write_optional_hook_response(&mut writer, None).await;
            }
            Err(_) => {
                // Timeout, remove pending and notify frontend.
                let removed = {
                    let mut pending = pending.lock().await;
                    pending.remove(&perm_id).is_some()
                };
                if removed {
                    let _ = app_handle.emit("interaction-timeout", &perm_id);
                    clear_session_waiting_for_approval(&sessions, app_handle, &payload.session_id)
                        .await;
                }
                hook_debug::append_hook_debug_log(
                    "socket_server",
                    Some(&payload.session_id),
                    Some(&payload.hook_event_name),
                    Some(&perm_id),
                    "timeout",
                    None,
                    None,
                );
                write_optional_hook_response(&mut writer, None).await;
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
            title: None,
            model: None,
            agent_id: None,
            agent_type: None,
            agent_transcript_path: None,
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
            "model": "claude-sonnet-4-20250514",
            "status": "Stewing"
        }"#;

        let update: StatuslineUpdate = serde_json::from_str(json).unwrap();
        assert_eq!(update.session_id, "test-session-abc");
        assert_eq!(update.tokens_in, 1500);
        assert_eq!(update.tokens_out, 800);
        assert_eq!(update.cost_usd, 0.02);
        assert_eq!(update.model, Some("claude-sonnet-4-20250514".to_string()));
        assert_eq!(update.status, Some("Stewing".to_string()));
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
        assert_eq!(update.status, None);
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

    #[test]
    fn test_interaction_request_id_prefers_elicitation_id() {
        let mut payload = create_hook_payload("Elicitation", "session-xyz");
        payload.tool_use_id = Some("toolu_abc123".to_string());
        payload.elicitation_id = Some("elicit_123".to_string());

        assert_eq!(
            interaction_request_id(&payload),
            "session-xyz-elicit_123".to_string()
        );
    }

    #[test]
    fn test_interaction_request_id_prefers_tool_use_id() {
        let mut payload = create_hook_payload("PermissionRequest", "session-xyz");
        payload.tool_use_id = Some("toolu_abc123".to_string());

        assert_eq!(
            interaction_request_id(&payload),
            "session-xyz-toolu_abc123".to_string()
        );
    }

    #[test]
    fn test_interaction_request_id_generates_unique_fallback_ids() {
        let payload = create_hook_payload("PermissionRequest", "session-xyz");
        let ids: std::collections::HashSet<_> =
            (0..512).map(|_| interaction_request_id(&payload)).collect();

        assert_eq!(ids.len(), 512);
        assert!(
            ids.iter()
                .all(|id| id.starts_with("session-xyz-interaction-"))
        );
    }

    fn make_decision(decision: &str) -> PermissionDecision {
        PermissionDecision {
            decision: decision.to_string(),
            reason: None,
            content: None,
        }
    }

    #[test]
    fn test_build_interaction_response_maps_permission_allow_and_deny() {
        let payload = create_hook_payload("PermissionRequest", "test-permission");
        let allow = build_interaction_response(&payload, &make_decision("allow")).unwrap();
        let deny = build_interaction_response(&payload, &make_decision("deny")).unwrap();

        assert_eq!(
            allow["hookSpecificOutput"]["hookEventName"],
            "PermissionRequest"
        );
        assert_eq!(allow["hookSpecificOutput"]["decision"]["behavior"], "allow");
        assert!(
            allow["hookSpecificOutput"]["decision"]
                .get("updatedInput")
                .is_none()
        );
        assert_eq!(
            deny["hookSpecificOutput"]["hookEventName"],
            "PermissionRequest"
        );
        assert_eq!(deny["hookSpecificOutput"]["decision"]["behavior"], "deny");
        assert!(
            deny["hookSpecificOutput"]["decision"]
                .get("message")
                .is_none()
        );
    }

    #[test]
    fn test_build_interaction_response_builds_updated_input_for_ask_user_question() {
        let mut payload = create_hook_payload("PermissionRequest", "test-ask-user-question");
        payload.tool_name = Some("AskUserQuestion".to_string());
        payload.tool_input = Some(serde_json::json!({
            "questions": [{
                "question": "要加吗？",
                "header": "Review 确认",
                "options": [
                    { "label": "全部处理" },
                    { "label": "只加测试" }
                ],
                "multiSelect": false
            }]
        }));
        let decision = PermissionDecision {
            decision: "allow".to_string(),
            reason: None,
            content: Some(serde_json::json!({
                "answers": { "要加吗？": "全部处理" }
            })),
        };

        let response = build_interaction_response(&payload, &decision).unwrap();

        assert_eq!(
            response["hookSpecificOutput"]["decision"]["behavior"],
            "allow"
        );
        assert_eq!(
            response["hookSpecificOutput"]["decision"]["updatedInput"]["questions"][0]["question"],
            "要加吗？"
        );
        assert_eq!(
            response["hookSpecificOutput"]["decision"]["updatedInput"]["answers"]["要加吗？"],
            "全部处理"
        );
    }

    #[test]
    fn test_build_interaction_response_maps_elicitation_accept_cancel_and_passthrough() {
        let payload = create_hook_payload("Elicitation", "test-elicitation");
        let accept = build_interaction_response(
            &payload,
            &PermissionDecision {
                decision: "accept".to_string(),
                reason: None,
                content: Some(serde_json::json!({ "choice": "plan_a" })),
            },
        )
        .unwrap();
        let decline = build_interaction_response(&payload, &make_decision("decline")).unwrap();
        let cancel = build_interaction_response(&payload, &make_decision("cancel")).unwrap();
        let passthrough = build_interaction_response(&payload, &make_decision("passthrough"));

        assert_eq!(accept["hookSpecificOutput"]["hookEventName"], "Elicitation");
        assert_eq!(accept["hookSpecificOutput"]["action"], "accept");
        assert_eq!(accept["hookSpecificOutput"]["content"]["choice"], "plan_a");
        assert_eq!(decline["hookSpecificOutput"]["action"], "decline");
        assert_eq!(cancel["hookSpecificOutput"]["action"], "cancel");
        assert!(passthrough.is_none());
    }

    #[test]
    fn test_build_interaction_response_supports_legacy_permission_ask_passthrough() {
        let payload = create_hook_payload("PermissionRequest", "test-legacy-ask");
        let passthrough = build_interaction_response(&payload, &make_decision("ask"));

        assert!(passthrough.is_none());
    }

    #[test]
    fn test_build_interaction_response_ignores_elicitation_result() {
        let payload = create_hook_payload("ElicitationResult", "test-elicitation-result");
        let response = build_interaction_response(&payload, &make_decision("cancel"));

        assert!(response.is_none());
    }
}
