use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::Mutex;

use crate::state::{HookPayload, Session, SessionMap, StatuslineUpdate};

fn create_test_session_map() -> SessionMap {
    Arc::new(Mutex::new(HashMap::new()))
}

fn create_hook_payload(session_id: &str, event: &str) -> HookPayload {
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

fn create_statusline_update(
    session_id: &str,
    tokens_in: u64,
    tokens_out: u64,
    cost_usd: f64,
    model: &str,
) -> StatuslineUpdate {
    StatuslineUpdate {
        session_id: session_id.to_string(),
        tokens_in,
        tokens_out,
        cost_usd,
        model: Some(model.to_string()),
        status: None,
    }
}

#[tokio::test]
async fn test_full_session_lifecycle_with_statusline_tokens() {
    let sessions = create_test_session_map();
    let session_id = "test-session-001";

    {
        let mut guard = sessions.lock().await;
        let mut session = Session::new(session_id.to_string(), "/tmp".to_string(), None, None);
        session.apply_event(&create_hook_payload(session_id, "SessionStart"));

        // Statusline provides cumulative totals
        session.apply_statusline_update(&create_statusline_update(
            session_id,
            100,
            200,
            0.01,
            "claude-sonnet-4-6",
        ));
        session.apply_statusline_update(&create_statusline_update(
            session_id,
            250,
            400,
            0.03,
            "claude-sonnet-4-6",
        ));
        guard.insert(session_id.to_string(), session);
    }

    let history_entry = {
        let guard = sessions.lock().await;
        let session = guard.get(session_id).unwrap();

        // Values are REPLACED (cumulative), not added
        assert_eq!(session.tokens_in, 250);
        assert_eq!(session.tokens_out, 400);
        assert_eq!(session.cost_usd, 0.03);
        assert_eq!(session.model.as_deref(), Some("claude-sonnet-4-6"));

        session.to_history_entry()
    };

    assert_eq!(history_entry.tokens_in, 250);
    assert_eq!(history_entry.tokens_out, 400);
    assert_eq!(history_entry.cost_usd, 0.03);
    assert_eq!(history_entry.model.as_deref(), Some("claude-sonnet-4-6"));
}

#[tokio::test]
async fn test_sessions_keep_independent_token_totals() {
    let sessions = create_test_session_map();

    {
        let mut guard = sessions.lock().await;

        let mut first = Session::new("session-1".to_string(), "/tmp".to_string(), None, None);
        first.apply_statusline_update(&create_statusline_update(
            "session-1",
            120,
            80,
            0.01,
            "claude-sonnet-4-6",
        ));

        let mut second = Session::new("session-2".to_string(), "/tmp".to_string(), None, None);
        second.apply_statusline_update(&create_statusline_update(
            "session-2",
            900,
            600,
            0.08,
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

    let entries: Vec<crate::history::HistoryEntry> = serde_json::from_str(old_json).unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].session_id, "test-123");
    assert_eq!(entries[0].title, Some("Test Session".to_string()));
    assert_eq!(entries[0].tokens_in, 0);
    assert_eq!(entries[0].tokens_out, 0);
    assert_eq!(entries[0].cost_usd, 0.0);
    assert_eq!(entries[0].model, None);
}
