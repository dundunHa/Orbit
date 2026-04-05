use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const SOCKET_PATH: &str = "/tmp/orbit.sock";
const STATUSLINE_STATE_FILE: &str = "statusline-state.json";
const STATUSLINE_WRAPPER_FILE: &str = "statusline-wrapper.sh";
const HOOK_EVENTS: [&str; 10] = [
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

const STATUSLINE_WRAPPER_TEMPLATE: &str = r#"#!/bin/bash
# Orbit statusline wrapper — fail-open, non-blocking
# Captures token data for Orbit, then passes through to user's original statusline

# Read stdin once, save to variable
INPUT=$(cat 2>/dev/null || true)

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
if [ -n "$ORIGINAL_CMD" ]; then
    echo "$INPUT" | bash -lc "$ORIGINAL_CMD"
fi
"#;

#[derive(Serialize, Deserialize, Clone, Debug)]
struct StatuslineState {
    original_statusline: Option<Value>,
    original_was_absent: bool,
    managed_command: String,
    #[serde(default)]
    hook_command: Option<String>,
    install_id: String,
    installed_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum StatusLineConfig {
    Absent,
    StandardCommand { command: String },
    Unsupported,
    OrbitOrphaned,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum UninstallMode {
    RestoreOriginal,
    PreserveDrift,
    ForceCleanup,
}

#[derive(Debug)]
struct PreparedInstall {
    settings: Value,
    state: StatuslineState,
    wrapper_path: PathBuf,
    wrapper_script: String,
}

#[derive(Debug)]
struct PreparedUninstall {
    settings: Value,
    mode: UninstallMode,
    state: Option<StatuslineState>,
    files_to_remove: Vec<PathBuf>,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage: orbit-cli <command>");
        eprintln!("Commands:");
        eprintln!("  hook       Forward hook event from stdin to Orbit app");
        eprintln!("  statusline Forward statusline event from stdin to Orbit app");
        eprintln!("  install    Configure Claude Code hooks for Orbit");
        eprintln!("  uninstall  Remove Orbit hooks from Claude Code settings");
        std::process::exit(1);
    }

    match args[1].as_str() {
        "hook" => cmd_hook(),
        "statusline" => cmd_statusline(),
        "install" => cmd_install(),
        "uninstall" => cmd_uninstall(args.iter().any(|arg| arg == "--force")),
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
                    let control_payload = format!("{}\n", control_msg);
                    let _ = stream.write_all(control_payload.as_bytes());
                }

                let ask_response = serde_json::json!({
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": { "behavior": "ask" }
                    }
                });
                print!("{}", ask_response);
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
    let settings_path = match get_claude_settings_path() {
        Ok(path) => path,
        Err(e) => {
            eprintln!("Failed to locate Claude settings path: {e}");
            std::process::exit(1)
        }
    };

    let orbit_cli = match resolve_current_exe_path() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Failed to resolve orbit-cli path: {e}");
            std::process::exit(1)
        }
    };

    let hook_command = format!("{} hook", orbit_cli);
    println!("Installing Orbit hooks...");

    let result = with_file_lock(&settings_path, || {
        let current_settings = read_settings(&settings_path)?;
        ensure_settings_object(&current_settings)?;
        let prepared = prepare_install(current_settings.clone(), &orbit_cli, &hook_command)?;

        write_wrapper_script(&prepared.wrapper_path, &prepared.wrapper_script)?;

        if let Err(e) = write_settings(&settings_path, &prepared.settings) {
            let _ = remove_file_if_exists(&prepared.wrapper_path);
            return Err(e);
        }

        let state_path = get_statusline_state_path()?;
        if let Err(e) = write_statusline_state(&state_path, &prepared.state) {
            let _ = write_settings(&settings_path, &current_settings);
            let _ = remove_file_if_exists(&prepared.wrapper_path);
            let _ = remove_file_if_exists(&state_path);
            return Err(e);
        }

        Ok(())
    });

    if let Err(e) = result {
        eprintln!("Failed to install Orbit: {e}");
        std::process::exit(1);
    }

    println!("Done! Hooks registered in {}", settings_path.display());
    println!("Events: {}", HOOK_EVENTS.join(", "));
    println!("\nStart Orbit app, then use Claude Code as normal.");
}

