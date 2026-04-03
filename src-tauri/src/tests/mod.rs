use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::Mutex;

use crate::history::HistoryEntry;
use crate::state::{HookPayload, Session, SessionMap, TokenUsage};

fn create_test_session_map() -> SessionMap {
    Arc::new(Mutex::new(HashMap::new()))
}

fn create_session_start_payload(session_id: &str) -> HookPayload {
    HookPayload {
        session_id: session_id.to_string(),
        hook_event_name: "SessionStart".to_string(),
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
    }
}

fn create_usage_payload(
    session_id: &str,
    tool_name: &str,
    input_tokens: u32,
    output_tokens: u32,
    model: &str,
) -> HookPayload {
    HookPayload {
        session_id: session_id.to_string(),
        hook_event_name: "PostToolUse".to_string(),
        cwd: "/tmp".to_string(),
        tool_name: Some(tool_name.to_string()),
        tool_input: None,
        tool_use_id: None,
        tool_response: None,
        notification_type: None,
        message: None,
        pid: None,
        tty: None,
        status: None,
        usage: Some(TokenUsage {
            input_tokens,
            output_tokens,
            model: model.to_string(),
        }),
    }
}

#[tokio::test]
async fn test_full_session_lifecycle_uses_hook_token_totals() {
    let sessions = create_test_session_map();
    let session_id = "test-session-001";

    {
        let mut guard = sessions.lock().await;
        let mut session = Session::new(session_id.to_string(), "/tmp".to_string(), None, None);
        session.apply_event(&create_session_start_payload(session_id));
        session.apply_event(&create_usage_payload(
            session_id,
            "Read",
            100,
            200,
            "claude-sonnet-4-6",
        ));
        session.apply_event(&create_usage_payload(
            session_id,
            "Edit",
            50,
            150,
            "claude-sonnet-4-6",
        ));
        guard.insert(session_id.to_string(), session);
    }

    let history_entry = {
        let guard = sessions.lock().await;
        let session = guard.get(session_id).unwrap();

        assert_eq!(session.tokens_in, 150);
        assert_eq!(session.tokens_out, 350);
        assert_eq!(session.model.as_deref(), Some("claude-sonnet-4-6"));

        HistoryEntry {
            session_id: session.id.clone(),
            cwd: session.cwd.clone(),
            started_at: session.started_at,
            ended_at: session.last_event_at,
            tool_count: session.tool_count,
            duration_secs: 60,
            title: session.title.clone().unwrap_or_default(),
            tokens_in: session.tokens_in,
            tokens_out: session.tokens_out,
            model: session.model.clone(),
        }
    };

    assert_eq!(history_entry.tokens_in, 150);
    assert_eq!(history_entry.tokens_out, 350);
    assert_eq!(history_entry.model.as_deref(), Some("claude-sonnet-4-6"));
}

#[tokio::test]
async fn test_sessions_with_same_model_keep_independent_token_totals() {
    let sessions = create_test_session_map();

    {
        let mut guard = sessions.lock().await;

        let mut first = Session::new("session-1".to_string(), "/tmp".to_string(), None, None);
        first.apply_event(&create_usage_payload(
            "session-1",
            "Read",
            120,
            80,
            "claude-sonnet-4-6",
        ));

        let mut second = Session::new("session-2".to_string(), "/tmp".to_string(), None, None);
        second.apply_event(&create_usage_payload(
            "session-2",
            "Edit",
            900,
            600,
            "claude-sonnet-4-6",
        ));

        guard.insert(first.id.clone(), first);
        guard.insert(second.id.clone(), second);
    }

    let guard = sessions.lock().await;
    let first = guard.get("session-1").unwrap();
    let second = guard.get("session-2").unwrap();

    assert_eq!(first.tokens_in, 120);
    assert_eq!(first.tokens_out, 80);
    assert_eq!(second.tokens_in, 900);
    assert_eq!(second.tokens_out, 600);
}

#[test]
fn test_history_backward_compatibility() {
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
    assert_eq!(entries[0].tokens_in, 0);
    assert_eq!(entries[0].tokens_out, 0);
    assert_eq!(entries[0].model, None);
}
