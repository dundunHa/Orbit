//! Shared installation logic for Orbit.
//!
//! The app bundle ships with an internal helper binary that Claude Code calls
//! for hook and statusline integration. The GUI owns install/uninstall flow;
//! the helper only bridges stdin/stdout payloads into the running app.

use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Default path to the Unix socket for communication with the Orbit app.
pub const SOCKET_PATH: &str = "/tmp/orbit.sock";
pub const SOCKET_PATH_ENV: &str = "ORBIT_SOCKET_PATH";
const STATUSLINE_STATE_FILE: &str = "statusline-state.json";
const STATUSLINE_WRAPPER_FILE: &str = "statusline-wrapper.sh";
const CLI_BINARY_NAME: &str = "orbit-cli";
const HELPER_BINARY_NAME: &str = "orbit-helper";
const FALLBACK_ORBIT_HELPER_PATH: &str = "/Applications/Orbit.app/Contents/MacOS/orbit-helper";

#[cfg(test)]
pub(crate) static TEST_HOME_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Hook events that Orbit registers with Claude Code
pub const HOOK_EVENTS: [&str; 13] = [
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "Stop",
    "SessionStart",
    "SessionEnd",
    "PermissionRequest",
    "Notification",
    "UserPromptSubmit",
    "SubagentStop",
    "PreCompact",
    "Elicitation",
    "ElicitationResult",
];

pub fn socket_path() -> String {
    std::env::var(SOCKET_PATH_ENV).unwrap_or_else(|_| SOCKET_PATH.to_string())
}

/// Template for the statusline wrapper script
const STATUSLINE_WRAPPER_TEMPLATE: &str = r#"#!/bin/bash
# Orbit statusline wrapper — fail-open, non-blocking
# Captures token data for Orbit, then passes through to user's original statusline

# Read stdin once, save to variable
INPUT=$(cat 2>/dev/null || true)

# Send to Orbit (non-blocking, fail-open)
ORBIT_HELPER=__ORBIT_HELPER_PATH__
if [ -n "$ORBIT_HELPER" ]; then
    (
        if command -v perl >/dev/null 2>&1; then
            echo "$INPUT" | perl -e 'alarm 2; system @ARGV' "$ORBIT_HELPER" statusline >/dev/null 2>&1 || true
        else
            echo "$INPUT" | "$ORBIT_HELPER" statusline >/dev/null 2>&1 || true
        fi
    ) &
    disown 2>/dev/null || true
fi

# Pass through to original statusline script (if any)
ORIGINAL_CMD=__ORBIT_ORIGINAL_CMD__
if [ -n "$ORIGINAL_CMD" ]; then
    if [ "$ORIGINAL_CMD" = "$0" ]; then
        exit 0
    fi

    echo "$INPUT" | /bin/bash -lc "$ORIGINAL_CMD"
fi
"#;

/// Tracks the state of a statusline installation
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct StatuslineState {
    /// The original statusline configuration before Orbit took over
    pub original_statusline: Option<Value>,
    /// Whether statusLine was originally absent
    pub original_was_absent: bool,
    /// Path to the managed wrapper script
    pub managed_command: String,
    /// The hook command registered with Claude Code
    #[serde(default)]
    pub hook_command: Option<String>,
    /// Unique ID for this installation
    pub install_id: String,
    /// ISO 8601 timestamp of installation
    pub installed_at: String,
}

/// Classification of the current statusLine configuration
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StatusLineConfig {
    /// No statusLine is configured
    Absent,
    /// Standard command-type statusLine
    StandardCommand { command: String },
    /// Unsupported configuration (non-standard type)
    Unsupported,
    /// Points to Orbit wrapper but no state file exists
    OrbitOrphaned,
}

/// Mode for uninstallation
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UninstallMode {
    /// Restore the original statusline configuration
    RestoreOriginal,
    /// Preserve user modifications (drift detected)
    PreserveDrift,
    /// Force cleanup even with drift
    ForceCleanup,
}

/// Prepared installation data
#[derive(Debug)]
pub struct PreparedInstall {
    /// The modified settings to write
    pub settings: Value,
    /// Installation state to persist
    pub state: StatuslineState,
    /// Path where wrapper script should be written
    pub wrapper_path: PathBuf,
    /// Content of the wrapper script
    pub wrapper_script: String,
}

/// Prepared uninstallation data
#[derive(Debug)]
pub struct PreparedUninstall {
    /// The modified settings to write
    pub settings: Value,
    /// Uninstall mode determined
    pub mode: UninstallMode,
    /// State file contents (if exists)
    pub state: Option<StatuslineState>,
    /// Files to remove
    pub files_to_remove: Vec<PathBuf>,
}

/// Errors that can occur during installation
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallError {
    /// Permission denied when writing files
    PermissionDenied,
    /// Configuration drift detected
    Drift,
    /// Another tool is using statusline
    Conflict(String),
    /// General error with message
    Other(String),
}

impl std::fmt::Display for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InstallError::PermissionDenied => write!(f, "Permission denied"),
            InstallError::Drift => write!(f, "Configuration drift detected"),
            InstallError::Conflict(tool) => write!(f, "Conflict with tool: {}", tool),
            InstallError::Other(msg) => write!(f, "{}", msg),
        }
    }
}

impl std::error::Error for InstallError {}

impl From<String> for InstallError {
    fn from(s: String) -> Self {
        InstallError::Other(s)
    }
}

impl InstallError {
    /// Classify a string error, promoting permission-related messages to
    /// `PermissionDenied`. Centralises the heuristic so a future migration
    /// to structured `io::Error` propagation only needs to touch one site.
    fn from_io_string(e: String) -> Self {
        if e.contains("Permission") || e.contains("permission") {
            InstallError::PermissionDenied
        } else {
            InstallError::Other(e)
        }
    }
}

/// Installation state for GUI auto-install flow
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallState {
    /// Orbit is already installed and healthy
    OrbitInstalled,
    /// Not installed, ready for installation
    NotInstalled,
    /// Configuration drift detected (user modified after install)
    DriftDetected,
    /// Another tool is using statusline
    OtherTool(String),
    /// Orbit wrapper exists but state file is missing
    Orphaned,
}

