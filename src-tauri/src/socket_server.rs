use std::sync::atomic::Ordering;
use tauri::Emitter;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::oneshot;

use crate::history;
use crate::state::{
    ConnectionCount, HookPayload, PendingPermission, PendingPermissions, PermissionDecision,
    Session, SessionMap,
};

const SOCKET_PATH: &str = "/tmp/orbit.sock";

pub async fn start(
    app_handle: tauri::AppHandle,
    sessions: SessionMap,
    pending: PendingPermissions,
    conn_count: ConnectionCount,
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
                let conn_count = conn_count.clone();

                // Increment connection count
                let count = conn_count.fetch_add(1, Ordering::Relaxed) + 1;
                let _ = handle.emit("connection-count", count);

                tauri::async_runtime::spawn(async move {
                    handle_connection(stream, sessions, pending, &handle).await;

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
    let history_entry = {
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

        // Prepare history entry (but don't write yet — avoid sync IO inside async lock)
        if is_session_end {
            let duration = (session.last_event_at - session.started_at)
                .num_seconds()
                .max(0);
            Some(history::HistoryEntry {
                session_id: session.id.clone(),
                cwd: session.cwd.clone(),
                started_at: session.started_at,
                ended_at: session.last_event_at,
                tool_count: session.tool_count,
                duration_secs: duration,
            })
        } else {
            None
        }
    };

    // Write history outside the lock to avoid blocking tokio worker
    if let Some(entry) = history_entry {
        history::save_entry(entry);
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
        let tool_input = payload
            .tool_input
            .clone()
            .unwrap_or(serde_json::Value::Null);

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
                        let ask_response = serde_json::json!({
                            "hookSpecificOutput": {
                                "hookEventName": "PermissionRequest",
                                "decision": { "behavior": "ask" }
                            }
                        });
                        let response_bytes = serde_json::to_vec(&ask_response).unwrap_or_default();
                        let _ = writer.write_all(&response_bytes).await;
                        return;
                    }
                };

                let response_bytes = serde_json::to_vec(&response).unwrap_or_default();
                let _ = writer.write_all(&response_bytes).await;
            }
            _ => {
                // Timeout or error, remove pending and notify frontend
                let mut pending = pending.lock().await;
                pending.remove(&perm_id);
                let _ = app_handle.emit("permission-timeout", &perm_id);
            }
        }
    }
}
