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
        title: None,
        model: None,
        agent_id: None,
        agent_type: None,
        agent_transcript_path: None,
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
        cwd: None,
        tokens_in,
        tokens_out,
        cost_usd,
        model: Some(model.to_string()),
        status: None,
        title: None,
        pid: None,
        tty: None,
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

/// Regression: a PreToolUse event that carries `agent_id` originates from a
/// subagent inside the session. It MUST create/update an entry in
/// `session.agents[agent_id]` and MUST NOT advance the parent session's
/// tool_count or flip its status to RunningTool. Otherwise the parent dot will
/// lie about what the main agent is doing while subagents run in parallel.
#[tokio::test]
async fn test_subagent_pretooluse_routes_to_agents_map_not_parent() {
    let sessions = create_test_session_map();
    let session_id = "sid-parent";

    {
        let mut guard = sessions.lock().await;
        let mut session = Session::new(session_id.to_string(), "/tmp".to_string(), None, None);

        // Main agent performs one tool call -> parent tool_count should go to 1.
        let mut main_pre = create_hook_payload(session_id, "PreToolUse");
        main_pre.tool_name = Some("Read".to_string());
        session.apply_event(&main_pre);

        // Subagent fires a PreToolUse with agent_id present.
        let mut sub_pre = create_hook_payload(session_id, "PreToolUse");
        sub_pre.tool_name = Some("Bash".to_string());
        sub_pre.agent_id = Some("aaa111".to_string());
        sub_pre.agent_type = Some("general-purpose".to_string());
        session.apply_subagent_event(&sub_pre);

        // Second subagent tool call in the same agent.
        let mut sub_pre2 = create_hook_payload(session_id, "PreToolUse");
        sub_pre2.tool_name = Some("Grep".to_string());
        sub_pre2.agent_id = Some("aaa111".to_string());
        sub_pre2.agent_type = Some("general-purpose".to_string());
        session.apply_subagent_event(&sub_pre2);

        guard.insert(session.id.clone(), session);
    }

    let guard = sessions.lock().await;
    let session = guard.get(session_id).unwrap();

    // Parent session untouched by subagent events.
    assert_eq!(
        session.tool_count, 1,
        "parent tool_count should reflect only the main agent's tool calls"
    );

    // Subagent record exists and tracks its own tool count + type.
    let sub = session.agents.get("aaa111").expect("subagent should exist");
    assert_eq!(sub.tool_count, 2);
    assert_eq!(sub.agent_type.as_deref(), Some("general-purpose"));
    assert!(!sub.ended, "should not be ended until SubagentStop arrives");
    assert_eq!(sub.last_tool_name.as_deref(), Some("Grep"));

    // SubagentStop must mark the agent as ended and leave parent status alone.
    let parent_status_before = format!("{:?}", session.status);
    drop(guard);
    {
        let mut guard = sessions.lock().await;
        let session = guard.get_mut(session_id).unwrap();
        let mut stop = create_hook_payload(session_id, "SubagentStop");
        stop.agent_id = Some("aaa111".to_string());
        session.apply_subagent_event(&stop);
    }
    let guard = sessions.lock().await;
    let session = guard.get(session_id).unwrap();
    assert!(session.agents.get("aaa111").unwrap().ended);
    assert_eq!(
        format!("{:?}", session.status),
        parent_status_before,
        "SubagentStop must not mutate the parent session's status"
    );
}

/// Regression: two completely independent Claude Code sessions (same cwd,
/// overlapping wall clock) must never be linked as parent/child. Before the
/// fix, socket_server.match_pending_parent would attach the second session
/// to the first simply because they shared a cwd and a Task PreToolUse had
/// recently fired. The new model removes that heuristic entirely, so both
/// sessions must stay at the tree root with parent_session_id == None.
#[tokio::test]
async fn test_two_independent_sessions_same_cwd_are_never_linked() {
    let sessions = create_test_session_map();

    {
        let mut guard = sessions.lock().await;
        let cwd = "/Users/alice/project";

        // Main agent A kicks off a Task PreToolUse in the shared cwd.
        let mut first = Session::new("sid-aaa".to_string(), cwd.to_string(), None, None);
        let mut task_pre = create_hook_payload("sid-aaa", "PreToolUse");
        task_pre.tool_name = Some("Task".to_string());
        first.apply_event(&task_pre);

        // Main agent B (completely unrelated) starts up in the same cwd shortly after.
        let mut second = Session::new("sid-bbb".to_string(), cwd.to_string(), None, None);
        second.apply_event(&create_hook_payload("sid-bbb", "SessionStart"));
        let mut bread = create_hook_payload("sid-bbb", "PreToolUse");
        bread.tool_name = Some("Read".to_string());
        second.apply_event(&bread);

        guard.insert(first.id.clone(), first);
        guard.insert(second.id.clone(), second);
    }

    let guard = sessions.lock().await;
    let a = guard.get("sid-aaa").unwrap();
    let b = guard.get("sid-bbb").unwrap();

    assert!(a.parent_session_id.is_none());
    assert!(b.parent_session_id.is_none());
    assert!(
        a.agents.is_empty(),
        "session A has no subagent events, so its agents map must stay empty"
    );
    assert!(
        b.agents.is_empty(),
        "session B has no subagent events, so its agents map must stay empty"
    );
}
