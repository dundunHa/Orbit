use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tauri::Emitter;
use tokio::sync::Mutex;
use tokio::time::interval;

use crate::state::SessionMap;

const CACHE_PATH: &str = "/tmp/.claude_usage_cache";
const POLL_INTERVAL_SECS: u64 = 2;

/// Usage data for a single model
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ModelUsage {
    pub model_name: String,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub cache_tokens: u64,
    pub cache_creation_tokens: u64,
    pub request_count: u64,
}

/// Global usage snapshot from Claude Code cache
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GlobalUsageSnapshot {
    pub timestamp: u64,
    pub models: Vec<ModelUsage>,
    pub total_prompt_tokens: u64,
    pub total_completion_tokens: u64,
    pub total_cache_tokens: u64,
    pub total_cache_creation_tokens: u64,
    pub total_request_count: u64,
}

/// Internal state for tracking token rates
#[derive(Debug, Clone)]
struct TokenRateState {
    last_snapshot: Option<GlobalUsageSnapshot>,
    last_timestamp: std::time::Instant,
}

impl Default for TokenRateState {
    fn default() -> Self {
        Self {
            last_snapshot: None,
            last_timestamp: std::time::Instant::now(),
        }
    }
}

/// Parsed cache file structure
#[derive(Debug, Clone, Deserialize)]
struct CacheFile {
    #[serde(default)]
    data: CacheData,
}

#[derive(Debug, Clone, Deserialize, Default)]
struct CacheData {
    #[serde(default)]
    models: Vec<CacheModel>,
    #[serde(default)]
    total_prompt_tokens: u64,
    #[serde(default)]
    total_completion_tokens: u64,
    #[serde(default)]
    total_cache_tokens: u64,
    #[serde(default)]
    total_cache_creation_tokens: u64,
    #[serde(default)]
    total_request_count: u64,
}

#[derive(Debug, Clone, Deserialize)]
struct CacheModel {
    model_name: String,
    #[serde(default)]
    prompt_tokens: u64,
    #[serde(default)]
    completion_tokens: u64,
    #[serde(default)]
    cache_tokens: u64,
    #[serde(default)]
    cache_creation_tokens: u64,
    #[serde(default)]
    request_count: u64,
}

/// Start the usage collector background task
pub async fn start(app_handle: tauri::AppHandle, sessions: SessionMap) {
    let state = Arc::new(Mutex::new(TokenRateState::default()));
    let mut ticker = interval(Duration::from_secs(POLL_INTERVAL_SECS));

    loop {
        ticker.tick().await;

        match read_usage_cache().await {
            Some(snapshot) => {
                let mut state_guard = state.lock().await;
                let now = std::time::Instant::now();

                // Emit update to frontend if we have a previous snapshot to calculate rates
                if let Some(ref last) = state_guard.last_snapshot {
                    let rates = calculate_rates(last, &snapshot, &state_guard.last_timestamp, &now);
                    let _ = app_handle.emit("global-usage-update", &snapshot);
                    let _ = app_handle.emit("token-rates", rates);

                    // Try to update active sessions with model-specific usage
                    update_sessions_with_usage(&sessions, &snapshot).await;
                }

                state_guard.last_snapshot = Some(snapshot);
                state_guard.last_timestamp = now;
            }
            None => {
                // Cache file missing or malformed - skip this poll
                continue;
            }
        }
    }
}

/// Read and parse the usage cache file
async fn read_usage_cache() -> Option<GlobalUsageSnapshot> {
    let path = Path::new(CACHE_PATH);

    if !path.exists() {
        return None;
    }

    let content = tokio::fs::read_to_string(path).await.ok()?;
    let cache: CacheFile = serde_json::from_str(&content).ok()?;

    let models = cache
        .data
        .models
        .into_iter()
        .map(|m| ModelUsage {
            model_name: m.model_name,
            prompt_tokens: m.prompt_tokens,
            completion_tokens: m.completion_tokens,
            cache_tokens: m.cache_tokens,
            cache_creation_tokens: m.cache_creation_tokens,
            request_count: m.request_count,
        })
        .collect();

    Some(GlobalUsageSnapshot {
        timestamp: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        models,
        total_prompt_tokens: cache.data.total_prompt_tokens,
        total_completion_tokens: cache.data.total_completion_tokens,
        total_cache_tokens: cache.data.total_cache_tokens,
        total_cache_creation_tokens: cache.data.total_cache_creation_tokens,
        total_request_count: cache.data.total_request_count,
    })
}

