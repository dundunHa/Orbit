use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const MAX_HISTORY: usize = 50;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub session_id: String,
    pub cwd: String,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub tool_count: u32,
    pub duration_secs: i64,
}

fn history_path() -> PathBuf {
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join(".orbit").join("history.json")
}

pub fn save_entry(entry: HistoryEntry) {
    let path = history_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let mut entries = load_entries();
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
    let path = history_path();
    match std::fs::read_to_string(&path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}
