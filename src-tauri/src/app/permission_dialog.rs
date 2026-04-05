//! Permission overlay dialog for onboarding.
//!
//! Shows a focused overlay window when Orbit cannot access Claude Code
//! configuration during automatic onboarding.

use super::onboarding::{OnboardingManager, OnboardingState};
use std::path::PathBuf;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

const POLL_INTERVAL: Duration = Duration::from_millis(300);
const WINDOW_LABEL: &str = "permission-overlay";
const FALLBACK_ORBIT_CLI_PATH: &str = "/Applications/Orbit.app/Contents/MacOS/orbit-cli";

pub fn start_monitor(app_handle: AppHandle, onboarding: OnboardingManager) {
    thread::spawn(move || {
        let mut dialog_visible = false;

        loop {
            match onboarding.state() {
                OnboardingState::PermissionDenied => {
                    if !dialog_visible {
                        if let Err(err) = show_dialog(&app_handle) {
                            eprintln!("[Orbit] Failed to show permission dialog: {}", err);
                        } else {
                            dialog_visible = true;
                        }
                    }
                }
                state if state.is_complete() => {
                    if dialog_visible {
                        let _ = hide_dialog(&app_handle);
                    }
                    break;
                }
                _ => {
                    if dialog_visible {
                        let _ = hide_dialog(&app_handle);
                        dialog_visible = false;
                    }
                }
            }

            thread::sleep(POLL_INTERVAL);
        }
    });
}

pub fn resolve_orbit_cli_path() -> String {
    std::env::current_exe()
        .map(|exe| orbit_cli_sibling_path(exe).to_string_lossy().to_string())
        .unwrap_or_else(|_| FALLBACK_ORBIT_CLI_PATH.to_string())
}

pub fn install_command() -> String {
    build_install_command(&resolve_orbit_cli_path())
}

fn orbit_cli_sibling_path(mut current_exe: PathBuf) -> PathBuf {
    current_exe.set_file_name("orbit-cli");
    current_exe
}

fn build_install_command(orbit_cli_path: &str) -> String {
    format!("\"{}\" install", orbit_cli_path.replace('"', "\\\""))
}

fn show_dialog(app_handle: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app_handle.get_webview_window(WINDOW_LABEL) {
        window.show()?;
        let _ = window.set_focus();
        return Ok(());
    }

    let window = WebviewWindowBuilder::new(
        app_handle,
        WINDOW_LABEL,
        WebviewUrl::App("permission-dialog.html".into()),
    )
    .title("Orbit Permission")
    .center()
    .inner_size(540.0, 340.0)
    .resizable(false)
    .minimizable(false)
    .maximizable(false)
    .closable(false)
    .decorations(false)
    .transparent(true)
    .always_on_top(true)
    .visible_on_all_workspaces(true)
    .skip_taskbar(true)
    .focused(true)
    .visible(true)
    .build()?;

    let _ = window.set_focus();
    Ok(())
}

fn hide_dialog(app_handle: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app_handle.get_webview_window(WINDOW_LABEL) {
        window.hide()?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_command_quotes_path() {
        assert_eq!(
            build_install_command("/Applications/Orbit App/Contents/MacOS/orbit-cli"),
            "\"/Applications/Orbit App/Contents/MacOS/orbit-cli\" install"
        );
    }

    #[test]
    fn orbit_cli_sibling_rewrites_binary_name() {
        let rewritten = orbit_cli_sibling_path(PathBuf::from("/tmp/target/debug/orbit"));
        assert_eq!(rewritten, PathBuf::from("/tmp/target/debug/orbit-cli"));
    }
}
