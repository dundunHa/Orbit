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

/// Source of a session title, ordered by priority (higher value = higher priority).
/// Used to prevent lower-quality titles from overriding better ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum TitleSource {
    UserPrompt = 1,
    HistoryJsonl = 2,
    SessionsMetadata = 3,
}

/// Known bare slash commands that carry no useful title information.
const BARE_SLASH_COMMANDS: &[&str] = &[
    "/clear",
    "/help",
    "/model",
    "/compact",
    "/cost",
    "/status",
    "/permissions",
    "/review",
    "/bug",
    "/init",
    "/doctor",
    "/logout",
    "/login",
];

fn is_bare_slash_command(s: &str) -> bool {
    let trimmed = s.trim();
    if !trimmed.starts_with('/') {
        return false;
    }
    let command_part = trimmed.split_whitespace().next().unwrap_or("");
    BARE_SLASH_COMMANDS.contains(&command_part)
}

/// Normalize a raw title string into a clean Option<String>.
/// - Trims whitespace
/// - Returns None for empty/whitespace-only strings
/// - Returns None for bare slash commands (/clear, /help, etc.)
/// - Truncates to 40 chars at Unicode char boundaries (no panic on CJK/emoji)
fn normalize_title(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if is_bare_slash_command(trimmed) {
        return None;
    }
    let truncated: String = trimmed.chars().take(40).collect();
    Some(truncated)
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title_source: Option<TitleSource>,
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
    pub decision: String, // permission: allow/deny/passthrough (legacy ask), elicitation: accept/decline/cancel/passthrough
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<Value>,
}

