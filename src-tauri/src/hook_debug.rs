use chrono::SecondsFormat;
use serde::Serialize;
use std::fs::{OpenOptions, create_dir_all};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};

const HOOK_DEBUG_LOG_PATH_ENV: &str = "ORBIT_HOOK_DEBUG_LOG_PATH";
static HOOK_DEBUG_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

#[derive(Serialize)]
struct HookDebugEntry<'a> {
    timestamp: String,
    source: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hook_event_name: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    request_id: Option<&'a str>,
    decision: &'a str,
    response_json: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    payload_summary: Option<&'a str>,
}

fn hook_debug_log_path() -> PathBuf {
    if let Some(override_path) = std::env::var_os(HOOK_DEBUG_LOG_PATH_ENV) {
        return PathBuf::from(override_path);
    }

    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".orbit")
        .join("hook-debug.log")
}

pub fn append_hook_debug_log(
    source: &str,
    session_id: Option<&str>,
    hook_event_name: Option<&str>,
    request_id: Option<&str>,
    decision: &str,
    response_json: Option<&str>,
    payload_summary: Option<&str>,
) {
    let entry = HookDebugEntry {
        timestamp: chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        source,
        session_id,
        hook_event_name,
        request_id,
        decision,
        response_json: response_json.unwrap_or("<none>"),
        payload_summary,
    };

    let Ok(line) = serde_json::to_string(&entry) else {
        return;
    };

    let path = hook_debug_log_path();
    let Some(parent) = path.parent() else {
        return;
    };

    let _guard = HOOK_DEBUG_LOCK.lock().ok();
    if create_dir_all(parent).is_err() {
        return;
    }

    let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) else {
        return;
    };

    let _ = writeln!(file, "{}", line);
}
