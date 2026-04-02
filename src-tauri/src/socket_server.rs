use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::oneshot;
use tauri::{Emitter, Manager};

use crate::state::{AppState, HookPayload, PendingPermission, PermissionDecision, Session};

const SOCKET_PATH: &str = "/tmp/orbit.sock";

pub async fn start(app_handle: tauri::AppHandle) {
    // Remove stale socket
    let _ = std::fs::remove_file(SOCKET_PATH);

    let listener = match UnixListener::bind(SOCKET_PATH) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("Failed to bind socket: {e}");
            return;
        }
    };

    let state = AppState::new();
    // Store state in Tauri
    app_handle.manage(state.sessions.clone());
    app_handle.manage(state.pending_permissions.clone());

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let sessions = state.sessions.clone();
                let pending = state.pending_permissions.clone();
                let handle = app_handle.clone();

                tauri::async_runtime::spawn(async move {
                    handle_connection(stream, sessions, pending, &handle).await;
                });
            }
            Err(e) => {
                eprintln!("Socket accept error: {e}");
            }
        }
    }
}

async fn handle_connection(
    stream: tokio::net::UnixStream,
    sessions: crate::state::SessionMap,
    pending: crate::state::PendingPermissions,
    app_handle: &tauri::AppHandle,
) {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut buf = String::new();

    if reader.read_line(&mut buf).await.is_err() {
        // Try reading all at once for non-line-delimited payloads
        return;
    }

    // Also try to read remaining data
    let mut remaining = String::new();
    let _ = reader.read_line(&mut remaining).await;
    if !remaining.is_empty() {
        buf.push_str(&remaining);
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
    }

    // Handle permission request: wait for user decision
    if is_permission_request {
        let (tx, rx) = oneshot::channel::<PermissionDecision>();

        let perm_id = format!(
            "{}-{}",
            payload.session_id,
            payload.tool_use_id.as_deref().unwrap_or("unknown")
        );

        {
            let mut pending = pending.lock().await;
            pending.insert(
                perm_id.clone(),
                PendingPermission {
                    session_id: payload.session_id.clone(),
                    tool_name: payload.tool_name.unwrap_or_default(),
                    tool_input: payload.tool_input.unwrap_or(serde_json::Value::Null),
                    responder: tx,
                },
            );
        }

        // Emit permission request to frontend
        let _ = app_handle.emit(
            "permission-request",
            serde_json::json!({
                "perm_id": perm_id,
                "session_id": payload.session_id,
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
                    _ => return, // "ask" = let Claude Code handle it
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
