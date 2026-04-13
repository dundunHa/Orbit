use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

/// Deserialize `""` as `None` for backward compatibility with old `title: String` format.
fn deserialize_title_opt<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    let opt: Option<String> = Option::deserialize(deserializer)?;
    Ok(opt.filter(|s| !s.is_empty()))
}

const MAX_HISTORY: usize = 50;

/// File-level mutex to prevent concurrent read-modify-write races
static HISTORY_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub session_id: String,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_session_id: Option<String>,
    pub cwd: String,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub tool_count: u32,
    pub duration_secs: i64,
    #[serde(default, deserialize_with = "deserialize_title_opt")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default)]
    pub tokens_in: u64,
    #[serde(default)]
    pub tokens_out: u64,
    #[serde(default)]
    pub cost_usd: f64,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tty: Option<String>,
}

fn history_path() -> PathBuf {
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join(".orbit").join("history.json")
}

pub fn save_entry(entry: HistoryEntry) {
    let _guard = HISTORY_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let path = history_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let mut entries = load_entries_inner(&path);
    entries.push(entry);

    // Keep only the last MAX_HISTORY entries
    if entries.len() > MAX_HISTORY {
        entries = entries.split_off(entries.len() - MAX_HISTORY);
    }

    if let Ok(json) = serde_json::to_string_pretty(&entries) {
        let _ = std::fs::write(&path, json);
    }
}

pub fn load_entries() -> Vec<HistoryEntry> {
    let _guard = HISTORY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    load_entries_inner(&history_path())
}

pub fn find_entry(session_id: &str) -> Option<HistoryEntry> {
    load_entries()
        .into_iter()
        .find(|e| e.session_id == session_id)
}

fn load_entries_inner(path: &PathBuf) -> Vec<HistoryEntry> {
    match std::fs::read_to_string(path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}
