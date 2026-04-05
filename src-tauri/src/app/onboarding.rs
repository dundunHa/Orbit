//! GUI Onboarding Module
//!
//! Handles automatic installation of Orbit hooks on GUI startup.
//! Designed for "silent & seamless" UX - background auto-install with tray indicators.

use super::conflict_dialog;
use crate::installer::{self, InstallError, InstallState, check_install_state, silent_install};
use serde::Serialize;
use std::sync::{Arc, Mutex};
#[cfg(test)]
use std::time::Duration;
use tauri::{AppHandle, Emitter};

pub const ONBOARDING_STATE_CHANGED_EVENT: &str = "onboarding-state-changed";

#[derive(Debug, Clone, Serialize)]
pub struct OnboardingStatePayload {
    #[serde(rename = "type")]
    pub type_name: String,
    pub status_text: String,
    pub tray_status: String,
    pub tray_emoji: String,
    pub needs_attention: bool,
    pub is_complete: bool,
    pub can_retry: bool,
}

/// Onboarding state for GUI flow
///
/// State machine:
/// ```text
/// Welcome ──▶ Checking ──▶ Installing ──▶ Connected
///    │           │            │
///    │           ▼            ▼
///    │      Conflict      PermissionDenied
///    │      Detected         │
///    └───────────────────────┘
///              │
///              ▼
///         DriftDetected
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OnboardingState {
    /// Initial state - waiting to start check
    Welcome,
    /// Checking current installation state
    Checking,
    /// Installing in progress
    Installing,
    /// Successfully connected
    Connected,
    /// Another tool is using statusline
    ConflictDetected(String),
    /// Permission denied (Sandbox)
    PermissionDenied,
    /// Configuration drift detected
    DriftDetected,
    /// Error during installation
    Error(String),
}

impl OnboardingState {
    fn type_name(&self) -> &'static str {
        match self {
            OnboardingState::Welcome => "Welcome",
            OnboardingState::Checking => "Checking",
            OnboardingState::Installing => "Installing",
            OnboardingState::Connected => "Connected",
            OnboardingState::ConflictDetected(_) => "ConflictDetected",
            OnboardingState::PermissionDenied => "PermissionDenied",
            OnboardingState::DriftDetected => "DriftDetected",
            OnboardingState::Error(_) => "Error",
        }
    }

    pub fn payload(&self) -> OnboardingStatePayload {
        let tray_status = self.tray_status();
        OnboardingStatePayload {
            type_name: self.type_name().to_string(),
            status_text: self.status_text(),
            tray_status: tray_status.as_str().to_string(),
            tray_emoji: tray_status.emoji().to_string(),
            needs_attention: self.needs_attention(),
            is_complete: self.is_complete(),
            can_retry: self.can_retry(),
        }
    }

    /// Get the tray icon status for this state
    pub fn tray_status(&self) -> TrayStatus {
        match self {
            OnboardingState::Welcome => TrayStatus::Connecting,
            OnboardingState::Checking => TrayStatus::Connecting,
            OnboardingState::Installing => TrayStatus::Connecting,
            OnboardingState::Connected => TrayStatus::Connected,
            OnboardingState::ConflictDetected(_) => TrayStatus::Conflict,
            OnboardingState::PermissionDenied => TrayStatus::NeedsPermission,
            OnboardingState::DriftDetected => TrayStatus::Conflict,
            OnboardingState::Error(_) => TrayStatus::Error,
        }
    }

    /// Get user-facing status text
    pub fn status_text(&self) -> String {
        match self {
            OnboardingState::Welcome => "Welcome to Orbit".to_string(),
            OnboardingState::Checking => "Checking Claude Code configuration...".to_string(),
            OnboardingState::Installing => "Installing Orbit hooks...".to_string(),
            OnboardingState::Connected => "Connected to Claude Code".to_string(),
            OnboardingState::ConflictDetected(tool) => {
                format!("Configuration conflict detected: {}", tool)
            }
            OnboardingState::PermissionDenied => "Permission required".to_string(),
            OnboardingState::DriftDetected => "Configuration drift detected".to_string(),
            OnboardingState::Error(msg) => format!("Error: {}", msg),
        }
    }

    /// Whether this state represents an error that needs user attention
    pub fn needs_attention(&self) -> bool {
        matches!(
            self,
            OnboardingState::ConflictDetected(_)
                | OnboardingState::PermissionDenied
                | OnboardingState::DriftDetected
                | OnboardingState::Error(_)
        )
    }

    pub fn can_retry(&self) -> bool {
        self.needs_attention()
    }

    /// Whether installation is complete (success or handled error)
    pub fn is_complete(&self) -> bool {
        matches!(
            self,
            OnboardingState::Connected
                | OnboardingState::ConflictDetected(_)
                | OnboardingState::PermissionDenied
                | OnboardingState::DriftDetected
                | OnboardingState::Error(_)
        )
    }
}

