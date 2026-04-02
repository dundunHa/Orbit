use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::oneshot;
use tauri::Emitter;

use crate::history;
use crate::state::{HookPayload, PendingPermission, PermissionDecision, Session, SessionMap, PendingPermissions};

const SOCKET_PATH: &str = "/tmp/orbit.sock";

pub async fn start(
    app_handle: tauri::AppHandle,
    sessions: SessionMap,
    pending: PendingPermissions,
) {
    // Remove stale socket
    let _ = std::fs::remove_file(SOCKET_PATH);

    let listener = match UnixListener::bind(SOCKET_PATH) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("Failed to bind socket: {e}");
            return;
        }
    };

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let sessions = sessions.clone();
                let pending = pending.clone();
                let handle = app_handle.clone();

                tauri::async_runtime::spawn(async move {
                    handle_connection(stream, sessions, pending, &handle).await;
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

    let payload: HookPayload = match serde_json::from_str(buf) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Failed to parse payload: {e}");
            return;
        }
    };

    let is_permission_request = payload.hook_event_name == "PermissionRequest";
    let is_session_end = payload.hook_event_name == "SessionEnd";

    // Update session state
    {
        let mut sessions = sessions.lock().await;
        let session = sessions
            .entry(payload.session_id.clone())
            .or_insert_with(|| {
                Session::new(
                    payload.session_id.clone(),
                    payload.cwd.clone(),
                    payload.pid,
                    payload.tty.clone(),
                )
            });
        session.apply_event(&payload);

        // Emit update to frontend
        let _ = app_handle.emit("session-update", session.clone());

        // Save history on session end
        if is_session_end {
            let duration = (session.last_event_at - session.started_at).num_seconds().max(0);
            history::save_entry(history::HistoryEntry {
                session_id: session.id.clone(),
                cwd: session.cwd.clone(),
                started_at: session.started_at,
                ended_at: session.last_event_at,
                tool_count: session.tool_count,
                duration_secs: duration,
            });
        }
    }

    // Handle permission request: wait for user decision
    if is_permission_request {
        let (tx, rx) = oneshot::channel::<PermissionDecision>();

        let perm_id = format!(
            "{}-{}",
            payload.session_id,
            payload.tool_use_id.as_deref().unwrap_or("unknown")
        );

        let tool_name = payload.tool_name.clone().unwrap_or_default();
        let tool_input = payload.tool_input.clone().unwrap_or(serde_json::Value::Null);

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

        // Emit permission request to frontend with full details
        let _ = app_handle.emit(
            "permission-request",
            serde_json::json!({
                "perm_id": perm_id,
                "session_id": payload.session_id,
                "tool_name": tool_name,
                "tool_input": tool_input,
            }),
        );

        // Wait for user decision (timeout 5 min)
        match tokio::time::timeout(std::time::Duration::from_secs(300), rx).await {
            Ok(Ok(decision)) => {
                let response = match decision.decision.as_str() {
                    "allow" => serde_json::json!({
                        "hookSpecificOutput": {
                            "hookEventName": "PermissionRequest",
                            "decision": { "behavior": "allow" }
                        }
                    }),
                    "deny" => serde_json::json!({
                        "hookSpecificOutput": {
                            "hookEventName": "PermissionRequest",
                            "decision": {
                                "behavior": "deny",
                                "message": decision.reason.unwrap_or_else(|| "Denied via Orbit".to_string())
                            }
                        }
                    }),
                    _ => {
                        // "ask" = let Claude Code handle it normally
                        // Still need to close cleanly so orbit-cli doesn't hang
                        return;
                    }
                };

                let response_bytes = serde_json::to_vec(&response).unwrap_or_default();
                let _ = writer.write_all(&response_bytes).await;
            }
            _ => {
                // Timeout or error, remove pending
                let mut pending = pending.lock().await;
                pending.remove(&perm_id);
            }
        }
    }
}
