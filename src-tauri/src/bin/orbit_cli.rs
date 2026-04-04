use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

const SOCKET_PATH: &str = "/tmp/orbit.sock";
const STATUSLINE_STATE_FILE: &str = "statusline-state.json";
const STATUSLINE_WRAPPER_FILE: &str = "statusline-wrapper.sh";

const STATUSLINE_WRAPPER_TEMPLATE: &str = r#"#!/bin/bash
# Orbit statusline wrapper — fail-open, non-blocking
# Captures token data for Orbit, then passes through to user's original statusline

set -eo pipefail

# Read stdin once, save to variable
INPUT=$(cat)

# Send to Orbit (non-blocking, fail-open)
ORBIT_CLI=__ORBIT_CLI_PATH__
if [ -n "$ORBIT_CLI" ]; then
    (
        if command -v perl >/dev/null 2>&1; then
            echo "$INPUT" | perl -e 'alarm 2; system @ARGV' "$ORBIT_CLI" statusline >/dev/null 2>&1 || true
        else
            echo "$INPUT" | "$ORBIT_CLI" statusline >/dev/null 2>&1 || true
        fi
    ) &
    disown 2>/dev/null || true
fi

# Pass through to original statusline script (if any)
ORIGINAL_CMD=__ORBIT_ORIGINAL_CMD__
if [ -n "$ORIGINAL_CMD" ] && [ "$ORIGINAL_CMD" != "__ORBIT_ORIGINAL_CMD__" ]; then
    echo "$INPUT" | bash -lc "$ORIGINAL_CMD"
fi
"#;

#[derive(Serialize, Deserialize)]
struct StatuslineState {
    original_statusline: Option<Value>,
    original_was_absent: bool,
    managed_command: String,
    install_id: String,
    installed_at: String,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage: orbit-cli <command>");
        eprintln!("Commands:");
        eprintln!("  hook      Forward hook event from stdin to Orbit app");
        eprintln!("  statusline Forward statusline event from stdin to Orbit app");
        eprintln!("  install   Configure Claude Code hooks for Orbit");
        eprintln!("  uninstall Remove Orbit hooks from Claude Code settings");
        std::process::exit(1);
    }

    match args[1].as_str() {
        "hook" => cmd_hook(),
        "statusline" => cmd_statusline(),
        "install" => cmd_install(),
        "uninstall" => cmd_uninstall(),
        _ => {
            eprintln!("Unknown command: {}", args[1]);
            std::process::exit(1);
        }
    }
}

fn cmd_hook() {
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        std::process::exit(1);
    }

    let input = input.trim();
    if input.is_empty() {
        std::process::exit(0);
    }

    let is_permission_request = serde_json::from_str::<Value>(input)
        .ok()
        .and_then(|val| {
            val.get("hook_event_name")
                .and_then(|v| v.as_str())
                .map(|s| s == "PermissionRequest")
        })
        .unwrap_or(false);

    match UnixStream::connect(SOCKET_PATH) {
        Ok(mut stream) => {
            if is_permission_request {
                if let Ok(val) = serde_json::from_str::<Value>(input) {
                    let control_msg = serde_json::json!({
                        "type": "PermissionRequestHandledByCli",
                        "session_id": val.get("session_id"),
                        "tool_use_id": val.get("tool_use_id")
                    });
                    let control_payload = format!("{}\n", control_msg.to_string());
                    let _ = stream.write_all(control_payload.as_bytes());
                }

                let ask_response = serde_json::json!({
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": { "behavior": "ask" }
                    }
                });
                print!("{}", ask_response.to_string());
            } else {
                let payload = format!("{}\n", input);
                if stream.write_all(payload.as_bytes()).is_err() {
                    std::process::exit(0);
                }
            }
        }
        Err(_) => {
            std::process::exit(0);
        }
    }
}