/// Calculate token rates from two snapshots
#[derive(Debug, Clone, Serialize)]
pub struct TokenRates {
    pub prompt_rate: f64,
    pub completion_rate: f64,
    pub total_rate: f64,
    pub by_model: HashMap<String, ModelRate>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ModelRate {
    pub prompt_rate: f64,
    pub completion_rate: f64,
    pub total_rate: f64,
}

fn calculate_rates(
    previous: &GlobalUsageSnapshot,
    current: &GlobalUsageSnapshot,
    last_time: &std::time::Instant,
    now: &std::time::Instant,
) -> TokenRates {
    let elapsed_secs = now.duration_since(*last_time).as_secs_f64();

    if elapsed_secs <= 0.0 {
        return TokenRates {
            prompt_rate: 0.0,
            completion_rate: 0.0,
            total_rate: 0.0,
            by_model: HashMap::new(),
        };
    }

    let prompt_delta = current
        .total_prompt_tokens
        .saturating_sub(previous.total_prompt_tokens);
    let completion_delta = current
        .total_completion_tokens
        .saturating_sub(previous.total_completion_tokens);

    let mut by_model = HashMap::new();

    // Calculate per-model rates
    for current_model in &current.models {
        if let Some(prev_model) = previous
            .models
            .iter()
            .find(|m| m.model_name == current_model.model_name)
        {
            let prompt_delta = current_model
                .prompt_tokens
                .saturating_sub(prev_model.prompt_tokens);
            let completion_delta = current_model
                .completion_tokens
                .saturating_sub(prev_model.completion_tokens);

            by_model.insert(
                current_model.model_name.clone(),
                ModelRate {
                    prompt_rate: prompt_delta as f64 / elapsed_secs,
                    completion_rate: completion_delta as f64 / elapsed_secs,
                    total_rate: (prompt_delta + completion_delta) as f64 / elapsed_secs,
                },
            );
        }
    }

    TokenRates {
        prompt_rate: prompt_delta as f64 / elapsed_secs,
        completion_rate: completion_delta as f64 / elapsed_secs,
        total_rate: (prompt_delta + completion_delta) as f64 / elapsed_secs,
        by_model,
    }
}

fn normalize_model_name(name: &str) -> String {
    name.trim_start_matches("anthropic/")
        .trim_start_matches("claude-")
        .to_string()
}

/// Update active sessions with usage data for their model
async fn update_sessions_with_usage(sessions: &SessionMap, snapshot: &GlobalUsageSnapshot) {
    let mut sessions_guard = sessions.lock().await;

    for (_, session) in sessions_guard.iter_mut() {
        if let Some(ref session_model) = session.model {
            let normalized_session = normalize_model_name(session_model);

            if let Some(model_usage) = snapshot.models.iter().find(|m| {
                let normalized_cache = normalize_model_name(&m.model_name);
                normalized_cache == normalized_session
            }) {
                session.tokens_in = session
                    .tokens_in
                    .max(model_usage.prompt_tokens + model_usage.cache_tokens);
                session.tokens_out = session.tokens_out.max(model_usage.completion_tokens);
            }
        }
    }
}

/// Get the latest usage snapshot (for SessionEnd final refresh)
pub async fn get_latest_snapshot() -> Option<GlobalUsageSnapshot> {
    read_usage_cache().await
}

/// Update a specific session with the latest usage data for its model
pub async fn refresh_session_with_latest(sessions: &SessionMap, session_id: &str) -> Option<()> {
    let snapshot = get_latest_snapshot().await?;
    let mut sessions_guard = sessions.lock().await;
    let session = sessions_guard.get_mut(session_id)?;

    if let Some(ref session_model) = session.model {
        let normalized_session = normalize_model_name(session_model);

        if let Some(model_usage) = snapshot.models.iter().find(|m| {
            let normalized_cache = normalize_model_name(&m.model_name);
            normalized_cache == normalized_session
        }) {
            session.tokens_in = session
                .tokens_in
                .max(model_usage.prompt_tokens + model_usage.cache_tokens);
            session.tokens_out = session.tokens_out.max(model_usage.completion_tokens);
        }
    }

    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_calculate_rates() {
        let prev = GlobalUsageSnapshot {
            timestamp: 0,
            models: vec![ModelUsage {
                model_name: "claude-sonnet".to_string(),
                prompt_tokens: 100,
                completion_tokens: 50,
                cache_tokens: 0,
                cache_creation_tokens: 0,
                request_count: 1,
            }],
            total_prompt_tokens: 100,
            total_completion_tokens: 50,
            total_cache_tokens: 0,
            total_cache_creation_tokens: 0,
            total_request_count: 1,
        };

        let curr = GlobalUsageSnapshot {
            timestamp: 2,
            models: vec![ModelUsage {
                model_name: "claude-sonnet".to_string(),
                prompt_tokens: 200,
                completion_tokens: 100,
                cache_tokens: 0,
                cache_creation_tokens: 0,
                request_count: 2,
            }],
            total_prompt_tokens: 200,
            total_completion_tokens: 100,
            total_cache_tokens: 0,
            total_cache_creation_tokens: 0,
            total_request_count: 2,
        };

        let last_time = std::time::Instant::now();
        std::thread::sleep(std::time::Duration::from_millis(10));
        let now = std::time::Instant::now();

        let rates = calculate_rates(&prev, &curr, &last_time, &now);

        // Rates should be positive
        assert!(rates.prompt_rate >= 0.0);
        assert!(rates.completion_rate >= 0.0);
        assert!(rates.total_rate >= 0.0);
    }

    #[test]
    fn test_monotonic_update() {
        // Test that tokens never decrease
        let prev = GlobalUsageSnapshot {
            timestamp: 0,
            models: vec![ModelUsage {
                model_name: "test-model".to_string(),
                prompt_tokens: 1000,
                completion_tokens: 500,
                cache_tokens: 0,
                cache_creation_tokens: 0,
                request_count: 10,
            }],
            total_prompt_tokens: 1000,
            total_completion_tokens: 500,
            total_cache_tokens: 0,
            total_cache_creation_tokens: 0,
            total_request_count: 10,
        };

        let curr = GlobalUsageSnapshot {
            timestamp: 2,
            models: vec![ModelUsage {
                model_name: "test-model".to_string(),
                prompt_tokens: 800, // Decreased (should not happen in reality, but test protection)
                completion_tokens: 400,
                cache_tokens: 0,
                cache_creation_tokens: 0,
                request_count: 10,
            }],
            total_prompt_tokens: 800,
            total_completion_tokens: 400,
            total_cache_tokens: 0,
            total_cache_creation_tokens: 0,
            total_request_count: 10,
        };

        let last_time = std::time::Instant::now();
        let now = last_time; // Same time to avoid division issues

        let rates = calculate_rates(&prev, &curr, &last_time, &now);

        // Rates should be 0 (not negative) due to saturating_sub
        assert_eq!(rates.prompt_rate, 0.0);
        assert_eq!(rates.completion_rate, 0.0);
    }
}