/// Check the current installation state without modifying anything
pub fn check_install_state(orbit_helper_path: &str) -> Result<InstallState, InstallError> {
    let settings_path = get_claude_settings_path()
        .map_err(|e| InstallError::Other(format!("Failed to get settings path: {}", e)))?;
    let state_path = get_statusline_state_path()
        .map_err(|e| InstallError::Other(format!("Failed to get state path: {}", e)))?;
    let wrapper_path = get_statusline_wrapper_path()
        .map_err(|e| InstallError::Other(format!("Failed to get wrapper path: {}", e)))?;

    let managed_command = wrapper_path.to_string_lossy().to_string();

    // Read current settings
    let settings = read_settings(&settings_path)
        .map_err(|e| InstallError::Other(format!("Failed to read settings: {}", e)))?;

    // Check if we have state file
    let state = read_statusline_state(&state_path)
        .map_err(|e| InstallError::Other(format!("Failed to read state: {}", e)))?;

    let current_command = get_statusline_command(&settings).map(str::to_string);
    let desired_hook_command = helper_hook_command(orbit_helper_path);

    // Check if we have state first - this determines if Orbit was ever installed
    if let Some(state) = state {
        // We have state file - check if statusLine still points to our wrapper
        if current_command.as_deref() == Some(state.managed_command.as_str()) {
            // statusLine matches our managed command
            if !wrapper_path.exists() {
                Ok(InstallState::Orphaned)
            } else if !settings_have_required_hook_commands(&settings, &desired_hook_command)
                || state.hook_command.as_deref() != Some(desired_hook_command.as_str())
            {
                Ok(InstallState::NotInstalled)
            } else {
                Ok(InstallState::OrbitInstalled)
            }
        } else {
            // statusLine has changed from our managed command
            // Check if it's pointing to something else
            if let Some(cmd) = current_command {
                if cmd == managed_command {
                    // This shouldn't happen due to the check above, but just in case
                    Ok(InstallState::Orphaned)
                } else {
                    Ok(InstallState::DriftDetected)
                }
            } else {
                // statusLine was removed entirely
                Ok(InstallState::DriftDetected)
            }
        }
    } else {
        // No state file - check current statusLine
        match classify_statusline(&settings, &managed_command) {
            StatusLineConfig::OrbitOrphaned => {
                // Settings point to our wrapper but no state - truly orphaned
                Ok(InstallState::Orphaned)
            }
            StatusLineConfig::Unsupported => {
                // Something else is using statusLine
                if let Some(cmd) = current_command {
                    Ok(InstallState::OtherTool(cmd))
                } else {
                    Ok(InstallState::OtherTool("unknown".to_string()))
                }
            }
            StatusLineConfig::StandardCommand { .. } => Ok(InstallState::NotInstalled),
            StatusLineConfig::Absent => Ok(InstallState::NotInstalled),
        }
    }
}

/// Attempt silent installation (for GUI auto-install)
pub fn silent_install(orbit_cli_path: &str) -> Result<(), InstallError> {
    let hook_command = format!("{} hook", orbit_cli_path);

    let settings_path = get_claude_settings_path()
        .map_err(|e| InstallError::Other(format!("Failed to get settings path: {}", e)))?;

    with_file_lock(&settings_path, || {
        let current_settings = read_settings(&settings_path)
            .map_err(|e| InstallError::Other(format!("Failed to read settings: {}", e)))?;
        ensure_settings_object(&current_settings)
            .map_err(|e| InstallError::Other(format!("Invalid settings: {}", e)))?;

        let prepared = prepare_install(current_settings.clone(), orbit_cli_path, &hook_command)
            .map_err(InstallError::from_io_string)?;

        write_wrapper_script(&prepared.wrapper_path, &prepared.wrapper_script)
            .map_err(InstallError::from_io_string)?;

        if let Err(e) = write_settings(&settings_path, &prepared.settings) {
            let _ = remove_file_if_exists(&prepared.wrapper_path);
            return Err(InstallError::from_io_string(e));
        }

        let state_path = get_statusline_state_path().map_err(InstallError::Other)?;
        if let Err(e) = write_statusline_state(&state_path, &prepared.state) {
            let _ = write_settings(&settings_path, &current_settings);
            let _ = remove_file_if_exists(&prepared.wrapper_path);
            let _ = remove_file_if_exists(&state_path);
            return Err(InstallError::from_io_string(e));
        }

        Ok(())
    })
}

/// Force-install Orbit, resolving drift and orphaned states.
///
/// Backs up the current settings.json, then cleans old state and installs
/// fresh. The backup is written to `~/.orbit/backups/` and is the caller's
/// safety net for manual restore. The state file captures whatever statusLine
/// existed at the moment of takeover, so uninstall restores to that point.
pub fn silent_force_install(orbit_cli_path: &str) -> Result<(), InstallError> {
    let hook_command = format!("{} hook", orbit_cli_path);

    let settings_path = get_claude_settings_path()
        .map_err(|e| InstallError::Other(format!("Failed to get settings path: {}", e)))?;
    let managed_command = get_statusline_wrapper_path()
        .map_err(|e| InstallError::Other(format!("Failed to get wrapper path: {}", e)))?
        .to_string_lossy()
        .to_string();

    with_file_lock(&settings_path, || {
        let current_settings = read_settings(&settings_path)
            .map_err(|e| InstallError::Other(format!("Failed to read settings: {}", e)))?;
        ensure_settings_object(&current_settings)
            .map_err(|e| InstallError::Other(format!("Invalid settings: {}", e)))?;

        // Backup before any mutation
        backup_settings(&current_settings)?;

        // Save old state for rollback, then clean so prepare_install_force starts fresh
        let state_path = get_statusline_state_path().map_err(InstallError::Other)?;
        let old_state = read_statusline_state(&state_path)
            .map_err(|e| InstallError::Other(format!("Failed to read state: {}", e)))?;
        let _ = remove_file_if_exists(&state_path);

        let mut settings_for_install = current_settings.clone();
        if get_statusline_command(&settings_for_install) == Some(managed_command.as_str()) {
            match old_state.as_ref() {
                Some(state) if !has_self_referential_original_statusline(state) => {
                    restore_original_statusline(&mut settings_for_install, state);
                }
                _ => clear_statusline(&mut settings_for_install),
            }
        }

        let stale_hook_commands =
            collect_hook_commands_for_cleanup(old_state.as_ref(), &settings_for_install);
        remove_orbit_hooks(&mut settings_for_install, &stale_hook_commands)
            .map_err(InstallError::Other)?;

        let prepared = prepare_install_force(settings_for_install, orbit_cli_path, &hook_command)
            .map_err(|e| {
            if let Some(ref st) = old_state {
                let _ = write_statusline_state(&state_path, st);
            }
            InstallError::from_io_string(e)
        })?;

        if let Err(e) = write_wrapper_script(&prepared.wrapper_path, &prepared.wrapper_script) {
            if let Some(ref st) = old_state {
                let _ = write_statusline_state(&state_path, st);
            }
            return Err(InstallError::from_io_string(e));
        }

        if let Err(e) = write_settings(&settings_path, &prepared.settings) {
            let _ = remove_file_if_exists(&prepared.wrapper_path);
            if let Some(ref st) = old_state {
                let _ = write_statusline_state(&state_path, st);
            }
            return Err(InstallError::from_io_string(e));
        }

        if let Err(e) = write_statusline_state(&state_path, &prepared.state) {
            let _ = write_settings(&settings_path, &current_settings);
            let _ = remove_file_if_exists(&prepared.wrapper_path);
            if let Some(ref st) = old_state {
                let _ = write_statusline_state(&state_path, st);
            } else {
                let _ = remove_file_if_exists(&state_path);
            }
            return Err(InstallError::from_io_string(e));
        }

        Ok(())
    })
}

