use serde_json::Value;

use crate::state::HookPayload;

#[allow(dead_code)]
pub trait CliAdapter: Send + Sync {
    fn name(&self) -> &str;
    fn parse_event(&self, raw: &Value) -> Option<HookPayload>;
    fn format_status(&self, tool_name: &str, tool_input: &Option<Value>) -> String;
}

#[allow(dead_code)]
pub struct ClaudeCodeAdapter;

impl CliAdapter for ClaudeCodeAdapter {
    fn name(&self) -> &str {
        "claude-code"
    }

    fn parse_event(&self, raw: &Value) -> Option<HookPayload> {
        serde_json::from_value(raw.clone()).ok()
    }

    fn format_status(&self, tool_name: &str, tool_input: &Option<Value>) -> String {
        match tool_name {
            "Bash" => {
                let cmd = tool_input
                    .as_ref()
                    .and_then(|v| v.get("command"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let short = if cmd.len() > 30 { &cmd[..30] } else { cmd };
                format!("$ {short}")
            }
            "Read" => {
                let path = tool_input
                    .as_ref()
                    .and_then(|v| v.get("file_path"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let filename = path.rsplit('/').next().unwrap_or(path);
                format!("Reading {filename}")
            }
            "Edit" | "Write" => {
                let path = tool_input
                    .as_ref()
                    .and_then(|v| v.get("file_path"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let filename = path.rsplit('/').next().unwrap_or(path);
                format!("Editing {filename}")
            }
            "Grep" => "Searching...".to_string(),
            "Glob" => "Finding files...".to_string(),
            "Agent" => "Running agent...".to_string(),
            _ => format!("Running {tool_name}"),
        }
    }
}
