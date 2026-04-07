use chrono::{DateTime, Datelike, Local, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, oneshot};

/// Token usage data from Claude Code statusline
#[derive(Debug, Clone, Deserialize)]
pub struct StatuslineUpdate {
    pub session_id: String,
    pub tokens_in: u64,
    pub tokens_out: u64,
    #[serde(default)]
    pub cost_usd: f64,
    #[serde(default)]
    pub model: Option<String>,
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
    #[serde(default)]
    pub has_spawned_subagent: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_session_id: Option<String>,
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
    #[serde(default)]
    pub cost_usd: f64,
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
    #[serde(alias = "sessionId")]
    pub session_id: String,
    #[serde(alias = "hookEventName")]
    pub hook_event_name: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    #[serde(alias = "toolName")]
    pub tool_name: Option<String>,
    #[serde(default)]
    #[serde(alias = "toolInput")]
    pub tool_input: Option<Value>,
    #[serde(default)]
    #[serde(alias = "toolUseId")]
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub tool_response: Option<Value>,
    #[serde(default)]
    #[serde(alias = "mcpServerName")]
    pub mcp_server_name: Option<String>,
    #[serde(default)]
    #[serde(alias = "notificationType")]
    pub notification_type: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    #[serde(alias = "elicitationId")]
    pub elicitation_id: Option<String>,
    #[serde(default)]
    #[serde(alias = "requestedSchema")]
    pub requested_schema: Option<Value>,
    #[serde(default)]
    pub action: Option<String>,
    #[serde(default)]
    pub content: Option<Value>,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default)]
    pub tty: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
}

/// Pending user interaction request waiting for Orbit UI to answer.
#[allow(dead_code)]
pub struct PendingPermission {
    pub session_id: String,
    pub tool_name: String,
    pub tool_input: Value,
    pub responder: oneshot::Sender<PermissionDecision>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermissionDecision {
    pub decision: String, // permission: allow/deny/ask, elicitation: accept/decline/cancel/passthrough
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<Value>,
}

pub type SessionMap = Arc<Mutex<HashMap<String, Session>>>;
pub type PendingPermissions = Arc<Mutex<HashMap<String, PendingPermission>>>;
pub type ConnectionCount = Arc<std::sync::atomic::AtomicU32>;

/// Aggregate token stats for today, readable from sync contexts (tray menu).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodayTokenStats {
    pub date: u32, // YYYYMMDD
    pub tokens_in: u64,
    pub tokens_out: u64,
    /// Tokens/sec, EMA-smoothed for stable tray display
    pub out_rate: f64,
    last_rate_sample_ts: Option<DateTime<Utc>>,
    last_rate_sample_out: u64,
    /// Per-session token baselines captured at start of day (or first seen today).
    /// Used to compute today-only deltas for sessions that span midnight.
    session_baselines: std::collections::HashMap<String, (u64, u64)>,
}

impl Default for TodayTokenStats {
    fn default() -> Self {
        Self {
            date: today_key(),
            tokens_in: 0,
            tokens_out: 0,
            out_rate: 0.0,
            last_rate_sample_ts: None,
            last_rate_sample_out: 0,
            session_baselines: std::collections::HashMap::new(),
        }
    }
}

impl TodayTokenStats {
    pub fn update_rate(&mut self, current_total_out: u64) {
        let now = Utc::now();
        if let Some(last_ts) = self.last_rate_sample_ts {
            let elapsed = (now - last_ts).num_milliseconds() as f64 / 1000.0;
            if elapsed > 0.5 {
                let delta = current_total_out.saturating_sub(self.last_rate_sample_out);
                let instant_rate = delta as f64 / elapsed;
                // EMA smoothing
                self.out_rate = self.out_rate * 0.7 + instant_rate * 0.3;
                self.last_rate_sample_ts = Some(now);
                self.last_rate_sample_out = current_total_out;
            }
        } else {
            self.last_rate_sample_ts = Some(now);
            self.last_rate_sample_out = current_total_out;
        }
    }

    pub fn reset_if_new_day(&mut self) {
        let today = today_key();
        if self.date != today {
            *self = Self::default();
        }
    }

    pub fn session_today_delta(
        &mut self,
        session_id: &str,
        total_in: u64,
        total_out: u64,
    ) -> (u64, u64) {
        let baseline = self
            .session_baselines
            .entry(session_id.to_string())
            .or_insert((total_in, total_out));
        (
            total_in.saturating_sub(baseline.0),
            total_out.saturating_sub(baseline.1),
        )
    }