fn backup_settings(settings: &Value) -> Result<(), InstallError> {
    let backup_dir = get_orbit_dir()
        .map_err(InstallError::Other)?
        .join("backups");
    let now = Utc::now();
    let backup_path = backup_dir.join(format!(
        "claude-settings-{}-orbit-{}.json",
        now.format("%Y%m%dT%H%M%SZ"),
        now.timestamp_nanos_opt().unwrap_or(0)
    ));

    let content = serde_json::to_string_pretty(settings)
        .map_err(|e| InstallError::Other(format!("Failed to serialize settings backup: {}", e)))?;
    atomic_write(&backup_path, content.as_bytes()).map_err(InstallError::from_io_string)?;

    Ok(())
}

/// Attempt silent uninstallation
pub fn silent_uninstall(force: bool) -> Result<(), InstallError> {
    let settings_path = get_claude_settings_path()
        .map_err(|e| InstallError::Other(format!("Failed to get settings path: {}", e)))?;

    let settings_exists = settings_path.exists();

    with_file_lock(&settings_path, || {
        let current_settings = if settings_exists {
            let settings = read_settings(&settings_path)
                .map_err(|e| InstallError::Other(format!("Failed to read settings: {}", e)))?;
            ensure_settings_object(&settings)
                .map_err(|e| InstallError::Other(format!("Invalid settings: {}", e)))?;
            settings
        } else {
            Value::Object(Default::default())
        };

        let prepared = prepare_uninstall(current_settings, force).map_err(InstallError::Other)?;

        if matches!(prepared.mode, UninstallMode::PreserveDrift) {
            return Ok(());
        }

        let mut settings_to_write = prepared.settings.clone();
        let stale_hook_commands =
            collect_hook_commands_for_cleanup(prepared.state.as_ref(), &settings_to_write);
        remove_orbit_hooks(&mut settings_to_write, &stale_hook_commands)
            .map_err(InstallError::Other)?;

        if settings_exists {
            write_settings(&settings_path, &settings_to_write).map_err(InstallError::Other)?;
        }

        for path in &prepared.files_to_remove {
            remove_file_if_exists(path).map_err(InstallError::Other)?;
        }

        Ok(())
    })
}

/// Prepare installation data without writing anything
///
/// When `force` is true, drift and orphaned-wrapper states are resolved by
/// discarding the old state and re-capturing the current statusLine as the
/// new original. This keeps the restore chain accurate: uninstall always
/// returns to whatever was configured right before the most recent takeover.
pub fn prepare_install(
    settings: Value,
    orbit_cli_path: &str,
    hook_command: &str,
) -> Result<PreparedInstall, String> {
    prepare_install_inner(settings, orbit_cli_path, hook_command, false)
}

/// Force variant of prepare_install that resolves drift and orphaned states
/// by discarding old state and re-capturing the current statusLine.
fn prepare_install_force(
    settings: Value,
    orbit_cli_path: &str,
    hook_command: &str,
) -> Result<PreparedInstall, String> {
    prepare_install_inner(settings, orbit_cli_path, hook_command, true)
}

