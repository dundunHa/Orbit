use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, oneshot};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum SessionStatus {
    WaitingForInput,
    Processing,
    RunningTool {
        tool_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    WaitingForApproval {
        tool_name: String,
        tool_input: Value,
    },
    Anomaly {
        idle_seconds: u64,
        previous_status: Box<SessionStatus>,
    },
    Compacting,
    Ended,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionEvent {
    pub event_name: String,
    pub timestamp: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_input: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub cwd: String,
    pub status: SessionStatus,
    pub started_at: DateTime<Utc>,
    pub last_event_at: DateTime<Utc>,
    pub tool_count: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tty: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HookPayload {
    pub session_id: String,
    pub hook_event_name: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub tool_name: Option<String>,
    #[serde(default)]
    pub tool_input: Option<Value>,
    #[serde(default)]
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub tool_response: Option<Value>,
    #[serde(default)]
    pub notification_type: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default)]
    pub tty: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
}

/// Pending permission request waiting for user decision
pub struct PendingPermission {
    pub session_id: String,
    pub tool_name: String,
    pub tool_input: Value,
    pub responder: oneshot::Sender<PermissionDecision>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermissionDecision {
    pub decision: String, // "allow", "deny", "ask"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

pub type SessionMap = Arc<Mutex<HashMap<String, Session>>>;
pub type PendingPermissions = Arc<Mutex<HashMap<String, PendingPermission>>>;

pub struct AppState {
    pub sessions: SessionMap,
    pub pending_permissions: PendingPermissions,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            pending_permissions: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

impl Session {
    pub fn new(id: String, cwd: String, pid: Option<u32>, tty: Option<String>) -> Self {
        let now = Utc::now();
        Self {
            id,
            cwd,
            status: SessionStatus::WaitingForInput,
            started_at: now,
            last_event_at: now,
            tool_count: 0,
            pid,
            tty,
        }
    }

    pub fn apply_event(&mut self, payload: &HookPayload) {
        self.last_event_at = Utc::now();

        match payload.hook_event_name.as_str() {
            "UserPromptSubmit" => {
                self.status = SessionStatus::Processing;
            }
            "PreToolUse" => {
                self.tool_count += 1;
                self.status = SessionStatus::RunningTool {
                    tool_name: payload.tool_name.clone().unwrap_or_default(),
                    description: payload
                        .tool_input
                        .as_ref()
                        .and_then(|v| v.get("description"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string()),
                };
            }
            "PostToolUse" | "PostToolUseFailure" => {
                self.status = SessionStatus::Processing;
            }
            "PermissionRequest" => {
                self.status = SessionStatus::WaitingForApproval {
                    tool_name: payload.tool_name.clone().unwrap_or_default(),
                    tool_input: payload.tool_input.clone().unwrap_or(Value::Null),
                };
            }
            "Stop" | "SubagentStop" => {
                self.status = SessionStatus::WaitingForInput;
            }
            "SessionStart" => {
                self.status = SessionStatus::WaitingForInput;
            }
            "SessionEnd" => {
                self.status = SessionStatus::Ended;
            }
            "Notification" => {
                if payload.notification_type.as_deref() == Some("idle_prompt") {
                    self.status = SessionStatus::WaitingForInput;
                }
            }
            "PreCompact" => {
                self.status = SessionStatus::Compacting;
            }
            _ => {}
        }
    }
}