impl PermissionDecision {
    pub fn normalized_decision(&self) -> &str {
        match self.decision.as_str() {
            "ask" => "passthrough",
            other => other,
        }
    }
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
    #[serde(skip)]
    pub out_rate: f64,
    #[serde(skip)]
    last_rate_sample_ts: Option<DateTime<Utc>>,
    #[serde(skip)]
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
        let mut stats = match std::fs::read_to_string(&path) {
            Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
            Err(_) => Self::default(),
        };
        stats.reset_if_new_day();
        stats
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
        let (title, title_source) = Self::fetch_title_from_claude_sessions(&id)
            .map(|(t, s)| (Some(t), Some(s)))
            .unwrap_or((None, None));
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
            title_source,
            tokens_in: 0,
            tokens_out: 0,
            cost_usd: 0.0,
            model: None,
        }
    }

    fn set_title_if_higher_priority(&mut self, title: String, source: TitleSource) {
        match self.title_source {
            Some(current) if current >= source => {}
            _ => {
                self.title = Some(title);
                self.title_source = Some(source);
            }
        }
    }

    fn fetch_title_from_claude_sessions(session_id: &str) -> Option<(String, TitleSource)> {
        let home = dirs_next::home_dir()?;

        let sessions_dir = home.join(".claude").join("sessions");
        if let Ok(entries) = std::fs::read_dir(&sessions_dir) {
            for entry in entries.flatten() {
                if let Ok(content) = std::fs::read_to_string(entry.path())
                    && let Ok(session_data) = serde_json::from_str::<ClaudeSessionFile>(&content)
                    && session_data.session_id == session_id
                    && let Some(title) = normalize_title(&session_data.name)
                {
                    return Some((title, TitleSource::SessionsMetadata));
                }
            }
        }

        let history_path = home.join(".claude").join("history.jsonl");
        if let Ok(content) = std::fs::read_to_string(&history_path) {
            for line in content.lines() {
                if let Ok(entry) = serde_json::from_str::<HistoryJsonlEntry>(line)
                    && entry.session_id == session_id
                    && let Some(title) = normalize_title(&entry.display)
                {
                    return Some((title, TitleSource::HistoryJsonl));
                }
            }
        }

        None
    }

    pub fn refresh_title_from_claude(&mut self) -> Option<String> {
        Self::fetch_title_from_claude_sessions(&self.id)
            .inspect(|(title, source)| {
                self.set_title_if_higher_priority(title.clone(), *source);
            })
            .map(|(title, _)| title)
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

    pub fn clear_waiting_for_approval(&mut self) -> bool {
        if matches!(self.status, SessionStatus::WaitingForApproval { .. }) {
            self.status = SessionStatus::Processing;
            self.last_event_at = Utc::now();
            return true;
        }

        false
    }

    pub fn apply_event(&mut self, payload: &HookPayload) {
        self.last_event_at = Utc::now();

        match payload.hook_event_name.as_str() {
            "UserPromptSubmit" => {
                self.status = SessionStatus::Processing;
                if let Some(msg) = &payload.message
                    && let Some(normalized) = normalize_title(msg)
                {
                    self.set_title_if_higher_priority(normalized, TitleSource::UserPrompt);
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

    pub fn to_history_entry(&self) -> crate::history::HistoryEntry {
        let duration = (self.last_event_at - self.started_at).num_seconds().max(0);
        crate::history::HistoryEntry {
            session_id: self.id.clone(),
            parent_session_id: self.parent_session_id.clone(),
            cwd: self.cwd.clone(),
            started_at: self.started_at,
            ended_at: self.last_event_at,
            tool_count: self.tool_count,
            duration_secs: duration,
            title: self.title.clone(),
            tokens_in: self.tokens_in,
            tokens_out: self.tokens_out,
            cost_usd: self.cost_usd,
            model: self.model.clone(),
            tty: self.tty.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::installer::TEST_HOME_ENV_LOCK;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::MutexGuard;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TestHome {
        _guard: MutexGuard<'static, ()>,
        path: PathBuf,
        old_home: Option<String>,
    }

    impl TestHome {
        fn new() -> Self {
            let guard = TEST_HOME_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let path = std::env::temp_dir().join(format!(
                "orbit-state-home-{}",
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            fs::create_dir_all(&path).unwrap();
            let old_home = std::env::var("HOME").ok();
            // SAFETY: TEST_HOME_ENV_LOCK is held for the lifetime of this helper.
            unsafe {
                std::env::set_var("HOME", &path);
            }

            Self {
                _guard: guard,
                path,
                old_home,
            }
        }

        fn baselines_path(&self) -> PathBuf {
            self.path.join(".orbit").join("token-baselines.json")
        }
    }

    impl Drop for TestHome {
        fn drop(&mut self) {
            match &self.old_home {
                Some(old_home) => unsafe {
                    std::env::set_var("HOME", old_home);
                },
                None => unsafe {
                    std::env::remove_var("HOME");
                },
            }
            let _ = fs::remove_dir_all(&self.path);
        }
    }

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
        assert_eq!(entries[0].title, Some("Test Session".to_string()));
        // Token/cost fields should default to 0/None
        assert_eq!(entries[0].tokens_in, 0);
        assert_eq!(entries[0].tokens_out, 0);
        assert_eq!(entries[0].cost_usd, 0.0);
        assert_eq!(entries[0].model, None);
    }

    #[test]
    fn test_permission_decision_normalizes_legacy_ask_to_passthrough() {
        let decision = PermissionDecision {
            decision: "ask".to_string(),
            reason: None,
            content: None,
        };

        assert_eq!(decision.normalized_decision(), "passthrough");
    }

    #[test]
    fn test_permission_decision_keeps_non_legacy_values() {
        let decision = PermissionDecision {
            decision: "deny".to_string(),
            reason: Some("Denied in UI".to_string()),
            content: None,
        };

        assert_eq!(decision.normalized_decision(), "deny");
    }

    #[test]
    fn test_clear_waiting_for_approval_sets_processing() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);
        session.apply_event(&make_hook_payload("PermissionRequest"));

        assert!(session.clear_waiting_for_approval());
        assert!(matches!(session.status, SessionStatus::Processing));
        assert!(!session.clear_waiting_for_approval());
    }

    #[test]
    fn test_today_token_stats_load_ignores_persisted_rate_fields() {
        let home = TestHome::new();
        let path = home.baselines_path();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            format!(
                r#"{{
                    "date": {},
                    "tokens_in": 0,
                    "tokens_out": 0,
                    "out_rate": 7.0,
                    "last_rate_sample_ts": "2026-04-11T10:00:00Z",
                    "last_rate_sample_out": 42,
                    "session_baselines": {{}}
                }}"#,
                today_key()
            ),
        )
        .unwrap();

        let stats = TodayTokenStats::load_from_disk();

        assert_eq!(stats.tokens_in, 0);
        assert_eq!(stats.tokens_out, 0);
        assert_eq!(stats.out_rate, 0.0);
        assert_eq!(stats.last_rate_sample_ts, None);
        assert_eq!(stats.last_rate_sample_out, 0);
    }

    #[test]
    fn test_today_token_stats_load_resets_when_file_is_from_previous_day() {
        let home = TestHome::new();
        let path = home.baselines_path();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            r#"{
                "date": 19990101,
                "tokens_in": 123,
                "tokens_out": 456,
                "session_baselines": {
                    "session-1": [10, 20]
                }
            }"#,
        )
        .unwrap();

        let stats = TodayTokenStats::load_from_disk();

        assert_eq!(stats.date, today_key());
        assert_eq!(stats.tokens_in, 0);
        assert_eq!(stats.tokens_out, 0);
        assert!(stats.session_baselines.is_empty());
        assert_eq!(stats.out_rate, 0.0);
    }

    // --- normalize_title() tests ---

    #[test]
    fn test_normalize_title_normal_text() {
        assert_eq!(
            normalize_title("hello world"),
            Some("hello world".to_string())
        );
    }

    #[test]
    fn test_normalize_title_empty_string() {
        assert_eq!(normalize_title(""), None);
    }

    #[test]
    fn test_normalize_title_whitespace_only() {
        assert_eq!(normalize_title("   "), None);
    }

    #[test]
    fn test_normalize_title_cjk_truncation() {
        let long_cjk = "修复中文bug测试一下多字节字符截断是否正确处理不会panic产生问题扩展更多的中文字符达到四十字以上";
        assert!(
            long_cjk.chars().count() > 40,
            "test string must exceed 40 chars"
        );
        let result = normalize_title(long_cjk).unwrap();
        assert_eq!(result.chars().count(), 40);
        assert!(result.starts_with("修复中文bug测试"));
    }

    #[test]
    fn test_normalize_title_emoji_no_panic() {
        let result = normalize_title("hello 🌍 world 🎉 test");
        assert!(result.is_some());
        assert!(result.unwrap().contains("hello"));
    }

    #[test]
    fn test_normalize_title_bare_slash_command_filtered() {
        assert_eq!(normalize_title("/clear"), None);
        assert_eq!(normalize_title("/help"), None);
        assert_eq!(normalize_title("/model"), None);
        assert_eq!(normalize_title("/compact"), None);
    }

    #[test]
    fn test_normalize_title_slash_with_content_kept() {
        assert_eq!(
            normalize_title("/openspec:apply foo"),
            Some("/openspec:apply foo".to_string())
        );
        assert_eq!(
            normalize_title("/ship this feature"),
            Some("/ship this feature".to_string())
        );
    }

    #[test]
    fn test_normalize_title_trims_whitespace() {
        assert_eq!(
            normalize_title("  hello world  "),
            Some("hello world".to_string())
        );
    }

    // --- TitleSource priority tests ---

    #[test]
    fn test_title_priority_higher_overrides_lower() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        // Simulate UserPrompt setting a low-priority title
        session.set_title_if_higher_priority(
            "low priority title".to_string(),
            TitleSource::UserPrompt,
        );
        assert_eq!(session.title, Some("low priority title".to_string()));
        assert_eq!(session.title_source, Some(TitleSource::UserPrompt));

        // Higher priority should override
        session.set_title_if_higher_priority(
            "high priority title".to_string(),
            TitleSource::SessionsMetadata,
        );
        assert_eq!(session.title, Some("high priority title".to_string()));
        assert_eq!(session.title_source, Some(TitleSource::SessionsMetadata));
    }

    #[test]
    fn test_title_priority_lower_does_not_override_higher() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        session
            .set_title_if_higher_priority("good title".to_string(), TitleSource::SessionsMetadata);
        session.set_title_if_higher_priority("bad title".to_string(), TitleSource::UserPrompt);

        assert_eq!(session.title, Some("good title".to_string()));
        assert_eq!(session.title_source, Some(TitleSource::SessionsMetadata));
    }

    #[test]
    fn test_title_priority_same_level_does_not_override() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        session.set_title_if_higher_priority("first prompt".to_string(), TitleSource::UserPrompt);
        session.set_title_if_higher_priority("second prompt".to_string(), TitleSource::UserPrompt);

        assert_eq!(session.title, Some("first prompt".to_string()));
    }

    // --- HistoryEntry backward compat with Option<String> title ---

    #[test]
    fn test_history_entry_title_null_deserializes_as_none() {
        use crate::history::HistoryEntry;

        let json = r#"[{
            "session_id": "test-null",
            "cwd": "/tmp",
            "started_at": "2024-01-01T00:00:00Z",
            "ended_at": "2024-01-01T00:01:00Z",
            "tool_count": 1,
            "duration_secs": 60,
            "title": null
        }]"#;

        let entries: Vec<HistoryEntry> = serde_json::from_str(json).unwrap();
        assert_eq!(entries[0].title, None);
    }

    #[test]
    fn test_history_entry_title_string_deserializes_as_some() {
        use crate::history::HistoryEntry;

        let json = r#"[{
            "session_id": "test-str",
            "cwd": "/tmp",
            "started_at": "2024-01-01T00:00:00Z",
            "ended_at": "2024-01-01T00:01:00Z",
            "tool_count": 1,
            "duration_secs": 60,
            "title": "My Session"
        }]"#;

        let entries: Vec<HistoryEntry> = serde_json::from_str(json).unwrap();
        assert_eq!(entries[0].title, Some("My Session".to_string()));
    }

    #[test]
    fn test_history_entry_title_empty_string_deserializes_as_none() {
        use crate::history::HistoryEntry;

        let json = r#"[{
            "session_id": "test-empty",
            "cwd": "/tmp",
            "started_at": "2024-01-01T00:00:00Z",
            "ended_at": "2024-01-01T00:01:00Z",
            "tool_count": 1,
            "duration_secs": 60,
            "title": ""
        }]"#;

        let entries: Vec<HistoryEntry> = serde_json::from_str(json).unwrap();
        assert_eq!(entries[0].title, None);
    }

    // --- Regression: UTF-8 truncation must not panic ---

    #[test]
    fn test_user_prompt_cjk_no_panic() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);

        let mut payload = make_hook_payload("UserPromptSubmit");
        payload.message = Some(
            "这是一个非常长的中文消息用来测试多字节字符截断是否会导致运行时panic崩溃问题"
                .to_string(),
        );

        session.apply_event(&payload);

        assert!(session.title.is_some());
        assert!(session.title.as_ref().unwrap().chars().count() <= 40);
    }

    // --- to_history_entry() ---

    #[test]
    fn test_to_history_entry_preserves_title() {
        let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);
        session.title = Some("test title".to_string());
        session.title_source = Some(TitleSource::HistoryJsonl);

        let entry = session.to_history_entry();
        assert_eq!(entry.title, Some("test title".to_string()));
    }

    #[test]
    fn test_to_history_entry_none_title() {
        let session = Session::new("test".to_string(), "/tmp".to_string(), None, None);
        let entry = session.to_history_entry();
        assert_eq!(entry.title, None);
    }
}