fn prepare_install_inner(
    mut settings: Value,
    orbit_cli_path: &str,
    hook_command: &str,
    force: bool,
) -> Result<PreparedInstall, String> {
    ensure_settings_object(&settings)?;

    let wrapper_path = get_statusline_wrapper_path()?;
    let managed_command = wrapper_path.to_string_lossy().to_string();
    let state_path = get_statusline_state_path()?;
    let current_command = get_statusline_command(&settings).map(str::to_string);

    // Check for existing state
    if let Some(state) = read_statusline_state(&state_path)? {
        if current_command.as_deref() == Some(state.managed_command.as_str()) {
            if !wrapper_path.exists() {
                if !force {
                    return Err(
                        "statusLine points to Orbit wrapper, but wrapper file is missing; repair the integration from Orbit and try again"
                            .to_string(),
                    );
                }
                // force: fall through to fresh install below
            } else {
                // Idempotent install
                let mut state = state;
                if has_self_referential_original_statusline(&state) {
                    // Corrupted state would recurse through the wrapper forever.
                    state.original_statusline = None;
                    state.original_was_absent = true;
                }
                let original_command = original_statusline_command(&state).map(str::to_string);

                let mut idempotent_settings = settings;
                let stale_hook_commands =
                    collect_hook_commands_for_cleanup(Some(&state), &idempotent_settings);
                remove_orbit_hooks(&mut idempotent_settings, &stale_hook_commands)?;
                state.hook_command = Some(hook_command.to_string());
                add_orbit_hooks(&mut idempotent_settings, hook_command)?;
                return Ok(PreparedInstall {
                    settings: idempotent_settings,
                    state,
                    wrapper_path,
                    wrapper_script: render_wrapper_script(
                        orbit_cli_path,
                        original_command.as_deref(),
                    ),
                });
            }
        } else if !force {
            return Err(
                "statusLine drift detected (current != managed); refusing to overwrite existing user config"
                    .to_string(),
            );
        }
        // force + drift: discard old state, re-capture current statusLine below
    }

    // Classify current statusLine
    match classify_statusline(&settings, &managed_command) {
        StatusLineConfig::Absent | StatusLineConfig::StandardCommand { .. } => {}
        StatusLineConfig::Unsupported => {
            return Err(
                "statusLine has unsupported configuration (not a command type); refusing to overwrite because the wrapper cannot pass through non-command configs"
                    .to_string(),
            );
        }
        StatusLineConfig::OrbitOrphaned => {
            if !force {
                return Err(
                    "settings.json points to Orbit wrapper but no install state exists; repair the integration from Orbit and try again"
                        .to_string(),
                );
            }
            // force: fall through to fresh install
        }
    }

    // Capture original statusLine BEFORE hooks mutation adds the `hooks` key
    let original_was_absent = settings.get("statusLine").is_none();
    let original_statusline = settings.get("statusLine").cloned();

    add_orbit_hooks(&mut settings, hook_command)?;

    // Replace statusLine with Orbit wrapper
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

/// Prepare uninstallation data without writing anything
pub fn prepare_uninstall(mut settings: Value, force: bool) -> Result<PreparedUninstall, String> {
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
        UninstallMode::PreserveDrift => Ok(PreparedUninstall {
            settings,
            mode,
            state: Some(state),
            files_to_remove: vec![],
        }),
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

/// Evaluate uninstall mode based on current state
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

/// Read settings.json
pub fn read_settings(path: &Path) -> Result<Value, String> {
    if !path.exists() {
        return Ok(Value::Object(Default::default()));
    }

    let content = fs::read_to_string(path)
        .map_err(|e| format!("failed to read {}: {}", path.display(), e))?;
    serde_json::from_str(&content)
        .map_err(|e| format!("failed to parse {} as JSON: {}", path.display(), e))
}

/// Write settings.json atomically
pub fn write_settings(path: &Path, settings: &Value) -> Result<(), String> {
    let pretty = serde_json::to_string_pretty(settings)
        .map_err(|e| format!("failed to serialize settings: {}", e))?;
    atomic_write(path, pretty.as_bytes())
}

/// Atomic file write using temp file + rename
fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create directory {}: {}", parent.display(), e))?;
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
        .map_err(|e| format!("failed to open temp file {}: {}", tmp_path.display(), e))?;

    tmp_file
        .write_all(bytes)
        .map_err(|e| format!("failed to write temp file {}: {}", tmp_path.display(), e))?;
    tmp_file
        .sync_all()
        .map_err(|e| format!("failed to fsync temp file {}: {}", tmp_path.display(), e))?;

    drop(tmp_file);

    fs::rename(&tmp_path, path).map_err(|e| {
        let _ = fs::remove_file(&tmp_path);
        format!(
            "failed to atomically rename {} to {}: {}",
            tmp_path.display(),
            path.display(),
            e
        )
    })?;

    Ok(())
}

/// Execute a function with a file lock.
///
/// NOTE: Uses `libc::flock` which provides process-level (not thread-level)
/// advisory locking. Concurrent calls from the same process won't block each
/// other. This is fine since the GUI serializes install/uninstall flows and the
/// CLI is a separate process.
pub fn with_file_lock<T>(
    path: &Path,
    f: impl FnOnce() -> Result<T, InstallError>,
) -> Result<T, InstallError> {
    let lock_path = path.with_extension("json.lock");
    if let Some(parent) = lock_path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            InstallError::Other(format!(
                "failed to create lock directory {}: {}",
                parent.display(),
                e
            ))
        })?;
    }

    let lock_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&lock_path)
        .map_err(|e| {
            InstallError::Other(format!(
                "failed to open lock file {}: {}",
                lock_path.display(),
                e
            ))
        })?;

    let rc = unsafe { libc::flock(lock_file.as_raw_fd(), libc::LOCK_EX) };
    if rc != 0 {
        return Err(InstallError::Other(format!(
            "failed to acquire lock for {}",
            path.display()
        )));
    }

    let result = f();
    let _ = unsafe { libc::flock(lock_file.as_raw_fd(), libc::LOCK_UN) };
    result
}

/// Ensure settings is a JSON object
pub fn ensure_settings_object(settings: &Value) -> Result<(), String> {
    if settings.is_object() {
        Ok(())
    } else {
        Err("settings.json top-level value must be a JSON object".to_string())
    }
}