fn cmd_uninstall(force: bool) {
    let settings_path = match get_claude_settings_path() {
        Ok(path) => path,
        Err(e) => {
            eprintln!("Failed to locate Claude settings path: {e}");
            std::process::exit(1)
        }
    };

    let settings_exists = settings_path.exists();
    if !settings_exists {
        println!("No settings file found at {}", settings_path.display());
    }

    let result = with_file_lock(&settings_path, || {
        let current_settings = if settings_exists {
            let settings = read_settings(&settings_path)?;
            ensure_settings_object(&settings)?;
            settings
        } else {
            Value::Object(Default::default())
        };

        let prepared = prepare_uninstall(current_settings, force)?;

        if matches!(prepared.mode, UninstallMode::PreserveDrift) {
            return Ok(prepared);
        }

        let mut settings_to_write = prepared.settings.clone();
        remove_orbit_hooks(
            &mut settings_to_write,
            &collect_hook_commands_for_cleanup(prepared.state.as_ref())?,
        )?;

        if settings_exists {
            write_settings(&settings_path, &settings_to_write)?;
        }

        for path in &prepared.files_to_remove {
            remove_file_if_exists(path)?;
        }

        Ok(prepared)
    });

    match result {
        Ok(prepared) => {
            if matches!(prepared.mode, UninstallMode::PreserveDrift) {
                return;
            }
            if settings_exists {
                println!("Orbit hooks removed from {}", settings_path.display());
            }
        }
        Err(e) => {
            eprintln!("Failed to uninstall Orbit: {e}");
            std::process::exit(1);
        }
    }
}

fn prepare_install(
    mut settings: Value,
    orbit_cli_path: &str,
    hook_command: &str,
) -> Result<PreparedInstall, String> {
    ensure_settings_object(&settings)?;

    let wrapper_path = get_statusline_wrapper_path()?;
    let managed_command = wrapper_path.to_string_lossy().to_string();
    let state_path = get_statusline_state_path()?;
    let current_command = get_statusline_command(&settings).map(str::to_string);

    if let Some(state) = read_statusline_state(&state_path)? {
        if current_command.as_deref() == Some(state.managed_command.as_str()) {
            if !wrapper_path.exists() {
                return Err(
                    "statusLine points to Orbit wrapper, but wrapper file is missing; run `orbit-cli uninstall --force` first"
                        .to_string(),
                );
            }

            let mut state = state;
            if state.hook_command.is_none() {
                state.hook_command = Some(hook_command.to_string());
            }

            let mut idempotent_settings = settings;
            add_orbit_hooks(&mut idempotent_settings, hook_command)?;
            return Ok(PreparedInstall {
                settings: idempotent_settings,
                state,
                wrapper_path,
                wrapper_script: render_wrapper_script(orbit_cli_path, current_command.as_deref()),
            });
        }

        return Err(
            "statusLine drift detected (current != managed); refusing to overwrite existing user config"
                .to_string(),
        );
    }

    match classify_statusline(&settings, &managed_command) {
        StatusLineConfig::Absent | StatusLineConfig::StandardCommand { .. } => {}
        StatusLineConfig::Unsupported => {
            return Err(
                "existing statusLine is not a supported {type:\"command\",command:\"...\"} object; refusing to take over"
                    .to_string(),
            )
        }
        StatusLineConfig::OrbitOrphaned => {
            return Err(
                "settings.json points to Orbit wrapper but no install state exists; run `orbit-cli uninstall --force` first"
                    .to_string(),
            )
        }
    }

    add_orbit_hooks(&mut settings, hook_command)?;

    let original_was_absent = settings.get("statusLine").is_none();
    let original_statusline = settings.get("statusLine").cloned();

    if let Some(obj) = settings.as_object_mut() {
        obj.insert(
            "statusLine".to_string(),
            serde_json::json!({
                "type": "command",
                "command": managed_command,
            }),
        );
    }

    Ok(PreparedInstall {
        settings,
        state: StatuslineState {
            original_statusline,
            original_was_absent,
            managed_command: wrapper_path.to_string_lossy().to_string(),
            hook_command: Some(hook_command.to_string()),
            install_id: generate_install_id(),
            installed_at: Utc::now().to_rfc3339(),
        },
        wrapper_script: render_wrapper_script(orbit_cli_path, current_command.as_deref()),
        wrapper_path,
    })
}