fn cmd_statusline() {
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        std::process::exit(0);
    }

    let input = input.trim();
    if input.is_empty() {
        std::process::exit(0);
    }

    let Ok(val) = serde_json::from_str::<Value>(input) else {
        std::process::exit(0)
    };

    let session_id = val
        .get("session_id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let tokens_in = val
        .get("context_window")
        .and_then(|v| v.get("total_input_tokens"))
        .and_then(|v| v.as_u64());
    let tokens_out = val
        .get("context_window")
        .and_then(|v| v.get("total_output_tokens"))
        .and_then(|v| v.as_u64());
    let cost_usd = val
        .get("cost")
        .and_then(|v| v.get("total_cost_usd"))
        .and_then(|v| v.as_f64());
    let model = val
        .get("model")
        .and_then(|v| v.get("id"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let msg = serde_json::json!({
        "type": "StatuslineUpdate",
        "session_id": session_id,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "cost_usd": cost_usd,
        "model": model
    });

    if let Ok(mut stream) = UnixStream::connect(SOCKET_PATH) {
        let payload = format!("{}\n", msg);
        let _ = stream.write_all(payload.as_bytes());
    }

    std::process::exit(0);
}

fn cmd_install() {
    let settings_path = get_claude_settings_path();
    println!("Installing Orbit hooks...");

    let mut settings = match read_settings(&settings_path) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Failed to read {}: {e}", settings_path.display());
            std::process::exit(1)
        }
    };

    // Ensure top-level is an object
    if !settings.is_object() {
        settings = Value::Object(Default::default());
    }

    let orbit_cli = match resolve_current_exe_path() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Failed to resolve orbit-cli path: {e}");
            std::process::exit(1)
        }
    };

    let hook_command = format!("{} hook", orbit_cli);

    let events = [
        "PreToolUse",
        "PostToolUse",
        "Stop",
        "SessionStart",
        "SessionEnd",
        "PermissionRequest",
        "Notification",
        "UserPromptSubmit",
        "SubagentStop",
        "PreCompact",
    ];

    let obj = settings.as_object_mut().expect("ensured object above");
    let hooks_obj = obj
        .entry("hooks")
        .or_insert_with(|| Value::Object(Default::default()));

    if !hooks_obj.is_object() {
        *hooks_obj = Value::Object(Default::default());
    }

    let hooks = hooks_obj.as_object_mut().expect("ensured object above");

    for event in &events {
        let event_hooks = hooks
            .entry(event.to_string())
            .or_insert_with(|| Value::Array(vec![]));

        if !event_hooks.is_array() {
            *event_hooks = Value::Array(vec![]);
        }

        let arr = event_hooks.as_array_mut().expect("ensured array above");

        let already_registered = arr.iter().any(|entry| {
            entry
                .get("hooks")
                .and_then(|h| h.as_array())
                .map(|hooks| {
                    hooks.iter().any(|h| {
                        h.get("command")
                            .and_then(|c| c.as_str())
                            .is_some_and(|c| c.contains("orbit"))
                    })
                })
                .unwrap_or(false)
        });

        if !already_registered {
            arr.push(serde_json::json!({
                "hooks": [{
                    "type": "command",
                    "command": hook_command
                }]
            }));
        }
    }

    if let Err(e) = install_statusline_wrapper(&mut settings, &orbit_cli) {
        eprintln!("Failed to install statusLine wrapper: {e}");
        std::process::exit(1);
    }

    if let Err(e) = write_settings(&settings_path, &settings) {
        eprintln!("Failed to write {}: {e}", settings_path.display());
        std::process::exit(1);
    }

    println!("Done! Hooks registered in {}", settings_path.display());
    println!("Events: {}", events.join(", "));
    println!("\nStart Orbit app, then use Claude Code as normal.");
}