/// Add Orbit hooks to settings
pub fn add_orbit_hooks(settings: &mut Value, hook_command: &str) -> Result<(), String> {
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
            return Err(format!("hooks.{} must be an array when present", event));
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

/// Remove Orbit hooks from settings
pub fn remove_orbit_hooks(settings: &mut Value, commands: &[String]) -> Result<(), String> {
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
        // Retain non-array event values (e.g. malformed string/object) untouched —
        // they aren't ours to fix and add_orbit_hooks will reject them on next install.
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

/// Check if a hook entry contains a specific command
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

/// Classify the current statusLine configuration
fn classify_statusline(settings: &Value, managed_command: &str) -> StatusLineConfig {
    let Some(statusline) = settings.get("statusLine") else {
        return StatusLineConfig::Absent;
    };

    if !statusline.is_object() {
        return StatusLineConfig::Unsupported;
    }

    if statusline.get("type").and_then(|v| v.as_str()) != Some("command") {
        return StatusLineConfig::Unsupported;
    }

    let Some(command) = statusline.get("command").and_then(|v| v.as_str()) else {
        return StatusLineConfig::Unsupported;
    };

    if command == managed_command {
        return StatusLineConfig::OrbitOrphaned;
    }

    if command.trim().is_empty() {
        return StatusLineConfig::Unsupported;
    }

    StatusLineConfig::StandardCommand {
        command: command.to_string(),
    }
}

/// Read statusline state file
fn read_statusline_state(path: &Path) -> Result<Option<StatuslineState>, String> {
    if !path.exists() {
        return Ok(None);
    }

    let content = fs::read_to_string(path)
        .map_err(|e| format!("failed to read statusline state {}: {}", path.display(), e))?;
    let state = serde_json::from_str::<StatuslineState>(&content)
        .map_err(|e| format!("failed to parse statusline state {}: {}", path.display(), e))?;
    Ok(Some(state))
}

/// Write statusline state file
pub fn write_statusline_state(path: &Path, state: &StatuslineState) -> Result<(), String> {
    let content = serde_json::to_string_pretty(state)
        .map_err(|e| format!("failed to serialize statusline state: {}", e))?;
    atomic_write(path, content.as_bytes())
}

/// Write wrapper script with executable permissions
pub fn write_wrapper_script(path: &Path, script: &str) -> Result<(), String> {
    atomic_write(path, script.as_bytes())?;
    let mut perms = fs::metadata(path)
        .map_err(|e| format!("failed to read wrapper metadata {}: {}", path.display(), e))?
        .permissions();
    perms.set_mode(0o755);
    fs::set_permissions(path, perms).map_err(|e| {
        format!(
            "failed to set wrapper executable bit {}: {}",
            path.display(),
            e
        )
    })
}

/// Remove file if it exists
pub fn remove_file_if_exists(path: &Path) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("failed to remove {}: {}", path.display(), e)),
    }
}

/// Get the current statusLine command from settings
fn get_statusline_command(settings: &Value) -> Option<&str> {
    settings
        .get("statusLine")
        .and_then(|v| v.as_object())
        .and_then(|v| v.get("command"))
        .and_then(|v| v.as_str())
}

/// Collect hook commands for cleanup
pub fn collect_hook_commands_for_cleanup(
    state: Option<&StatuslineState>,
    settings: &Value,
) -> Vec<String> {
    let mut commands = Vec::new();
    if let Some(command) = state.and_then(|s| s.hook_command.as_deref()) {
        push_unique_command(&mut commands, command.to_string());
        for alias in orbit_hook_aliases(command) {
            push_unique_command(&mut commands, alias);
        }
    }
    let current_hook = helper_hook_command(&resolve_orbit_helper_path());
    push_unique_command(&mut commands, current_hook.clone());
    for alias in orbit_hook_aliases(&current_hook) {
        push_unique_command(&mut commands, alias);
    }
    for command in orbit_hook_commands_in_settings(settings) {
        push_unique_command(&mut commands, command);
    }
    commands
}

fn resolve_home_dir() -> Result<PathBuf, String> {
    dirs_next::home_dir().ok_or_else(|| "home directory not available".to_string())
}

fn get_orbit_dir() -> Result<PathBuf, String> {
    Ok(resolve_home_dir()?.join(".orbit"))
}

/// Get path to statusline state file
pub fn get_statusline_state_path() -> Result<PathBuf, String> {
    Ok(get_orbit_dir()?.join(STATUSLINE_STATE_FILE))
}

fn get_statusline_wrapper_path() -> Result<PathBuf, String> {
    Ok(get_orbit_dir()?.join(STATUSLINE_WRAPPER_FILE))
}

/// Resolve the current executable path
pub fn resolve_current_exe_path() -> Result<String, String> {
    let exe = std::env::current_exe()
        .map_err(|e| format!("failed to resolve current executable: {}", e))?;
    let abs = if exe.is_absolute() {
        exe
    } else {
        let cwd =
            std::env::current_dir().map_err(|e| format!("failed to resolve current dir: {}", e))?;
        cwd.join(exe)
    };
    Ok(abs.to_string_lossy().to_string())
}

pub fn resolve_orbit_helper_path() -> String {
    std::env::current_exe()
        .map(|exe| orbit_helper_sibling_path(exe).to_string_lossy().to_string())
        .unwrap_or_else(|_| FALLBACK_ORBIT_HELPER_PATH.to_string())
}

fn orbit_helper_sibling_path(mut current_exe: PathBuf) -> PathBuf {
    current_exe.set_file_name(HELPER_BINARY_NAME);
    current_exe
}

/// Shell-quote a string for safe inclusion in scripts
fn shell_single_quote(s: &str) -> String {
    if s.is_empty() {
        "''".to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\"'\"'"))
    }
}

/// Render the wrapper script with given parameters
fn render_wrapper_script(orbit_cli_path: &str, original_command: Option<&str>) -> String {
    STATUSLINE_WRAPPER_TEMPLATE
        .replace("__ORBIT_HELPER_PATH__", &shell_single_quote(orbit_cli_path))
        .replace(
            "__ORBIT_ORIGINAL_CMD__",
            &shell_single_quote(original_command.unwrap_or("")),
        )
}

fn original_statusline_command(state: &StatuslineState) -> Option<&str> {
    let original = state.original_statusline.as_ref()?;
    let statusline = original.as_object()?;
    if statusline.get("type").and_then(|v| v.as_str()) != Some("command") {
        return None;
    }
    statusline.get("command").and_then(|v| v.as_str())
}

fn has_self_referential_original_statusline(state: &StatuslineState) -> bool {
    original_statusline_command(state) == Some(state.managed_command.as_str())
}

fn clear_statusline(settings: &mut Value) {
    if let Some(obj) = settings.as_object_mut() {
        obj.remove("statusLine");
    }
}

fn restore_original_statusline(settings: &mut Value, state: &StatuslineState) {
    if let Some(obj) = settings.as_object_mut() {
        if state.original_was_absent {
            obj.remove("statusLine");
        } else if let Some(original_statusline) = state.original_statusline.clone() {
            obj.insert("statusLine".to_string(), original_statusline);
        } else {
            obj.insert("statusLine".to_string(), Value::Null);
        }
    }
}

fn helper_hook_command(helper_path: &str) -> String {
    format!("{} hook", helper_path)
}