fn prepare_uninstall(mut settings: Value, force: bool) -> Result<PreparedUninstall, String> {
    ensure_settings_object(&settings)?;
    let state_path = get_statusline_state_path()?;
    let wrapper_path = get_statusline_wrapper_path()?;
    let current_command = get_statusline_command(&settings).map(str::to_string);

    let Some(state) = read_statusline_state(&state_path)? else {
        if force {
            let managed_command = wrapper_path.to_string_lossy().to_string();
            if current_command.as_deref() == Some(managed_command.as_str())
                && let Some(obj) = settings.as_object_mut()
            {
                obj.remove("statusLine");
            }

            return Ok(PreparedUninstall {
                settings,
                mode: UninstallMode::ForceCleanup,
                state: None,
                files_to_remove: vec![wrapper_path],
            });
        }

        return Ok(PreparedUninstall {
            settings,
            mode: UninstallMode::RestoreOriginal,
            state: None,
            files_to_remove: vec![],
        });
    };

    let mode = evaluate_uninstall_mode(current_command.as_deref(), &state, force);
    match mode {
        UninstallMode::PreserveDrift => {
            println!("Warning: statusLine was modified by user.");
            println!("Original config preserved in {}", state_path.display());
            println!("Run `orbit-cli uninstall --force` to forcibly clean up Orbit files.");
            Ok(PreparedUninstall {
                settings,
                mode,
                state: Some(state),
                files_to_remove: vec![],
            })
        }
        UninstallMode::RestoreOriginal | UninstallMode::ForceCleanup => {
            if let Some(obj) = settings.as_object_mut() {
                if state.original_was_absent {
                    obj.remove("statusLine");
                } else if let Some(original_statusline) = state.original_statusline.clone() {
                    obj.insert("statusLine".to_string(), original_statusline);
                } else {
                    obj.insert("statusLine".to_string(), Value::Null);
                }
            }

            Ok(PreparedUninstall {
                settings,
                mode,
                state: Some(state),
                files_to_remove: vec![state_path, wrapper_path],
            })
        }
    }
}

fn evaluate_uninstall_mode(
    current_command: Option<&str>,
    state: &StatuslineState,
    force: bool,
) -> UninstallMode {
    if current_command == Some(state.managed_command.as_str()) {
        return UninstallMode::RestoreOriginal;
    }

    if force {
        UninstallMode::ForceCleanup
    } else {
        UninstallMode::PreserveDrift
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

    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp_path = path.with_extension(format!("tmp.{}.{}", std::process::id(), unique));

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

fn with_file_lock<T>(path: &Path, f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    let lock_path = path.with_extension("json.lock");
    if let Some(parent) = lock_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create lock directory {}: {e}", parent.display()))?;
    }

    let lock_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&lock_path)
        .map_err(|e| format!("failed to open lock file {}: {e}", lock_path.display()))?;

    let rc = unsafe { libc::flock(lock_file.as_raw_fd(), libc::LOCK_EX) };
    if rc != 0 {
        return Err(format!("failed to acquire lock for {}", path.display()));
    }

    let result = f();
    let _ = unsafe { libc::flock(lock_file.as_raw_fd(), libc::LOCK_UN) };
    result
}

fn ensure_settings_object(settings: &Value) -> Result<(), String> {
    if settings.is_object() {
        Ok(())
    } else {
        Err("settings.json top-level value must be a JSON object".to_string())
    }
}

fn add_orbit_hooks(settings: &mut Value, hook_command: &str) -> Result<(), String> {
    ensure_settings_object(settings)?;

    let obj = settings.as_object_mut().expect("validated object above");
    let hooks_obj = obj
        .entry("hooks")
        .or_insert_with(|| Value::Object(Default::default()));

    if !hooks_obj.is_object() {
        return Err("settings.json hooks field must be an object when present".to_string());
    }

    let hooks = hooks_obj.as_object_mut().expect("validated object above");
    for event in &HOOK_EVENTS {
        let event_hooks = hooks
            .entry(event.to_string())
            .or_insert_with(|| Value::Array(vec![]));

        if !event_hooks.is_array() {
            return Err(format!("hooks.{event} must be an array when present"));
        }

        let arr = event_hooks.as_array_mut().expect("validated array above");
        let already_registered = arr
            .iter()
            .any(|entry| entry_has_hook_command(entry, hook_command));
        if !already_registered {
            arr.push(serde_json::json!({
                "hooks": [{
                    "type": "command",
                    "command": hook_command,
                }]
            }));
        }
    }

    Ok(())
}