fn cmd_uninstall() {
    let settings_path = get_claude_settings_path();
    let settings_exists = settings_path.exists();

    if !settings_exists {
        println!("No settings file found at {}", settings_path.display());
    }

    let mut settings = if settings_exists {
        match read_settings(&settings_path) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("Failed to read {}: {e}", settings_path.display());
                std::process::exit(1)
            }
        }
    } else {
        Value::Object(Default::default())
    };

    if settings_exists {
        if let Some(hooks) = settings.get_mut("hooks").and_then(|h| h.as_object_mut()) {
            for (_event, entries) in hooks.iter_mut() {
                if let Some(arr) = entries.as_array_mut() {
                    arr.retain(|entry| {
                        !entry
                            .get("hooks")
                            .and_then(|h| h.as_array())
                            .map(|hooks| {
                                hooks.iter().any(|h| {
                                    h.get("command")
                                        .and_then(|c| c.as_str())
                                        .is_some_and(|c| c.contains("orbit"))
                                })
                            })
                            .unwrap_or(false)
                    });
                }
            }

            hooks.retain(|_, v| v.as_array().map(|a| !a.is_empty()).unwrap_or(true));
        }
    }

    if let Err(e) = uninstall_statusline_wrapper(&mut settings) {
        eprintln!("Failed to uninstall statusLine wrapper: {e}");
        std::process::exit(1);
    }

    if settings_exists {
        if let Err(e) = write_settings(&settings_path, &settings) {
            eprintln!("Failed to write {}: {e}", settings_path.display());
            std::process::exit(1);
        }
        println!("Orbit hooks removed from {}", settings_path.display());
    }
}

fn read_settings(path: &PathBuf) -> Result<Value, String> {
    if !path.exists() {
        return Ok(Value::Object(Default::default()));
    }

    let content =
        fs::read_to_string(path).map_err(|e| format!("failed to read {}: {e}", path.display()))?;
    serde_json::from_str(&content)
        .map_err(|e| format!("failed to parse {} as JSON: {e}", path.display()))
}

fn write_settings(path: &PathBuf, settings: &Value) -> Result<(), String> {
    let pretty = serde_json::to_string_pretty(settings)
        .map_err(|e| format!("failed to serialize settings: {e}"))?;
    atomic_write(path, pretty.as_bytes())
}

fn atomic_write(path: &PathBuf, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create directory {}: {e}", parent.display()))?;
    }

    let tmp_path = path.with_extension("tmp");

    let mut tmp_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&tmp_path)
        .map_err(|e| format!("failed to open temp file {}: {e}", tmp_path.display()))?;

    tmp_file
        .write_all(bytes)
        .map_err(|e| format!("failed to write temp file {}: {e}", tmp_path.display()))?;

    tmp_file
        .sync_all()
        .map_err(|e| format!("failed to fsync temp file {}: {e}", tmp_path.display()))?;

    drop(tmp_file);

    fs::rename(&tmp_path, path).map_err(|e| {
        let _ = fs::remove_file(&tmp_path);
        format!(
            "failed to atomically rename {} to {}: {e}",
            tmp_path.display(),
            path.display()
        )
    })?;

    Ok(())
}

fn install_statusline_wrapper(settings: &mut Value, orbit_cli_path: &str) -> Result<(), String> {
    let state_path = get_statusline_state_path();
    let wrapper_path = get_statusline_wrapper_path();
    let managed_command = wrapper_path.to_string_lossy().to_string();
    let current_command = get_statusline_command(settings).map(|s| s.to_string());

    if let Some(state) = read_statusline_state(&state_path)? {
        if current_command.as_deref() == Some(state.managed_command.as_str()) {
            println!("statusLine wrapper already installed, skipping.");
            return Ok(());
        }

        println!(
            "Warning: statusLine drift detected (current != managed), skipping wrapper install."
        );
        return Ok(());
    }

    let original_was_absent = settings.get("statusLine").is_none();
    let original_statusline = if original_was_absent {
        None
    } else {
        settings.get("statusLine").cloned()
    };

    let state = StatuslineState {
        original_statusline,
        original_was_absent,
        managed_command: managed_command.clone(),
        install_id: generate_install_id(),
        installed_at: Utc::now().to_rfc3339(),
    };
    write_statusline_state(&state_path, &state)?;

    let wrapper_script = render_wrapper_script(orbit_cli_path, current_command.as_deref());
    if let Err(e) = write_wrapper_script(&wrapper_path, &wrapper_script) {
        let _ = remove_file_if_exists(&state_path);
        return Err(e);
    }

    if let Some(obj) = settings.as_object_mut() {
        obj.insert(
            "statusLine".to_string(),
            serde_json::json!({
                "type": "command",
                "command": managed_command
            }),
        );
    }

    println!(
        "Installed statusLine wrapper at {}",
        wrapper_path.to_string_lossy()
    );

    Ok(())
}