fn orbit_cli_sibling_path(mut current_exe: PathBuf) -> PathBuf {
    current_exe.set_file_name(CLI_BINARY_NAME);
    current_exe
}

fn orbit_hook_aliases(command: &str) -> Vec<String> {
    let Some(binary_path) = command.strip_suffix(" hook") else {
        return Vec::new();
    };

    let binary_path = PathBuf::from(binary_path);
    let Some(file_name) = binary_path.file_name() else {
        return Vec::new();
    };

    if file_name == OsStr::new(HELPER_BINARY_NAME) {
        return vec![helper_hook_command(
            &orbit_cli_sibling_path(binary_path).to_string_lossy(),
        )];
    }

    if file_name == OsStr::new(CLI_BINARY_NAME) {
        return vec![helper_hook_command(
            &orbit_helper_sibling_path(binary_path).to_string_lossy(),
        )];
    }

    Vec::new()
}

fn orbit_hook_commands_in_settings(settings: &Value) -> Vec<String> {
    let mut commands = Vec::new();
    let Some(hooks) = settings.get("hooks").and_then(|v| v.as_object()) else {
        return commands;
    };

    for entries in hooks.values().filter_map(Value::as_array) {
        for entry in entries {
            if let Some(inner_hooks) = entry.get("hooks").and_then(Value::as_array) {
                for hook in inner_hooks {
                    if hook.get("type").and_then(Value::as_str) != Some("command") {
                        continue;
                    }
                    let Some(command) = hook.get("command").and_then(Value::as_str) else {
                        continue;
                    };
                    if !orbit_hook_aliases(command).is_empty() {
                        push_unique_command(&mut commands, command.to_string());
                    }
                }
            }
        }
    }

    commands
}

fn push_unique_command(commands: &mut Vec<String>, command: String) {
    if !commands.iter().any(|existing| existing == &command) {
        commands.push(command);
    }
}

#[cfg(test)]
fn settings_has_exact_hook_command(settings: &Value, command: &str) -> bool {
    settings
        .get("hooks")
        .and_then(|v| v.as_object())
        .into_iter()
        .flat_map(|events| events.values())
        .filter_map(|entries| entries.as_array())
        .flat_map(|entries| entries.iter())
        .any(|entry| entry_has_hook_command(entry, command))
}

fn settings_have_required_hook_commands(settings: &Value, command: &str) -> bool {
    let Some(hooks) = settings.get("hooks").and_then(|v| v.as_object()) else {
        return false;
    };

    HOOK_EVENTS.iter().all(|event| {
        hooks
            .get(*event)
            .and_then(|entries| entries.as_array())
            .is_some_and(|entries| {
                entries
                    .iter()
                    .any(|entry| entry_has_hook_command(entry, command))
            })
    })
}

/// Generate a unique installation ID
fn generate_install_id() -> String {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("orbit-{}-{}", std::process::id(), ts)
}

