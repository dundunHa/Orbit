use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{oneshot, Mutex};

/// Token usage information from Claude Code API
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub model: String,
}

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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default)]
    pub tokens_in: u64,
    #[serde(default)]
    pub tokens_out: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct ClaudeSessionFile {
    #[serde(rename = "sessionId")]
    session_id: String,
    name: String,
}

#[derive(Debug, Clone, Deserialize)]
struct HistoryJsonlEntry {
    #[serde(rename = "sessionId")]
    session_id: String,
    display: String,
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
    #[serde(default)]
    pub usage: Option<TokenUsage>,
}

/// Pending permission request waiting for user decision
#[allow(dead_code)]
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
pub type ConnectionCount = Arc<std::sync::atomic::AtomicU32>;

pub struct AppState {
    pub sessions: SessionMap,
    pub pending_permissions: PendingPermissions,
    pub connection_count: ConnectionCount,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            pending_permissions: Arc::new(Mutex::new(HashMap::new())),
            connection_count: Arc::new(std::sync::atomic::AtomicU32::new(0)),
        }
    }
}

impl Session {
    pub fn new(id: String, cwd: String, pid: Option<u32>, tty: Option<String>) -> Self {
        let now = Utc::now();
        let title = Self::fetch_title_from_claude_sessions(&id);
        Self {
            id,
            cwd,
            status: SessionStatus::WaitingForInput,
            started_at: now,
            last_event_at: now,
            tool_count: 0,
            pid,
            tty,
            title,
            tokens_in: 0,
            tokens_out: 0,
            model: None,
        }
    }

    fn fetch_title_from_claude_sessions(session_id: &str) -> Option<String> {
        let home = dirs_next::home_dir()?;

        let sessions_dir = home.join(".claude").join("sessions");
        if let Ok(entries) = std::fs::read_dir(&sessions_dir) {
            for entry in entries.flatten() {
                if let Ok(content) = std::fs::read_to_string(entry.path()) {
                    if let Ok(session_data) = serde_json::from_str::<ClaudeSessionFile>(&content) {
                        if session_data.session_id == session_id {
                            if !session_data.name.is_empty() {
                                return Some(session_data.name);
                            }
                        }
                    }
                }
            }
        }

        let history_path = home.join(".claude").join("history.jsonl");
        if let Ok(content) = std::fs::read_to_string(&history_path) {
            for line in content.lines() {
                if let Ok(entry) = serde_json::from_str::<HistoryJsonlEntry>(line) {
                    if entry.session_id == session_id {
                        let display = entry.display.trim();
                        if !display.is_empty() && !display.starts_with('/') {
                            let title = display.chars().take(40).collect::<String>();
                            return Some(title);
                        }
                    }
                }
            }
        }

        None
    }

    pub fn refresh_title_from_claude(&mut self) -> Option<String> {
        Self::fetch_title_from_claude_sessions(&self.id).map(|title| {
            self.title = Some(title.clone());
            title
        })
    }

    pub fn apply_event(&mut self, payload: &HookPayload) {
        self.last_event_at = Utc::now();

        // Extract and accumulate token usage if available
        if let Some(usage) = &payload.usage {
            self.tokens_in += usage.input_tokens as u64;
            self.tokens_out += usage.output_tokens as u64;
            self.model = Some(usage.model.clone());
        }

        match payload.hook_event_name.as_str() {
            "UserPromptSubmit" => {
                self.status = SessionStatus::Processing;
                if self.title.is_none() {
                    if let Some(msg) = &payload.message {
                        let title = if msg.len() > 40 {
                            format!("{}...", &msg[..37])
                        } else {
                            msg.clone()
                        };
                        self.title = Some(title);
                    }
                }
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
                self.refresh_title_from_claude();
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_token_accumulation() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        let payload = HookPayload {
            session_id: "test".to_string(),
            hook_event_name: "PostToolUse".to_string(),
            cwd: "/tmp".to_string(),
            tool_name: Some("Read".to_string()),
            tool_input: None,
            tool_use_id: None,
            tool_response: None,
            notification_type: None,
            message: None,
            pid: None,
            tty: None,
            status: None,
            usage: Some(TokenUsage {
                input_tokens: 100,
                output_tokens: 200,
                model: "claude-sonnet-4-5".to_string(),
            }),
        };

        session.apply_event(&payload);

        assert_eq!(session.tokens_in, 100);
        assert_eq!(session.tokens_out, 200);
        assert_eq!(session.model, Some("claude-sonnet-4-5".to_string()));
    }

    #[test]
    fn test_optional_token_usage() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        let payload = HookPayload {
            session_id: "test".to_string(),
            hook_event_name: "Stop".to_string(),
            cwd: "/tmp".to_string(),
            tool_name: None,
            tool_input: None,
            tool_use_id: None,
            tool_response: None,
            notification_type: None,
            message: None,
            pid: None,
            tty: None,
            status: None,
            usage: None,
        };

        session.apply_event(&payload);

        assert_eq!(session.tokens_in, 0);
        assert_eq!(session.tokens_out, 0);
        assert_eq!(session.model, None);
    }

    #[test]
    fn test_token_accumulation_multiple_events() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        let payload1 = HookPayload {
            session_id: "test".to_string(),
            hook_event_name: "PostToolUse".to_string(),
            cwd: "/tmp".to_string(),
            tool_name: Some("Read".to_string()),
            tool_input: None,
            tool_use_id: None,
            tool_response: None,
            notification_type: None,
            message: None,
            pid: None,
            tty: None,
            status: None,
            usage: Some(TokenUsage {
                input_tokens: 100,
                output_tokens: 200,
                model: "claude-sonnet-4-5".to_string(),
            }),
        };

        let payload2 = HookPayload {
            session_id: "test".to_string(),
            hook_event_name: "PostToolUse".to_string(),
            cwd: "/tmp".to_string(),
            tool_name: Some("Edit".to_string()),
            tool_input: None,
            tool_use_id: None,
            tool_response: None,
            notification_type: None,
            message: None,
            pid: None,
            tty: None,
            status: None,
            usage: Some(TokenUsage {
                input_tokens: 50,
                output_tokens: 150,
                model: "claude-sonnet-4-5".to_string(),
            }),
        };

        session.apply_event(&payload1);
        session.apply_event(&payload2);

        assert_eq!(session.tokens_in, 150);
        assert_eq!(session.tokens_out, 350);
    }

    #[test]
    fn test_history_backward_compatibility() {
        use crate::history::HistoryEntry;

        // Old history.json format without token fields
        let old_json = r#"[{
            "session_id": "test-123",
            "cwd": "/tmp",
            "started_at": "2024-01-01T00:00:00Z",
            "ended_at": "2024-01-01T00:01:00Z",
            "tool_count": 5,
            "duration_secs": 60,
            "title": "Test Session"
        }]"#;

        let entries: Vec<HistoryEntry> = serde_json::from_str(old_json).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].session_id, "test-123");
        // Token fields should default to 0/None
        assert_eq!(entries[0].tokens_in, 0);
        assert_eq!(entries[0].tokens_out, 0);
        assert_eq!(entries[0].model, None);
    }
}
