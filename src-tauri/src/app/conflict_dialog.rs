//! Conflict resolution dialog for onboarding.
//!
//! When Orbit detects another tool already owns Claude Code's `statusLine`,
//! this module shows a native macOS choice dialog and optionally takes over
//! after backing up the current Claude settings.

use super::onboarding::{OnboardingManager, OnboardingState};
use crate::installer::{self, InstallError};
use chrono::Utc;
use serde_json::Value;
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::Duration;
use tauri::AppHandle;

const POLL_INTERVAL: Duration = Duration::from_millis(250);
const KEEP_EXISTING_LABEL: &str = "保留现有配置";
const SWITCH_TO_ORBIT_LABEL: &str = "切换到Orbit";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConflictChoice {
    KeepExisting,
    SwitchToOrbit,
}

/// Poll onboarding state and show the conflict dialog once when needed.
pub fn start_monitor(onboarding: OnboardingManager, app_handle: AppHandle) {
    thread::spawn(move || {
        loop {
            match onboarding.state() {
                OnboardingState::ConflictDetected(tool) => {
                    match show_conflict_dialog(&tool) {
                        Ok(ConflictChoice::KeepExisting) => {}
                        Ok(ConflictChoice::SwitchToOrbit) => {
                            onboarding.switch_to_orbit_with_backup_with_emitter(app_handle.clone())
                        }
                        Err(err) => onboarding.set_state_with_emitter(
                            OnboardingState::Error(err.to_string()),
                            app_handle.clone(),
                        ),
                    }
                    break;
                }
                state if state.is_complete() => break,
                _ => thread::sleep(POLL_INTERVAL),
            }
        }
    });
}

/// Back up the current Claude settings, then reinstall Orbit on top.
pub fn backup_and_switch_to_orbit(orbit_cli_path: &str) -> Result<PathBuf, InstallError> {
    let settings_path = installer::get_claude_settings_path().map_err(InstallError::Other)?;
    let backup_path = installer::with_file_lock(&settings_path, || {
        let settings = installer::read_settings(&settings_path)
            .map_err(|e| InstallError::Other(format!("Failed to read Claude settings: {}", e)))?;
        installer::ensure_settings_object(&settings).map_err(InstallError::Other)?;
        backup_current_settings(&settings)
    })?;

    installer::silent_install(orbit_cli_path)?;
    Ok(backup_path)
}

fn backup_current_settings(settings: &Value) -> Result<PathBuf, InstallError> {
    let backup_dir = installer::get_orbit_dir()
        .map_err(InstallError::Other)?
        .join("backups");
    let backup_path = backup_dir.join(format!(
        "claude-settings-{}-{}.json",
        Utc::now().format("%Y%m%dT%H%M%SZ"),
        installer::generate_install_id()
    ));

    let content = serde_json::to_string_pretty(settings).map_err(|e| {
        InstallError::Other(format!("Failed to serialize Claude settings backup: {}", e))
    })?;
    installer::atomic_write(&backup_path, content.as_bytes()).map_err(classify_write_error)?;

    Ok(backup_path)
}

fn show_conflict_dialog(tool: &str) -> Result<ConflictChoice, InstallError> {
    let message = format!(
        "Claude Code 当前的 statusLine 正被以下工具占用：{}。\n\n保留现有配置会维持当前设置；切换到Orbit会先备份当前配置，再重装 Orbit。",
        tool
    );
    let script = format!(
        r#"set dialogResult to display dialog "{}" buttons {{"{}", "{}"}} default button "{}" with title "Orbit 配置冲突" with icon caution
button returned of dialogResult"#,
        escape_applescript_string(&message),
        KEEP_EXISTING_LABEL,
        SWITCH_TO_ORBIT_LABEL,
        SWITCH_TO_ORBIT_LABEL,
    );

    let output = Command::new("osascript")
        .arg("-e")
        .arg(script)
        .output()
        .map_err(|e| InstallError::Other(format!("Failed to launch conflict dialog: {}", e)))?;

    if output.status.success() {
        let choice = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return match choice.as_str() {
            SWITCH_TO_ORBIT_LABEL => Ok(ConflictChoice::SwitchToOrbit),
            _ => Ok(ConflictChoice::KeepExisting),
        };
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.contains("-128") {
        Ok(ConflictChoice::KeepExisting)
    } else {
        Err(InstallError::Other(format!(
            "Failed to show conflict dialog: {}",
            stderr.trim()
        )))
    }
}

fn escape_applescript_string(input: &str) -> String {
    input.replace('\\', "\\\\").replace('"', "\\\"")
}

fn classify_write_error(message: String) -> InstallError {
    if message.contains("Permission") || message.contains("permission") {
        InstallError::PermissionDenied
    } else {
        InstallError::Other(message)
    }
}