/// Tray icon status indicators
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayStatus {
    /// 🟡 Connecting/Installing
    Connecting,
    /// 🟢 Connected
    Connected,
    /// 🔴 Permission needed
    NeedsPermission,
    /// ⚠️ Conflict or error
    Conflict,
    /// 🔴 Generic error
    Error,
}

impl TrayStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            TrayStatus::Connecting => "connecting",
            TrayStatus::Connected => "connected",
            TrayStatus::NeedsPermission => "needs_permission",
            TrayStatus::Conflict => "conflict",
            TrayStatus::Error => "error",
        }
    }

    /// Get the emoji for this status
    pub fn emoji(&self) -> &'static str {
        match self {
            TrayStatus::Connecting => "🟡",
            TrayStatus::Connected => "🟢",
            TrayStatus::NeedsPermission => "🔴",
            TrayStatus::Conflict => "⚠️",
            TrayStatus::Error => "🔴",
        }
    }

    /// Get tooltip text for tray icon
    pub fn tooltip(&self) -> &'static str {
        match self {
            TrayStatus::Connecting => "Orbit - Connecting...",
            TrayStatus::Connected => "Orbit - Connected to Claude Code",
            TrayStatus::NeedsPermission => "Orbit - Permission needed",
            TrayStatus::Conflict => "Orbit - Configuration conflict",
            TrayStatus::Error => "Orbit - Error",
        }
    }
}

fn emit_state_change(app_handle: Option<&AppHandle>, next: &OnboardingState) {
    if let Some(app_handle) = app_handle {
        let _ = app_handle.emit(ONBOARDING_STATE_CHANGED_EVENT, next.payload());
    }
}

fn transition_state(
    state: &Arc<Mutex<OnboardingState>>,
    next: OnboardingState,
    app_handle: Option<&AppHandle>,
) {
    {
        let mut current = state.lock().unwrap();
        *current = next.clone();
    }
    emit_state_change(app_handle, &next);
}

/// Onboarding manager - handles state machine and auto-install
#[derive(Clone)]
pub struct OnboardingManager {
    state: Arc<Mutex<OnboardingState>>,
    orbit_cli_path: String,
}

impl OnboardingManager {
    /// Create a new onboarding manager
    pub fn new(orbit_cli_path: String) -> Self {
        Self {
            state: Arc::new(Mutex::new(OnboardingState::Welcome)),
            orbit_cli_path,
        }
    }

    /// Get current state
    pub fn state(&self) -> OnboardingState {
        self.state.lock().unwrap().clone()
    }

    pub fn state_payload(&self) -> OnboardingStatePayload {
        self.state().payload()
    }

    /// Start background auto-install flow
    ///
    /// This should be called on app startup. It spawns a background thread
    /// and returns immediately (<50ms).
    pub fn start_background_check(&self) {
        self.start_background_check_inner(None);
    }

    pub fn start_background_check_with_emitter(&self, app_handle: AppHandle) {
        self.start_background_check_inner(Some(app_handle));
    }

