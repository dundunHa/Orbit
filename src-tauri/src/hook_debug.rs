use chrono::SecondsFormat;
use serde::Serialize;
use std::fs::{OpenOptions, create_dir_all, rename};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

const HOOK_DEBUG_LOG_PATH_ENV: &str = "ORBIT_HOOK_DEBUG_LOG_PATH";
/// Enable hook-debug log. Default: disabled. Set `ORBIT_HOOK_DEBUG=1` to enable.
const HOOK_DEBUG_ENABLE_ENV: &str = "ORBIT_HOOK_DEBUG";
/// Max log size before rotate (bytes). Override with `ORBIT_HOOK_DEBUG_MAX_BYTES`.
const HOOK_DEBUG_MAX_BYTES_ENV: &str = "ORBIT_HOOK_DEBUG_MAX_BYTES";
const DEFAULT_MAX_BYTES: u64 = 8 * 1024 * 1024; // 8 MiB

static HOOK_DEBUG_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

fn hook_debug_enabled() -> bool {
    std::env::var_os(HOOK_DEBUG_ENABLE_ENV)
        .map(|v| {
            let s = v.to_string_lossy();
            !matches!(s.as_ref(), "" | "0" | "false" | "FALSE" | "off" | "OFF")
        })
        .unwrap_or(false)
}

fn max_bytes() -> u64 {
    std::env::var(HOOK_DEBUG_MAX_BYTES_ENV)
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(DEFAULT_MAX_BYTES)
}

/// Rotate log if it exceeds max size. Best-effort: errors silently ignored.
fn maybe_rotate(path: &Path, limit: u64) {
    let Ok(meta) = std::fs::metadata(path) else {
        return;
    };
    if meta.len() < limit {
        return;
    }
    let rotated = path.with_extension("log.1");
    let _ = rename(path, &rotated);
}

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
    if !hook_debug_enabled() {
        return;
    }

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

    maybe_rotate(&path, max_bytes());

    let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) else {
        return;
    };

    let _ = writeln!(file, "{}", line);
}