fn remove_orbit_hooks(settings: &mut Value, commands: &[String]) -> Result<(), String> {
    if commands.is_empty() {
        return Ok(());
    }

    ensure_settings_object(settings)?;
    if let Some(hooks) = settings.get_mut("hooks").and_then(|h| h.as_object_mut()) {
        for (_event, entries) in hooks.iter_mut() {
            if let Some(arr) = entries.as_array_mut() {
                arr.retain(|entry| {
                    !commands
                        .iter()
                        .any(|command| entry_has_hook_command(entry, command))
                });
            }
        }
        hooks.retain(|_, v| v.as_array().map(|a| !a.is_empty()).unwrap_or(true));
    }

    if let Some(obj) = settings.as_object_mut() {
        let should_remove_hooks = obj
            .get("hooks")
            .and_then(|v| v.as_object())
            .is_some_and(|hooks| hooks.is_empty());
        if should_remove_hooks {
            obj.remove("hooks");
        }
    }

    Ok(())
}

fn entry_has_hook_command(entry: &Value, command: &str) -> bool {
    entry
        .get("hooks")
        .and_then(|h| h.as_array())
        .map(|hooks| {
            hooks.iter().any(|h| {
                h.get("type").and_then(|v| v.as_str()) == Some("command")
                    && h.get("command").and_then(|v| v.as_str()) == Some(command)
            })
        })
        .unwrap_or(false)
}

fn classify_statusline(settings: &Value, managed_command: &str) -> StatusLineConfig {
    let Some(statusline) = settings.get("statusLine") else {
        return StatusLineConfig::Absent;
    };

    if !statusline.is_object() {
        return StatusLineConfig::Unsupported;
    }

    let Some(command) = statusline.get("command").and_then(|v| v.as_str()) else {
        return StatusLineConfig::Unsupported;
    };

    if command == managed_command {
        return StatusLineConfig::OrbitOrphaned;
    }

    if statusline.get("type").and_then(|v| v.as_str()) != Some("command") {
        return StatusLineConfig::Unsupported;
    }

    if command.trim().is_empty() {
        return StatusLineConfig::Unsupported;
    }

    StatusLineConfig::StandardCommand {
        command: command.to_string(),
    }
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
        .and_then(|v| v.as_object())
        .and_then(|v| v.get("command"))
        .and_then(|v| v.as_str())
}

fn collect_hook_commands_for_cleanup(
    state: Option<&StatuslineState>,
) -> Result<Vec<String>, String> {
    let mut commands = Vec::new();
    if let Some(command) = state.and_then(|s| s.hook_command.clone()) {
        commands.push(command);
    }
    if let Ok(orbit_cli) = resolve_current_exe_path() {
        let current_hook = format!("{} hook", orbit_cli);
        if !commands.contains(&current_hook) {
            commands.push(current_hook);
        }
    }
    Ok(commands)
}

fn resolve_home_dir() -> Result<PathBuf, String> {
    dirs_next::home_dir().ok_or_else(|| "home directory not available".to_string())
}

fn get_orbit_dir() -> Result<PathBuf, String> {
    Ok(resolve_home_dir()?.join(".orbit"))
}

fn get_statusline_state_path() -> Result<PathBuf, String> {
    Ok(get_orbit_dir()?.join(STATUSLINE_STATE_FILE))
}