    fn start_background_check_inner(&self, app_handle: Option<AppHandle>) {
        let state = Arc::clone(&self.state);
        let orbit_cli_path = self.orbit_cli_path.clone();

        std::thread::spawn(move || {
            transition_state(&state, OnboardingState::Checking, app_handle.as_ref());

            match check_install_state(&orbit_cli_path) {
                Ok(InstallState::OrbitInstalled) => {
                    transition_state(&state, OnboardingState::Connected, app_handle.as_ref());
                }
                Ok(InstallState::NotInstalled) => {
                    transition_state(&state, OnboardingState::Installing, app_handle.as_ref());

                    match silent_install(&orbit_cli_path) {
                        Ok(()) => {
                            transition_state(
                                &state,
                                OnboardingState::Connected,
                                app_handle.as_ref(),
                            );
                        }
                        Err(InstallError::PermissionDenied) => {
                            transition_state(
                                &state,
                                OnboardingState::PermissionDenied,
                                app_handle.as_ref(),
                            );
                        }
                        Err(InstallError::Conflict(tool)) => {
                            transition_state(
                                &state,
                                OnboardingState::ConflictDetected(tool),
                                app_handle.as_ref(),
                            );
                        }
                        Err(e) => {
                            transition_state(
                                &state,
                                OnboardingState::Error(e.to_string()),
                                app_handle.as_ref(),
                            );
                        }
                    }
                }
                Ok(InstallState::DriftDetected) => {
                    transition_state(&state, OnboardingState::DriftDetected, app_handle.as_ref());
                }
                Ok(InstallState::OtherTool(tool)) => {
                    transition_state(
                        &state,
                        OnboardingState::ConflictDetected(tool),
                        app_handle.as_ref(),
                    );
                }
                Ok(InstallState::Orphaned) => {
                    transition_state(&state, OnboardingState::Installing, app_handle.as_ref());

                    match silent_install(&orbit_cli_path) {
                        Ok(()) => {
                            transition_state(
                                &state,
                                OnboardingState::Connected,
                                app_handle.as_ref(),
                            );
                        }
                        Err(InstallError::PermissionDenied) => {
                            transition_state(
                                &state,
                                OnboardingState::PermissionDenied,
                                app_handle.as_ref(),
                            );
                        }
                        Err(e) => {
                            transition_state(
                                &state,
                                OnboardingState::Error(e.to_string()),
                                app_handle.as_ref(),
                            );
                        }
                    }
                }
                Err(e) => {
                    transition_state(
                        &state,
                        OnboardingState::Error(e.to_string()),
                        app_handle.as_ref(),
                    );
                }
            }
        });
    }

    pub fn set_state(&self, next: OnboardingState) {
        transition_state(&self.state, next, None);
    }

    pub fn set_state_with_emitter(&self, next: OnboardingState, app_handle: AppHandle) {
        transition_state(&self.state, next, Some(&app_handle));
    }

    /// Retry installation (for use after user grants permission)
    pub fn retry_install(&self) {
        self.retry_install_inner(None);
    }

    pub fn retry_install_with_emitter(&self, app_handle: AppHandle) {
        self.retry_install_inner(Some(app_handle));
    }

    fn retry_install_inner(&self, app_handle: Option<AppHandle>) {
        let state = Arc::clone(&self.state);
        let orbit_cli_path = self.orbit_cli_path.clone();

        std::thread::spawn(move || {
            transition_state(&state, OnboardingState::Installing, app_handle.as_ref());

            match silent_install(&orbit_cli_path) {
                Ok(()) => {
                    transition_state(&state, OnboardingState::Connected, app_handle.as_ref());
                }
                Err(InstallError::PermissionDenied) => {
                    transition_state(
                        &state,
                        OnboardingState::PermissionDenied,
                        app_handle.as_ref(),
                    );
                }
                Err(InstallError::Conflict(tool)) => {
                    transition_state(
                        &state,
                        OnboardingState::ConflictDetected(tool),
                        app_handle.as_ref(),
                    );
                }
                Err(e) => {
                    transition_state(
                        &state,
                        OnboardingState::Error(e.to_string()),
                        app_handle.as_ref(),
                    );
                }
            }
        });
    }

    /// Uninstall Orbit (for use in settings menu)
    pub fn uninstall(&self, force: bool) -> Result<(), String> {
        installer::silent_uninstall(force).map_err(|e| e.to_string())
    }

