use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::history::HistoryEntry;
use crate::state::{HookPayload, Session, SessionMap, TokenUsage};
use crate::usage_collector::{GlobalUsageSnapshot, ModelUsage};

fn create_test_session_map() -> SessionMap {
    Arc::new(Mutex::new(HashMap::new()))
}

fn create_test_usage_snapshot(
    model_name: &str,
    prompt: u64,
    completion: u64,
) -> GlobalUsageSnapshot {
    GlobalUsageSnapshot {
        timestamp: 0,
        models: vec![ModelUsage {
            model_name: model_name.to_string(),
            prompt_tokens: prompt,
            completion_tokens: completion,
            cache_tokens: 0,
            cache_creation_tokens: 0,
            request_count: 1,
        }],
        total_prompt_tokens: prompt,
        total_completion_tokens: completion,
        total_cache_tokens: 0,
        total_cache_creation_tokens: 0,
        total_request_count: 1,
    }
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

#[tokio::test]
async fn test_full_session_lifecycle_with_token_updates() {
    let sessions = create_test_session_map();
    let session_id = "test-session-001";

    {
        let mut guard = sessions.lock().await;
        let mut session = Session::new(session_id.to_string(), "/tmp".to_string(), None, None);
        let payload = create_session_start_payload(session_id);
        session.apply_event(&payload);
        guard.insert(session_id.to_string(), session);
    }

    {
        let guard = sessions.lock().await;
        assert!(guard.contains_key(session_id));
        let session = guard.get(session_id).unwrap();
        assert_eq!(session.tokens_in, 0);
        assert_eq!(session.tokens_out, 0);
    }

    {
        let mut guard = sessions.lock().await;
        let session = guard.get_mut(session_id).unwrap();
        session.model = Some("claude-sonnet-4-6".to_string());
    }

    let snapshot = create_test_usage_snapshot("claude-sonnet-4-6", 1000, 500);

    {
        let mut guard = sessions.lock().await;
        let session = guard.get_mut(session_id).unwrap();

        if let Some(model_usage) = snapshot
            .models
            .iter()
            .find(|m| m.model_name == *session.model.as_ref().unwrap())
        {
            session.tokens_in = session
                .tokens_in
                .max(model_usage.prompt_tokens + model_usage.cache_tokens);
            session.tokens_out = session.tokens_out.max(model_usage.completion_tokens);
        }
    }

    {
        let guard = sessions.lock().await;
        let session = guard.get(session_id).unwrap();
        assert_eq!(session.tokens_in, 1000);
        assert_eq!(session.tokens_out, 500);
    }

    let snapshot2 = create_test_usage_snapshot("claude-sonnet-4-6", 2500, 1200);
    {
        let mut guard = sessions.lock().await;
        let session = guard.get_mut(session_id).unwrap();

        if let Some(model_usage) = snapshot2
            .models
            .iter()
            .find(|m| m.model_name == *session.model.as_ref().unwrap())
        {
            session.tokens_in = session
                .tokens_in
                .max(model_usage.prompt_tokens + model_usage.cache_tokens);
            session.tokens_out = session.tokens_out.max(model_usage.completion_tokens);
        }
    }

    {
        let guard = sessions.lock().await;
        let session = guard.get(session_id).unwrap();
        assert_eq!(session.tokens_in, 2500);
        assert_eq!(session.tokens_out, 1200);
    }

    let history_entry = {
        let guard = sessions.lock().await;
        let session = guard.get(session_id).unwrap();
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

    assert_eq!(history_entry.tokens_in, 2500);
    assert_eq!(history_entry.tokens_out, 1200);
    assert_eq!(history_entry.model, Some("claude-sonnet-4-6".to_string()));
}

#[tokio::test]
async fn test_model_name_normalization() {
    let sessions = create_test_session_map();
    let session_id = "test-session-002";

    {
        let mut guard = sessions.lock().await;
        let mut session = Session::new(session_id.to_string(), "/tmp".to_string(), None, None);
        session.model = Some("claude-sonnet-4-6".to_string());
        guard.insert(session_id.to_string(), session);
    }

    let test_cases = vec![
        ("claude-sonnet-4-6", true),
        ("anthropic/claude-sonnet-4-6", true),
        ("kimi-k2.5", false),
    ];

    fn normalize(name: &str) -> String {
        let mut result = name.to_string();
        for prefix in ["anthropic/", "claude-"] {
            if result.starts_with(prefix) {
                result = result[prefix.len()..].to_string();
            }
        }
        result
    }

    for (cache_model, should_match) in test_cases {
        let snapshot = create_test_usage_snapshot(cache_model, 1000, 500);

        let mut guard = sessions.lock().await;
        let session = guard.get_mut(session_id).unwrap();

        let normalized_session = normalize(session.model.as_ref().unwrap());

        let matched = snapshot
            .models
            .iter()
            .any(|m| normalize(&m.model_name) == normalized_session);

        assert_eq!(
            matched,
            should_match,
            "Model '{}' should {}match session model '{}'",
            cache_model,
            if should_match { "" } else { "not " },
            session.model.as_ref().unwrap()
        );
    }
}

#[tokio::test]
async fn test_multiple_sessions_different_models() {
    let sessions = create_test_session_map();

    let session_configs = vec![
        ("session-1", "claude-sonnet-4-6"),
        ("session-2", "kimi-k2.5"),
        ("session-3", "claude-opus-4-6-v1"),
    ];

    for (id, model) in &session_configs {
        let mut guard = sessions.lock().await;
        let mut session = Session::new(id.to_string(), "/tmp".to_string(), None, None);
        session.model = Some(model.to_string());
        guard.insert(id.to_string(), session);
    }

    let snapshot = GlobalUsageSnapshot {
        timestamp: 0,
        models: vec![
            ModelUsage {
                model_name: "claude-sonnet-4-6".to_string(),
                prompt_tokens: 1000,
                completion_tokens: 500,
                cache_tokens: 0,
                cache_creation_tokens: 0,
                request_count: 1,
            },
            ModelUsage {
                model_name: "kimi-k2.5".to_string(),
                prompt_tokens: 2000,
                completion_tokens: 800,
                cache_tokens: 0,
                cache_creation_tokens: 0,
                request_count: 1,
            },
            ModelUsage {
                model_name: "claude-opus-4-6-v1".to_string(),
                prompt_tokens: 3000,
                completion_tokens: 1200,
                cache_tokens: 0,
                cache_creation_tokens: 0,
                request_count: 1,
            },
        ],
        total_prompt_tokens: 6000,
        total_completion_tokens: 2500,
        total_cache_tokens: 0,
        total_cache_creation_tokens: 0,
        total_request_count: 3,
    };

    fn normalize(name: &str) -> String {
        let mut result = name.to_string();
        for prefix in ["anthropic/", "claude-"] {
            if result.starts_with(prefix) {
                result = result[prefix.len()..].to_string();
            }
        }
        result
    }

    {
        let mut guard = sessions.lock().await;
        for (session_id, _) in &session_configs {
            if let Some(session) = guard.get_mut(*session_id) {
                if let Some(ref session_model) = session.model {
                    let normalized_session = normalize(session_model);

                    if let Some(model_usage) = snapshot
                        .models
                        .iter()
                        .find(|m| normalize(&m.model_name) == normalized_session)
                    {
                        session.tokens_in = session
                            .tokens_in
                            .max(model_usage.prompt_tokens + model_usage.cache_tokens);
                        session.tokens_out = session.tokens_out.max(model_usage.completion_tokens);
                    }
                }
            }
        }
    }

    let guard = sessions.lock().await;

    let session1 = guard.get("session-1").unwrap();
    assert_eq!(session1.tokens_in, 1000);
    assert_eq!(session1.tokens_out, 500);

    let session2 = guard.get("session-2").unwrap();
    assert_eq!(session2.tokens_in, 2000);
    assert_eq!(session2.tokens_out, 800);

    let session3 = guard.get("session-3").unwrap();
    assert_eq!(session3.tokens_in, 3000);
    assert_eq!(session3.tokens_out, 1200);
}

#[tokio::test]
async fn test_monotonic_protection_against_decrease() {
    let sessions = create_test_session_map();
    let session_id = "test-session-004";

    {
        let mut guard = sessions.lock().await;
        let mut session = Session::new(session_id.to_string(), "/tmp".to_string(), None, None);
        session.model = Some("claude-sonnet-4-6".to_string());
        session.tokens_in = 10000;
        session.tokens_out = 5000;
        guard.insert(session_id.to_string(), session);
    }

    let snapshot = create_test_usage_snapshot("claude-sonnet-4-6", 5000, 2000);

    {
        let mut guard = sessions.lock().await;
        let session = guard.get_mut(session_id).unwrap();

        if let Some(model_usage) = snapshot
            .models
            .iter()
            .find(|m| m.model_name == *session.model.as_ref().unwrap())
        {
            session.tokens_in = session
                .tokens_in
                .max(model_usage.prompt_tokens + model_usage.cache_tokens);
            session.tokens_out = session.tokens_out.max(model_usage.completion_tokens);
        }
    }

    let guard = sessions.lock().await;
    let session = guard.get(session_id).unwrap();
    assert_eq!(session.tokens_in, 10000);
    assert_eq!(session.tokens_out, 5000);
}

#[tokio::test]
async fn test_session_without_model_gets_no_tokens() {
    let sessions = create_test_session_map();
    let session_id = "test-session-005";

    {
        let mut guard = sessions.lock().await;
        let session = Session::new(session_id.to_string(), "/tmp".to_string(), None, None);
        guard.insert(session_id.to_string(), session);
    }

    let snapshot = create_test_usage_snapshot("claude-sonnet-4-6", 1000, 500);

    {
        let mut guard = sessions.lock().await;
        let session = guard.get_mut(session_id).unwrap();

        if let Some(ref session_model) = session.model {
            if let Some(model_usage) = snapshot
                .models
                .iter()
                .find(|m| m.model_name == *session_model)
            {
                session.tokens_in = session
                    .tokens_in
                    .max(model_usage.prompt_tokens + model_usage.cache_tokens);
                session.tokens_out = session.tokens_out.max(model_usage.completion_tokens);
            }
        }
    }

    let guard = sessions.lock().await;
    let session = guard.get(session_id).unwrap();
    assert_eq!(session.tokens_in, 0);
    assert_eq!(session.tokens_out, 0);
    assert!(session.model.is_none());
}

#[tokio::test]
async fn test_hook_usage_accumulation_plus_collector_update() {
    let sessions = create_test_session_map();
    let session_id = "test-session-006";

    {
        let mut guard = sessions.lock().await;
        let mut session = Session::new(session_id.to_string(), "/tmp".to_string(), None, None);

        let hook_payload = HookPayload {
            session_id: session_id.to_string(),
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
                model: "claude-sonnet-4-6".to_string(),
            }),
        };
        session.apply_event(&hook_payload);
        guard.insert(session_id.to_string(), session);
    }

    {
        let guard = sessions.lock().await;
        let session = guard.get(session_id).unwrap();
        assert_eq!(session.tokens_in, 100);
        assert_eq!(session.tokens_out, 200);
    }

    let snapshot = create_test_usage_snapshot("claude-sonnet-4-6", 5000, 2000);

    {
        let mut guard = sessions.lock().await;
        let session = guard.get_mut(session_id).unwrap();

        if let Some(model_usage) = snapshot
            .models
            .iter()
            .find(|m| m.model_name == *session.model.as_ref().unwrap())
        {
            session.tokens_in = session
                .tokens_in
                .max(model_usage.prompt_tokens + model_usage.cache_tokens);
            session.tokens_out = session.tokens_out.max(model_usage.completion_tokens);
        }
    }

    let guard = sessions.lock().await;
    let session = guard.get(session_id).unwrap();
    assert_eq!(session.tokens_in, 5000);
    assert_eq!(session.tokens_out, 2000);
}