    /// Load token baselines from disk, returning default if file doesn't exist or is corrupted.
    pub fn load_from_disk() -> Self {
        let path = baselines_path();
        match std::fs::read_to_string(&path) {
            Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    /// Save token baselines to disk, ignoring errors.
    pub fn save_to_disk(&self) {
        let path = baselines_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(&path, json);
        }
    }
}

fn baselines_path() -> std::path::PathBuf {
    let home = dirs_next::home_dir().unwrap_or_else(|| std::path::PathBuf::from("."));
    home.join(".orbit").join("token-baselines.json")
}

fn today_key() -> u32 {
    let now = Local::now();
    now.year() as u32 * 10000 + now.month() * 100 + now.day()
}

pub type TodayStats = Arc<parking_lot::Mutex<TodayTokenStats>>;

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
            has_spawned_subagent: false,
            parent_session_id: None,
            status: SessionStatus::WaitingForInput,
            started_at: now,
            last_event_at: now,
            tool_count: 0,
            pid,
            tty,
            title,
            tokens_in: 0,
            tokens_out: 0,
            cost_usd: 0.0,
            model: None,
        }
    }

    fn fetch_title_from_claude_sessions(session_id: &str) -> Option<String> {
        let home = dirs_next::home_dir()?;

        let sessions_dir = home.join(".claude").join("sessions");
        if let Ok(entries) = std::fs::read_dir(&sessions_dir) {
            for entry in entries.flatten() {
                if let Ok(content) = std::fs::read_to_string(entry.path())
                    && let Ok(session_data) = serde_json::from_str::<ClaudeSessionFile>(&content)
                    && session_data.session_id == session_id
                    && !session_data.name.is_empty()
                {
                    return Some(session_data.name);
                }
            }
        }

        let history_path = home.join(".claude").join("history.jsonl");
        if let Ok(content) = std::fs::read_to_string(&history_path) {
            for line in content.lines() {
                if let Ok(entry) = serde_json::from_str::<HistoryJsonlEntry>(line)
                    && entry.session_id == session_id
                {
                    let display = entry.display.trim();
                    if !display.is_empty() && !display.starts_with('/') {
                        let title = display.chars().take(40).collect::<String>();
                        return Some(title);
                    }
                }
            }
        }

        None
    }

    pub fn refresh_title_from_claude(&mut self) -> Option<String> {
        Self::fetch_title_from_claude_sessions(&self.id).inspect(|title| {
            self.title = Some(title.clone());
        })
    }

    /// Apply cumulative token data from statusline
    pub fn apply_statusline_update(&mut self, update: &StatuslineUpdate) {
        self.tokens_in = update.tokens_in;
        self.tokens_out = update.tokens_out;
        self.cost_usd = update.cost_usd;
        if let Some(ref model) = update.model {
            self.model = Some(model.clone());
        }
        self.last_event_at = Utc::now();
    }

    pub fn apply_event(&mut self, payload: &HookPayload) {
        self.last_event_at = Utc::now();

        match payload.hook_event_name.as_str() {
            "UserPromptSubmit" => {
                self.status = SessionStatus::Processing;
                if self.title.is_none()
                    && let Some(msg) = &payload.message
                {
                    let title = if msg.len() > 40 {
                        format!("{}...", &msg[..37])
                    } else {
                        msg.clone()
                    };
                    self.title = Some(title);
                }
            }
            "PreToolUse" => {
                self.tool_count += 1;
                if payload.tool_name.as_deref() == Some("Task") {
                    self.has_spawned_subagent = true;
                }
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
            "Elicitation" => {
                self.status = SessionStatus::WaitingForApproval {
                    tool_name: payload
                        .mcp_server_name
                        .clone()
                        .unwrap_or_else(|| "Question".to_string()),
                    tool_input: serde_json::json!({
                        "message": payload.message.clone(),
                        "mode": payload.mode.clone(),
                        "url": payload.url.clone(),
                        "requested_schema": payload.requested_schema.clone(),
                    }),
                };
            }
            "ElicitationResult" => {
                self.status = SessionStatus::Processing;
            }
            "Stop" | "SubagentStop" => {
                // LLM generation stopped (reply completed, interrupted by user Ctrl+C, or subagent finished)
                // Status dot becomes GREEN (idle) - session continues, waiting for next input
                self.status = SessionStatus::WaitingForInput;
            }
            "SessionStart" => {
                self.status = SessionStatus::WaitingForInput;
                self.refresh_title_from_claude();
            }
            "SessionEnd" => {
                // Entire session ended (user closed terminal, exited Claude Code)
                // Status dot becomes GRAY (ended) - session is archived to history, cannot continue
                self.status = SessionStatus::Ended;
            }
            "Notification" => match payload.notification_type.as_deref() {
                Some("idle_prompt") => {
                    self.status = SessionStatus::WaitingForInput;
                }
                Some("permission_prompt") => {
                    self.status = SessionStatus::WaitingForApproval {
                        tool_name: "Permission".to_string(),
                        tool_input: payload.tool_input.clone().unwrap_or_else(|| {
                            serde_json::json!({
                                "message": payload.message.clone().unwrap_or_default()
                            })
                        }),
                    };
                }
                _ => {}
            },
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

    fn make_hook_payload(event: &str) -> HookPayload {
        HookPayload {
            session_id: "test".to_string(),
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
    fn test_statusline_update_replaces_tokens() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        let update = StatuslineUpdate {
            session_id: "test".to_string(),
            tokens_in: 5000,
            tokens_out: 2000,
            cost_usd: 0.05,
            model: Some("claude-sonnet-4-20250514".to_string()),
        };

        session.apply_statusline_update(&update);

        assert_eq!(session.tokens_in, 5000);
        assert_eq!(session.tokens_out, 2000);
        assert_eq!(session.cost_usd, 0.05);
        assert_eq!(session.model, Some("claude-sonnet-4-20250514".to_string()));
    }

    #[test]
    fn test_statusline_update_overwrites_previous() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        let update1 = StatuslineUpdate {
            session_id: "test".to_string(),
            tokens_in: 1000,
            tokens_out: 500,
            cost_usd: 0.01,
            model: Some("claude-sonnet-4-20250514".to_string()),
        };
        session.apply_statusline_update(&update1);

        let update2 = StatuslineUpdate {
            session_id: "test".to_string(),
            tokens_in: 3000,
            tokens_out: 1500,
            cost_usd: 0.03,
            model: Some("claude-sonnet-4-20250514".to_string()),
        };
        session.apply_statusline_update(&update2);

        // Should be the latest values, NOT accumulated
        assert_eq!(session.tokens_in, 3000);
        assert_eq!(session.tokens_out, 1500);
        assert_eq!(session.cost_usd, 0.03);
    }

    #[test]
    fn test_hook_events_do_not_affect_tokens() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        let payload = make_hook_payload("PostToolUse");
        session.apply_event(&payload);

        // Hook events should NOT change token counts
        assert_eq!(session.tokens_in, 0);
        assert_eq!(session.tokens_out, 0);
        assert_eq!(session.model, None);
    }

    #[test]
    fn test_session_status_transitions() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        let mut payload = make_hook_payload("SessionStart");
        session.apply_event(&payload);
        assert!(matches!(session.status, SessionStatus::WaitingForInput));

        payload = make_hook_payload("UserPromptSubmit");
        payload.message = Some("test prompt".to_string());
        session.apply_event(&payload);
        assert!(matches!(session.status, SessionStatus::Processing));

        payload = make_hook_payload("Stop");
        session.apply_event(&payload);
        assert!(matches!(session.status, SessionStatus::WaitingForInput));

        payload = make_hook_payload("SessionEnd");
        session.apply_event(&payload);
        assert!(matches!(session.status, SessionStatus::Ended));
    }

    #[test]
    fn test_notification_permission_prompt_sets_waiting_for_approval() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);
        let mut payload = make_hook_payload("Notification");
        payload.notification_type = Some("permission_prompt".to_string());
        payload.message = Some("Claude needs your permission to use Bash".to_string());

        session.apply_event(&payload);

        assert!(matches!(
            session.status,
            SessionStatus::WaitingForApproval { .. }
        ));
    }

    #[test]
    fn test_hook_payload_supports_camel_case_aliases() {
        let payload: HookPayload = serde_json::from_str(
            r#"{
                "sessionId": "test-session",
                "hookEventName": "PermissionRequest",
                "cwd": "/tmp",
                "toolName": "Bash",
                "toolInput": {"command": "pwd"},
                "toolUseId": "toolu_123",
                "notificationType": "permission_prompt"
            }"#,
        )
        .unwrap();

        assert_eq!(payload.session_id, "test-session");
        assert_eq!(payload.hook_event_name, "PermissionRequest");
        assert_eq!(payload.tool_name.as_deref(), Some("Bash"));
        assert_eq!(
            payload
                .tool_input
                .as_ref()
                .and_then(|value| value.get("command"))
                .and_then(|value| value.as_str()),
            Some("pwd")
        );
        assert_eq!(payload.tool_use_id.as_deref(), Some("toolu_123"));
        assert_eq!(
            payload.notification_type.as_deref(),
            Some("permission_prompt")
        );
    }

    #[test]
    fn test_history_backward_compatibility() {
        use crate::history::HistoryEntry;

        // Old history.json format without token/cost fields
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
        // Token/cost fields should default to 0/None
        assert_eq!(entries[0].tokens_in, 0);
        assert_eq!(entries[0].tokens_out, 0);
        assert_eq!(entries[0].cost_usd, 0.0);
        assert_eq!(entries[0].model, None);
    }
}