    /// Switch to Orbit with backup (for conflict resolution)
    pub fn switch_to_orbit_with_backup(&self) {
        self.switch_to_orbit_with_backup_inner(None);
    }

    pub fn switch_to_orbit_with_backup_with_emitter(&self, app_handle: AppHandle) {
        self.switch_to_orbit_with_backup_inner(Some(app_handle));
    }

    fn switch_to_orbit_with_backup_inner(&self, app_handle: Option<AppHandle>) {
        let state = Arc::clone(&self.state);
        let orbit_cli_path = self.orbit_cli_path.clone();

        std::thread::spawn(move || {
            transition_state(&state, OnboardingState::Installing, app_handle.as_ref());

            match conflict_dialog::backup_and_switch_to_orbit(&orbit_cli_path) {
                Ok(_) => {
                    transition_state(&state, OnboardingState::Connected, app_handle.as_ref());
                }
                Err(InstallError::PermissionDenied) => {
                    transition_state(
                        &state,
                        OnboardingState::PermissionDenied,
                        app_handle.as_ref(),
                    );
                }
                Err(InstallError::Conflict(tool)) => {
                    transition_state(
                        &state,
                        OnboardingState::ConflictDetected(tool),
                        app_handle.as_ref(),
                    );
                }
                Err(e) => {
                    transition_state(
                        &state,
                        OnboardingState::Error(e.to_string()),
                        app_handle.as_ref(),
                    );
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn onboarding_state_transitions() {
        let manager = OnboardingManager::new("/opt/orbit-cli".to_string());

        // Initial state
        assert_eq!(manager.state(), OnboardingState::Welcome);

        // State should transition after start
        manager.start_background_check();

        // Wait a bit for state transition
        std::thread::sleep(Duration::from_millis(100));

        // State should have moved past Welcome
        let state = manager.state();
        assert!(!matches!(state, OnboardingState::Welcome));
    }

    #[test]
    fn tray_status_mapping() {
        assert_eq!(
            OnboardingState::Welcome.tray_status(),
            TrayStatus::Connecting
        );
        assert_eq!(
            OnboardingState::Checking.tray_status(),
            TrayStatus::Connecting
        );
        assert_eq!(
            OnboardingState::Installing.tray_status(),
            TrayStatus::Connecting
        );
        assert_eq!(
            OnboardingState::Connected.tray_status(),
            TrayStatus::Connected
        );
        assert_eq!(
            OnboardingState::ConflictDetected("test".to_string()).tray_status(),
            TrayStatus::Conflict
        );
        assert_eq!(
            OnboardingState::PermissionDenied.tray_status(),
            TrayStatus::NeedsPermission
        );
        assert_eq!(
            OnboardingState::DriftDetected.tray_status(),
            TrayStatus::Conflict
        );
        assert_eq!(
            OnboardingState::Error("test".to_string()).tray_status(),
            TrayStatus::Error
        );
    }

    #[test]
    fn needs_attention_detection() {
        assert!(!OnboardingState::Welcome.needs_attention());
        assert!(!OnboardingState::Checking.needs_attention());
        assert!(!OnboardingState::Installing.needs_attention());
        assert!(!OnboardingState::Connected.needs_attention());
        assert!(OnboardingState::ConflictDetected("test".to_string()).needs_attention());
        assert!(OnboardingState::PermissionDenied.needs_attention());
        assert!(OnboardingState::DriftDetected.needs_attention());
        assert!(OnboardingState::Error("test".to_string()).needs_attention());
    }

    #[test]
    fn completion_detection() {
        assert!(!OnboardingState::Welcome.is_complete());
        assert!(!OnboardingState::Checking.is_complete());
        assert!(!OnboardingState::Installing.is_complete());
        assert!(OnboardingState::Connected.is_complete());
        assert!(OnboardingState::ConflictDetected("test".to_string()).is_complete());
        assert!(OnboardingState::PermissionDenied.is_complete());
        assert!(OnboardingState::DriftDetected.is_complete());
        assert!(OnboardingState::Error("test".to_string()).is_complete());
    }
}