fn get_statusline_wrapper_path() -> Result<PathBuf, String> {
    Ok(get_orbit_dir()?.join(STATUSLINE_WRAPPER_FILE))
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

fn get_claude_settings_path() -> Result<PathBuf, String> {
    Ok(resolve_home_dir()?.join(".claude").join("settings.json"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::{Mutex, MutexGuard};

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct TestHome {
        _guard: MutexGuard<'static, ()>,
        path: PathBuf,
        old_home: Option<String>,
    }

    impl TestHome {
        fn new() -> Self {
            let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let path =
                std::env::temp_dir().join(format!("orbit-cli-home-{}", generate_install_id()));
            fs::create_dir_all(&path).unwrap();
            let old_home = std::env::var("HOME").ok();
            unsafe {
                std::env::set_var("HOME", &path);
            }

            Self {
                _guard: guard,
                path,
                old_home,
            }
        }

        fn settings_path(&self) -> PathBuf {
            self.path.join(".claude").join("settings.json")
        }

        fn state_path(&self) -> PathBuf {
            self.path.join(".orbit").join(STATUSLINE_STATE_FILE)
        }

        fn wrapper_path(&self) -> PathBuf {
            self.path.join(".orbit").join(STATUSLINE_WRAPPER_FILE)
        }
    }

    impl Drop for TestHome {
        fn drop(&mut self) {
            match &self.old_home {
                Some(old_home) => unsafe {
                    std::env::set_var("HOME", old_home);
                },
                None => unsafe {
                    std::env::remove_var("HOME");
                },
            }
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn run_install_for_test(home: &TestHome, initial_settings: Value) -> Result<(), String> {
        let settings_path = home.settings_path();
        if let Some(parent) = settings_path.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        write_settings(&settings_path, &initial_settings)?;

        let orbit_cli = "/opt/orbit-cli".to_string();
        let hook_command = format!("{} hook", orbit_cli);

        with_file_lock(&settings_path, || {
            let current_settings = read_settings(&settings_path)?;
            ensure_settings_object(&current_settings)?;
            let prepared = prepare_install(current_settings.clone(), &orbit_cli, &hook_command)?;

            write_wrapper_script(&prepared.wrapper_path, &prepared.wrapper_script)?;
            write_settings(&settings_path, &prepared.settings)?;
            write_statusline_state(&home.state_path(), &prepared.state)?;
            Ok(())
        })
    }

    fn run_uninstall_for_test(home: &TestHome, force: bool) -> Result<(), String> {
        let settings_path = home.settings_path();
        with_file_lock(&settings_path, || {
            let current_settings = read_settings(&settings_path)?;
            ensure_settings_object(&current_settings)?;
            let prepared = prepare_uninstall(current_settings, force)?;
            if matches!(prepared.mode, UninstallMode::PreserveDrift) {
                return Ok(());
            }

            let mut settings_to_write = prepared.settings.clone();
            remove_orbit_hooks(
                &mut settings_to_write,
                &collect_hook_commands_for_cleanup(prepared.state.as_ref())?,
            )?;
            write_settings(&settings_path, &settings_to_write)?;
            for path in &prepared.files_to_remove {
                remove_file_if_exists(path)?;
            }
            Ok(())
        })
    }

    fn managed_command() -> &'static str {
        "/Users/test/.orbit/statusline-wrapper.sh"
    }

    fn settings_with_statusline(statusline: Option<Value>) -> Value {
        let mut obj = serde_json::Map::new();
        if let Some(statusline) = statusline {
            obj.insert("statusLine".to_string(), statusline);
        }
        Value::Object(obj)
    }

    #[test]
    fn classify_statusline_absent() {
        assert_eq!(
            classify_statusline(&json!({}), managed_command()),
            StatusLineConfig::Absent
        );
    }

    #[test]
    fn classify_statusline_standard_command() {
        assert_eq!(
            classify_statusline(
                &settings_with_statusline(Some(
                    json!({"type": "command", "command": "/usr/local/bin/foo"})
                )),
                managed_command(),
            ),
            StatusLineConfig::StandardCommand {
                command: "/usr/local/bin/foo".to_string(),
            }
        );
    }

    #[test]
    fn classify_statusline_rejects_non_object() {
        assert_eq!(
            classify_statusline(
                &settings_with_statusline(Some(json!(true))),
                managed_command()
            ),
            StatusLineConfig::Unsupported
        );
    }

    #[test]
    fn classify_statusline_rejects_missing_command() {
        assert_eq!(
            classify_statusline(
                &settings_with_statusline(Some(json!({"type": "command"}))),
                managed_command(),
            ),
            StatusLineConfig::Unsupported
        );
    }

    #[test]
    fn classify_statusline_detects_orphaned_wrapper() {
        assert_eq!(
            classify_statusline(
                &settings_with_statusline(Some(
                    json!({"type": "command", "command": managed_command()})
                )),
                managed_command(),
            ),
            StatusLineConfig::OrbitOrphaned
        );
    }

    #[test]
    fn ensure_settings_object_fails_for_non_object() {
        assert!(ensure_settings_object(&json!([1, 2, 3])).is_err());
    }

    #[test]
    fn add_orbit_hooks_is_exact_and_idempotent() {
        let mut settings = json!({
            "hooks": {
                "PostToolUse": [
                    {"hooks": [{"type": "command", "command": "/usr/local/bin/orbital-tool hook"}]}
                ]
            }
        });

        add_orbit_hooks(&mut settings, "/opt/orbit-cli hook").unwrap();
        add_orbit_hooks(&mut settings, "/opt/orbit-cli hook").unwrap();

        let post_tool_use = settings
            .get("hooks")
            .and_then(|v| v.get("PostToolUse"))
            .and_then(|v| v.as_array())
            .unwrap();

        let exact_count = post_tool_use
            .iter()
            .filter(|entry| entry_has_hook_command(entry, "/opt/orbit-cli hook"))
            .count();
        assert_eq!(exact_count, 1);
        assert!(
            post_tool_use
                .iter()
                .any(|entry| entry_has_hook_command(entry, "/usr/local/bin/orbital-tool hook"))
        );
    }

    #[test]
    fn remove_orbit_hooks_keeps_non_orbit_strings() {
        let mut settings = json!({
            "hooks": {
                "PostToolUse": [
                    {"hooks": [{"type": "command", "command": "/opt/orbit-cli hook"}]},
                    {"hooks": [{"type": "command", "command": "/usr/local/bin/orbital-tool hook"}]}
                ]
            }
        });

        remove_orbit_hooks(&mut settings, &["/opt/orbit-cli hook".to_string()]).unwrap();

        let post_tool_use = settings
            .get("hooks")
            .and_then(|v| v.get("PostToolUse"))
            .and_then(|v| v.as_array())
            .unwrap();

        assert_eq!(post_tool_use.len(), 1);
        assert!(entry_has_hook_command(
            &post_tool_use[0],
            "/usr/local/bin/orbital-tool hook"
        ));
    }

    #[test]
    fn uninstall_mode_preserves_drift_without_force() {
        let state = StatuslineState {
            original_statusline: None,
            original_was_absent: true,
            managed_command: managed_command().to_string(),
            hook_command: Some("/opt/orbit-cli hook".to_string()),
            install_id: "test".to_string(),
            installed_at: "2026-01-01T00:00:00Z".to_string(),
        };

        assert_eq!(
            evaluate_uninstall_mode(Some("/usr/local/bin/other"), &state, false),
            UninstallMode::PreserveDrift
        );
        assert_eq!(
            evaluate_uninstall_mode(Some("/usr/local/bin/other"), &state, true),
            UninstallMode::ForceCleanup
        );
        assert_eq!(
            evaluate_uninstall_mode(Some(managed_command()), &state, false),
            UninstallMode::RestoreOriginal
        );
    }

    #[test]
    fn render_wrapper_script_is_fail_open() {
        let script = render_wrapper_script(
            "/Applications/Orbit.app/Contents/MacOS/orbit-cli",
            Some("/usr/local/bin/my-statusline --flag"),
        );
        assert!(script.contains("bash -lc \"$ORIGINAL_CMD\""));
        assert!(script.contains("cat 2>/dev/null || true"));
        assert!(!script.contains("set -eo pipefail"));
    }

    #[test]
    fn atomic_write_uses_unique_suffix_and_writes_content() {
        let path =
            std::env::temp_dir().join(format!("orbit-cli-test-{}.json", generate_install_id()));
        atomic_write(&path, br#"{"ok":true}"#).unwrap();
        let content = fs::read_to_string(&path).unwrap();
        assert_eq!(content, r#"{"ok":true}"#);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn shell_single_quote_handles_quotes() {
        assert_eq!(shell_single_quote("foo'bar"), "'foo'\"'\"'bar'");
    }

    #[test]
    fn collect_hook_commands_prefers_state_but_includes_current_binary() {
        let state = StatuslineState {
            original_statusline: None,
            original_was_absent: true,
            managed_command: managed_command().to_string(),
            hook_command: Some("/opt/orbit-cli hook".to_string()),
            install_id: "test".to_string(),
            installed_at: "2026-01-01T00:00:00Z".to_string(),
        };
        let commands = collect_hook_commands_for_cleanup(Some(&state)).unwrap();
        assert!(commands.contains(&"/opt/orbit-cli hook".to_string()));
        assert!(!commands.is_empty());
    }

    #[test]
    fn entry_has_hook_command_requires_exact_match() {
        let entry = json!({
            "hooks": [{"type": "command", "command": "/usr/local/bin/orbital-tool hook"}]
        });
        assert!(entry_has_hook_command(
            &entry,
            "/usr/local/bin/orbital-tool hook"
        ));
        assert!(!entry_has_hook_command(
            &entry,
            "/usr/local/bin/orbit-cli hook"
        ));
    }

    #[test]
    fn install_then_uninstall_restores_original_statusline_and_removes_files() {
        let home = TestHome::new();
        let original_settings = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/original-status --flag"
            }
        });

        run_install_for_test(&home, original_settings.clone()).unwrap();

        let installed = read_settings(&home.settings_path()).unwrap();
        let installed_command = get_statusline_command(&installed).unwrap().to_string();
        assert_eq!(installed_command, home.wrapper_path().to_string_lossy());
        assert!(home.wrapper_path().exists());
        assert!(home.state_path().exists());

        run_uninstall_for_test(&home, false).unwrap();

        let restored = read_settings(&home.settings_path()).unwrap();
        assert_eq!(restored, original_settings);
        assert!(!home.wrapper_path().exists());
        assert!(!home.state_path().exists());
    }

    #[test]
    fn install_then_uninstall_restores_absent_statusline() {
        let home = TestHome::new();
        let original_settings = json!({
            "hooks": {}
        });

        run_install_for_test(&home, original_settings).unwrap();
        let installed = read_settings(&home.settings_path()).unwrap();
        assert_eq!(
            get_statusline_command(&installed).unwrap(),
            home.wrapper_path().to_string_lossy()
        );

        run_uninstall_for_test(&home, false).unwrap();
        let restored = read_settings(&home.settings_path()).unwrap();
        assert!(restored.get("statusLine").is_none());
    }

    #[test]
    fn uninstall_drift_keeps_state_and_wrapper_until_force() {
        let home = TestHome::new();
        let original_settings = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/original-status"
            }
        });

        run_install_for_test(&home, original_settings).unwrap();

        let drifted = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/user-modified"
            }
        });
        write_settings(&home.settings_path(), &drifted).unwrap();

        run_uninstall_for_test(&home, false).unwrap();
        let after_drift_uninstall = read_settings(&home.settings_path()).unwrap();
        assert_eq!(after_drift_uninstall, drifted);
        assert!(home.wrapper_path().exists());
        assert!(home.state_path().exists());

        run_uninstall_for_test(&home, true).unwrap();
        let after_force = read_settings(&home.settings_path()).unwrap();
        assert_eq!(
            after_force,
            json!({
                "statusLine": {
                    "type": "command",
                    "command": "/usr/local/bin/original-status"
                }
            })
        );
        assert!(!home.wrapper_path().exists());
        assert!(!home.state_path().exists());
    }

    #[test]
    fn install_rejects_non_standard_statusline_on_real_filesystem() {
        let home = TestHome::new();
        let settings = json!({
            "statusLine": {
                "type": "builtin",
                "name": "unsupported"
            }
        });

        let err = run_install_for_test(&home, settings).unwrap_err();
        assert!(err.contains("refusing to take over"));
        assert!(!home.wrapper_path().exists());
        assert!(!home.state_path().exists());
    }

    #[test]
    fn install_rejects_non_object_settings_top_level_on_real_filesystem() {
        let home = TestHome::new();
        let settings_path = home.settings_path();
        if let Some(parent) = settings_path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&settings_path, "[]").unwrap();

        let orbit_cli = "/opt/orbit-cli".to_string();
        let hook_command = format!("{} hook", orbit_cli);
        let err = with_file_lock(&settings_path, || {
            let current_settings = read_settings(&settings_path)?;
            ensure_settings_object(&current_settings)?;
            let _ = prepare_install(current_settings, &orbit_cli, &hook_command)?;
            Ok(())
        })
        .unwrap_err();

        assert!(err.contains("top-level value must be a JSON object"));
        assert!(!home.wrapper_path().exists());
        assert!(!home.state_path().exists());
    }
}