fn uninstall_statusline_wrapper(settings: &mut Value) -> Result<(), String> {
    let state_path = get_statusline_state_path();
    let wrapper_path = get_statusline_wrapper_path();

    let Some(state) = read_statusline_state(&state_path)? else {
        return Ok(());
    };

    let current_command = get_statusline_command(settings).map(|s| s.to_string());

    if current_command.as_deref() != Some(state.managed_command.as_str()) {
        println!("Warning: statusLine was modified by user, not restoring");
    } else {
        if !settings.is_object() {
            *settings = Value::Object(Default::default());
        }

        if let Some(obj) = settings.as_object_mut() {
            if state.original_was_absent {
                obj.remove("statusLine");
            } else {
                obj.insert(
                    "statusLine".to_string(),
                    state.original_statusline.unwrap_or(Value::Null),
                );
            }
        }
    }

    remove_file_if_exists(&state_path)?;
    remove_file_if_exists(&wrapper_path)?;

    Ok(())
}

fn read_statusline_state(path: &PathBuf) -> Result<Option<StatuslineState>, String> {
    if !path.exists() {
        return Ok(None);
    }

    let content = fs::read_to_string(path)
        .map_err(|e| format!("failed to read statusline state {}: {e}", path.display()))?;
    let state = serde_json::from_str::<StatuslineState>(&content)
        .map_err(|e| format!("failed to parse statusline state {}: {e}", path.display()))?;

    Ok(Some(state))
}

fn write_statusline_state(path: &PathBuf, state: &StatuslineState) -> Result<(), String> {
    let content = serde_json::to_string_pretty(state)
        .map_err(|e| format!("failed to serialize statusline state: {e}"))?;
    atomic_write(path, content.as_bytes())
}

fn write_wrapper_script(path: &PathBuf, script: &str) -> Result<(), String> {
    atomic_write(path, script.as_bytes())?;
    let mut perms = fs::metadata(path)
        .map_err(|e| format!("failed to read wrapper metadata {}: {e}", path.display()))?
        .permissions();
    perms.set_mode(0o755);
    fs::set_permissions(path, perms).map_err(|e| {
        format!(
            "failed to set wrapper executable bit {}: {e}",
            path.display()
        )
    })
}

fn remove_file_if_exists(path: &PathBuf) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("failed to remove {}: {e}", path.display())),
    }
}

fn get_statusline_command(settings: &Value) -> Option<&str> {
    settings
        .get("statusLine")
        .and_then(|v| v.get("command"))
        .and_then(|v| v.as_str())
}

fn get_orbit_dir() -> PathBuf {
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join(".orbit")
}

fn get_statusline_state_path() -> PathBuf {
    get_orbit_dir().join(STATUSLINE_STATE_FILE)
}

fn get_statusline_wrapper_path() -> PathBuf {
    get_orbit_dir().join(STATUSLINE_WRAPPER_FILE)
}

fn resolve_current_exe_path() -> Result<String, String> {
    let exe = std::env::current_exe()
        .map_err(|e| format!("failed to resolve current executable: {e}"))?;
    let abs = if exe.is_absolute() {
        exe
    } else {
        let cwd =
            std::env::current_dir().map_err(|e| format!("failed to resolve current dir: {e}"))?;
        cwd.join(exe)
    };
    Ok(abs.to_string_lossy().to_string())
}

fn shell_single_quote(s: &str) -> String {
    if s.is_empty() {
        "''".to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\"'\"'"))
    }
}

fn render_wrapper_script(orbit_cli_path: &str, original_command: Option<&str>) -> String {
    STATUSLINE_WRAPPER_TEMPLATE
        .replace("__ORBIT_CLI_PATH__", &shell_single_quote(orbit_cli_path))
        .replace(
            "__ORBIT_ORIGINAL_CMD__",
            &shell_single_quote(original_command.unwrap_or("")),
        )
}

fn generate_install_id() -> String {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("orbit-{}-{ts}", std::process::id())
}

fn get_claude_settings_path() -> PathBuf {
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join(".claude").join("settings.json")
}