/// Get the Claude Code settings.json path
pub fn get_claude_settings_path() -> Result<PathBuf, String> {
    Ok(resolve_home_dir()?.join(".claude").join("settings.json"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::PathBuf;
    use std::sync::MutexGuard;

    struct TestHome {
        _guard: MutexGuard<'static, ()>,
        path: PathBuf,
        old_home: Option<String>,
    }

    impl TestHome {
        fn new() -> Self {
            let guard = TEST_HOME_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let path = std::env::temp_dir()
                .join(format!("orbit-installer-home-{}", generate_install_id()));
            fs::create_dir_all(&path).unwrap();
            let old_home = std::env::var("HOME").ok();
            // SAFETY: ENV_LOCK is held, so no other test thread accesses env vars.
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
            // SAFETY: ENV_LOCK is still held (via _guard) during drop.
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

        let orbit_helper = "/Applications/Orbit.app/Contents/MacOS/orbit-helper".to_string();
        let hook_command = format!("{} hook", orbit_helper);

        with_file_lock(&settings_path, || {
            let current_settings = read_settings(&settings_path)?;
            ensure_settings_object(&current_settings)?;
            let prepared = prepare_install(current_settings.clone(), &orbit_helper, &hook_command)?;

            write_wrapper_script(&prepared.wrapper_path, &prepared.wrapper_script)?;
            write_settings(&settings_path, &prepared.settings)?;
            write_statusline_state(&home.state_path(), &prepared.state)?;
            Ok(())
        })
        .map_err(|e: InstallError| e.to_string())
    }

    fn run_force_install_for_test(home: &TestHome, initial_settings: Value) -> Result<(), String> {
        let settings_path = home.settings_path();
        if let Some(parent) = settings_path.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        write_settings(&settings_path, &initial_settings)?;

        let orbit_helper = "/Applications/Orbit.app/Contents/MacOS/orbit-helper".to_string();
        let hook_command = format!("{} hook", orbit_helper);

        with_file_lock(&settings_path, || {
            let current_settings = read_settings(&settings_path)?;
            ensure_settings_object(&current_settings)?;

            let state_path = home.state_path();
            let _ = remove_file_if_exists(&state_path);

            let prepared =
                prepare_install_force(current_settings.clone(), &orbit_helper, &hook_command)?;

            write_wrapper_script(&prepared.wrapper_path, &prepared.wrapper_script)?;
            write_settings(&settings_path, &prepared.settings)?;
            write_statusline_state(&state_path, &prepared.state)?;
            Ok(())
        })
        .map_err(|e: InstallError| e.to_string())
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
            let stale_hook_commands =
                collect_hook_commands_for_cleanup(prepared.state.as_ref(), &settings_to_write);
            remove_orbit_hooks(&mut settings_to_write, &stale_hook_commands)?;
            write_settings(&settings_path, &settings_to_write)?;
            for path in &prepared.files_to_remove {
                remove_file_if_exists(path)?;
            }
            Ok(())
        })
        .map_err(|e: InstallError| e.to_string())
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

        add_orbit_hooks(
            &mut settings,
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook",
        )
        .unwrap();
        add_orbit_hooks(
            &mut settings,
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook",
        )
        .unwrap();

        let post_tool_use = settings
            .get("hooks")
            .and_then(|v| v.get("PostToolUse"))
            .and_then(|v| v.as_array())
            .unwrap();

        let exact_count = post_tool_use
            .iter()
            .filter(|entry| {
                entry_has_hook_command(
                    entry,
                    "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook",
                )
            })
            .count();
        assert_eq!(exact_count, 1);
        assert!(
            post_tool_use
                .iter()
                .any(|entry| entry_has_hook_command(entry, "/usr/local/bin/orbital-tool hook"))
        );
    }

    #[test]
    fn settings_have_required_hook_commands_detects_missing_event() {
        let mut settings = json!({});
        add_orbit_hooks(
            &mut settings,
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook",
        )
        .unwrap();

        settings
            .get_mut("hooks")
            .and_then(|v| v.as_object_mut())
            .unwrap()
            .remove("Elicitation");

        assert!(!settings_have_required_hook_commands(
            &settings,
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook"
        ));
        assert!(settings_has_exact_hook_command(
            &settings,
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook"
        ));
    }

    #[test]
    fn remove_orbit_hooks_keeps_non_orbit_strings() {
        let mut settings = json!({
            "hooks": {
                "PostToolUse": [
                    {"hooks": [{"type": "command", "command": "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook"}]},
                    {"hooks": [{"type": "command", "command": "/usr/local/bin/orbital-tool hook"}]}
                ]
            }
        });

        remove_orbit_hooks(
            &mut settings,
            &["/Applications/Orbit.app/Contents/MacOS/orbit-helper hook".to_string()],
        )
        .unwrap();

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
            hook_command: Some(
                "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook".to_string(),
            ),
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
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            Some("/usr/local/bin/my-statusline --flag"),
        );
        assert!(script.contains("echo \"$INPUT\" | /bin/bash -lc \"$ORIGINAL_CMD\""));
        assert!(script.contains("if [ \"$ORIGINAL_CMD\" = \"$0\" ]"));
        assert!(script.contains("cat 2>/dev/null || true"));
        assert!(!script.contains("set -eo pipefail"));
    }

    #[test]
    fn idempotent_install_updates_hook_command_and_preserves_original_passthrough() {
        let home = TestHome::new();
        let original_settings = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/original-status --flag"
            }
        });

        run_install_for_test(&home, original_settings).unwrap();
        let current_settings = read_settings(&home.settings_path()).unwrap();
        let helper_path = "/Applications/Orbit.app/Contents/MacOS/orbit-helper";
        let prepared = prepare_install(
            current_settings,
            helper_path,
            &format!("{helper_path} hook"),
        )
        .unwrap();

        assert_eq!(
            prepared.state.hook_command,
            Some("/Applications/Orbit.app/Contents/MacOS/orbit-helper hook".to_string())
        );
        assert!(
            prepared
                .wrapper_script
                .contains("'/usr/local/bin/original-status --flag'")
        );
        assert!(
            !prepared
                .wrapper_script
                .contains(&home.wrapper_path().to_string_lossy().to_string())
        );
    }

    #[test]
    fn idempotent_install_sanitizes_self_referential_original_statusline() {
        let home = TestHome::new();
        run_install_for_test(&home, json!({})).unwrap();

        let wrapper_command = home.wrapper_path().to_string_lossy().to_string();
        write_statusline_state(
            &home.state_path(),
            &StatuslineState {
                original_statusline: Some(json!({
                    "type": "command",
                    "command": wrapper_command,
                })),
                original_was_absent: false,
                managed_command: home.wrapper_path().to_string_lossy().to_string(),
                hook_command: Some(
                    "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook".to_string(),
                ),
                install_id: "test".to_string(),
                installed_at: "2026-01-01T00:00:00Z".to_string(),
            },
        )
        .unwrap();

        let current_settings = read_settings(&home.settings_path()).unwrap();
        let prepared = prepare_install(
            current_settings,
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook",
        )
        .unwrap();

        assert!(prepared.state.original_statusline.is_none());
        assert!(prepared.state.original_was_absent);
        assert!(
            !prepared
                .wrapper_script
                .contains(&home.wrapper_path().to_string_lossy().to_string())
        );
    }

    #[test]
    fn idempotent_install_replaces_previous_helper_hook_path() {
        let home = TestHome::new();
        run_install_for_test(&home, json!({})).unwrap();

        let mut current_settings = read_settings(&home.settings_path()).unwrap();
        remove_orbit_hooks(
            &mut current_settings,
            &["/Applications/Orbit.app/Contents/MacOS/orbit-helper hook".to_string()],
        )
        .unwrap();
        add_orbit_hooks(
            &mut current_settings,
            "/Volumes/Orbit/Orbit.app/Contents/MacOS/orbit-helper hook",
        )
        .unwrap();
        write_settings(&home.settings_path(), &current_settings).unwrap();

        let mut state = read_statusline_state(&home.state_path()).unwrap().unwrap();
        state.hook_command =
            Some("/Volumes/Orbit/Orbit.app/Contents/MacOS/orbit-helper hook".to_string());
        write_statusline_state(&home.state_path(), &state).unwrap();

        let prepared = prepare_install(
            current_settings,
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook",
        )
        .unwrap();

        assert!(!settings_has_exact_hook_command(
            &prepared.settings,
            "/Volumes/Orbit/Orbit.app/Contents/MacOS/orbit-helper hook",
        ));
        assert!(settings_has_exact_hook_command(
            &prepared.settings,
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook",
        ));
    }

    #[test]
    fn prepare_install_repairs_state_files_missing_hook_command() {
        let home = TestHome::new();
        run_install_for_test(&home, json!({})).unwrap();

        let legacy_state = format!(
            r#"{{
  "original_statusline": null,
  "original_was_absent": true,
  "managed_command": "{}",
  "install_id": "legacy",
  "installed_at": "2026-01-01T00:00:00Z"
}}"#,
            home.wrapper_path().to_string_lossy()
        );
        atomic_write(&home.state_path(), legacy_state.as_bytes()).unwrap();

        let current_settings = read_settings(&home.settings_path()).unwrap();
        let prepared = prepare_install(
            current_settings,
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook",
        )
        .unwrap();

        assert_eq!(
            prepared.state.hook_command,
            Some("/Applications/Orbit.app/Contents/MacOS/orbit-helper hook".to_string())
        );
    }

    #[test]
    fn force_install_cleans_legacy_cli_hooks_without_state_file() {
        let home = TestHome::new();
        let mut settings = json!({});
        add_orbit_hooks(
            &mut settings,
            "/Applications/Orbit.app/Contents/MacOS/orbit-cli hook",
        )
        .unwrap();
        write_settings(&home.settings_path(), &settings).unwrap();

        silent_force_install("/Applications/Orbit.app/Contents/MacOS/orbit-helper").unwrap();

        let repaired = read_settings(&home.settings_path()).unwrap();
        assert!(!settings_has_exact_hook_command(
            &repaired,
            "/Applications/Orbit.app/Contents/MacOS/orbit-cli hook",
        ));
        assert!(settings_has_exact_hook_command(
            &repaired,
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook",
        ));
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
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook"
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
        assert!(err.contains("unsupported configuration"));
        assert!(!home.wrapper_path().exists());
        assert!(!home.state_path().exists());
    }

    #[test]
    fn force_install_resolves_drift_on_real_filesystem() {
        let home = TestHome::new();

        // First: normal install
        run_install_for_test(&home, json!({})).unwrap();
        assert!(home.wrapper_path().exists());

        // Simulate drift: user changes statusLine
        let drifted = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/user-tool"
            }
        });
        write_settings(&home.settings_path(), &drifted).unwrap();

        // Normal install should fail (drift)
        let err = run_install_for_test(&home, drifted.clone()).unwrap_err();
        assert!(err.contains("drift"));

        // Force install should succeed
        run_force_install_for_test(&home, drifted).unwrap();
        let after = read_settings(&home.settings_path()).unwrap();
        assert_eq!(
            get_statusline_command(&after).unwrap(),
            home.wrapper_path().to_string_lossy()
        );

        // State should capture the drifted statusLine (not the original absent one)
        let state = read_statusline_state(&home.state_path()).unwrap().unwrap();
        let original = state.original_statusline.unwrap();
        assert_eq!(
            original,
            json!({"type": "command", "command": "/usr/local/bin/user-tool"})
        );
    }

    #[test]
    fn force_install_then_uninstall_restores_to_takeover_point() {
        let home = TestHome::new();

        // Install with an existing statusLine
        let original = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/tool-a"
            }
        });
        run_install_for_test(&home, original).unwrap();

        // Simulate drift to tool-b
        let drifted = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/tool-b"
            }
        });
        write_settings(&home.settings_path(), &drifted).unwrap();

        // Force reinstall: should capture tool-b as the restore point
        run_force_install_for_test(&home, drifted).unwrap();

        // Uninstall should restore to tool-b (not tool-a)
        run_uninstall_for_test(&home, false).unwrap();
        let restored = read_settings(&home.settings_path()).unwrap();
        assert_eq!(
            restored,
            json!({
                "statusLine": {
                    "type": "command",
                    "command": "/usr/local/bin/tool-b"
                }
            })
        );
    }

    #[test]
    fn silent_force_install_preserves_original_statusline_when_repairing_wrapper() {
        let home = TestHome::new();
        let original = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/tool-a"
            }
        });
        run_install_for_test(&home, original).unwrap();

        silent_force_install("/Applications/Orbit.app/Contents/MacOS/orbit-helper").unwrap();

        let state = read_statusline_state(&home.state_path()).unwrap().unwrap();
        assert_eq!(
            state.original_statusline,
            Some(json!({
                "type": "command",
                "command": "/usr/local/bin/tool-a"
            }))
        );
    }

    #[test]
    fn check_install_state_detects_not_installed() {
        let _home = TestHome::new();
        let state =
            check_install_state("/Applications/Orbit.app/Contents/MacOS/orbit-helper").unwrap();
        assert_eq!(state, InstallState::NotInstalled);
    }

    #[test]
    fn check_install_state_treats_standard_command_as_takeover_ready() {
        let home = TestHome::new();
        write_settings(
            &home.settings_path(),
            &json!({
                "statusLine": {
                    "type": "command",
                    "command": "/usr/local/bin/existing-statusline"
                }
            }),
        )
        .unwrap();

        let state =
            check_install_state("/Applications/Orbit.app/Contents/MacOS/orbit-helper").unwrap();
        assert_eq!(state, InstallState::NotInstalled);
    }

    #[test]
    fn check_install_state_detects_orbit_installed() {
        let home = TestHome::new();
        let original_settings = json!({});
        run_install_for_test(&home, original_settings).unwrap();

        let state =
            check_install_state("/Applications/Orbit.app/Contents/MacOS/orbit-helper").unwrap();
        assert_eq!(state, InstallState::OrbitInstalled);
    }

    #[test]
    fn check_install_state_detects_missing_required_hook_as_not_installed() {
        let home = TestHome::new();
        run_install_for_test(&home, json!({})).unwrap();

        let mut settings = read_settings(&home.settings_path()).unwrap();
        settings
            .get_mut("hooks")
            .and_then(|v| v.as_object_mut())
            .unwrap()
            .remove("Elicitation");
        write_settings(&home.settings_path(), &settings).unwrap();

        let state =
            check_install_state("/Applications/Orbit.app/Contents/MacOS/orbit-helper").unwrap();
        assert_eq!(state, InstallState::NotInstalled);
    }

    #[test]
    fn check_install_state_detects_drift() {
        let home = TestHome::new();
        let original_settings = json!({});
        run_install_for_test(&home, original_settings).unwrap();

        // Modify statusline after install
        let drifted = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/other"
            }
        });
        write_settings(&home.settings_path(), &drifted).unwrap();

        let state =
            check_install_state("/Applications/Orbit.app/Contents/MacOS/orbit-helper").unwrap();
        assert_eq!(state, InstallState::DriftDetected);
    }

    #[test]
    fn orbit_helper_sibling_rewrites_binary_name() {
        let rewritten = orbit_helper_sibling_path(PathBuf::from("/tmp/target/debug/orbit"));
        assert_eq!(rewritten, PathBuf::from("/tmp/target/debug/orbit-helper"));
    }
}
