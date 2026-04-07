//! GUI Onboarding Module
//!
//! Handles automatic installation of Orbit integration on GUI startup.
//! Designed for "silent & seamless" UX - background auto-install with tray indicators.

use crate::installer::{
    self, InstallError, InstallState, check_install_state, silent_force_install, silent_install,
};
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
            OnboardingState::Installing => "Connecting Orbit to Claude Code...".to_string(),
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

    #[allow(dead_code)]
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
    orbit_helper_path: String,
}

impl OnboardingManager {
    /// Create a new onboarding manager
    pub fn new(orbit_helper_path: String) -> Self {
        Self {
            state: Arc::new(Mutex::new(OnboardingState::Welcome)),
            orbit_helper_path,
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
        let orbit_helper_path = self.orbit_helper_path.clone();

        std::thread::spawn(move || {
            transition_state(&state, OnboardingState::Checking, app_handle.as_ref());

            match check_install_state(&orbit_helper_path) {
                Ok(InstallState::OrbitInstalled) => {
                    transition_state(&state, OnboardingState::Connected, app_handle.as_ref());
                }
                Ok(InstallState::NotInstalled) => {
                    transition_state(&state, OnboardingState::Installing, app_handle.as_ref());

                    match silent_install(&orbit_helper_path) {
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
                    transition_state(
                        &state,
                        OnboardingState::ConflictDetected(
                            "Orbit integration is incomplete. Click Retry to repair it."
                                .to_string(),
                        ),
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

    pub fn set_state(&self, next: OnboardingState) {
        transition_state(&self.state, next, None);
    }

    pub fn retry_install_with_emitter(&self, app_handle: AppHandle) {
        self.retry_install_inner(Some(app_handle));
    }

    fn retry_install_inner(&self, app_handle: Option<AppHandle>) {
        let state = Arc::clone(&self.state);
        let orbit_helper_path = self.orbit_helper_path.clone();

        std::thread::spawn(move || {
            transition_state(&state, OnboardingState::Installing, app_handle.as_ref());

            match silent_force_install(&orbit_helper_path) {
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::installer::{self, TEST_HOME_ENV_LOCK, silent_install, write_settings};
    use serde_json::json;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::MutexGuard;

    #[test]
    fn onboarding_state_transitions() {
        let manager = OnboardingManager::new(
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper".to_string(),
        );

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

    struct TestHome {
        _guard: MutexGuard<'static, ()>,
        path: PathBuf,
        old_home: Option<String>,
    }

    impl TestHome {
        fn new() -> Self {
            let guard = TEST_HOME_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let path = std::env::temp_dir().join(format!(
                "orbit-onboarding-home-{}",
                chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default()
            ));
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

    fn wait_for_completion(manager: &OnboardingManager) -> OnboardingState {
        for _ in 0..20 {
            let state = manager.state();
            if state.is_complete() {
                return state;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        manager.state()
    }

    #[test]
    fn onboarding_auto_connects_over_standard_command_statusline() {
        let home = TestHome::new();
        if let Some(parent) = home.settings_path().parent() {
            fs::create_dir_all(parent).unwrap();
        }
        write_settings(
            &home.settings_path(),
            &json!({
                "statusLine": {
                    "type": "command",
                    "command": "/usr/local/bin/other-tool"
                }
            }),
        )
        .unwrap();

        let manager = OnboardingManager::new(
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper".to_string(),
        );
        manager.start_background_check();

        assert_eq!(wait_for_completion(&manager), OnboardingState::Connected);
    }

    #[test]
    fn onboarding_still_flags_unsupported_statusline_configs() {
        let home = TestHome::new();
        if let Some(parent) = home.settings_path().parent() {
            fs::create_dir_all(parent).unwrap();
        }
        write_settings(
            &home.settings_path(),
            &json!({
                "statusLine": {
                    "type": "script",
                    "command": "/usr/local/bin/other-tool"
                }
            }),
        )
        .unwrap();

        let manager = OnboardingManager::new(
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper".to_string(),
        );
        manager.start_background_check();

        assert_eq!(
            wait_for_completion(&manager),
            OnboardingState::ConflictDetected("/usr/local/bin/other-tool".to_string())
        );
    }

    #[test]
    fn onboarding_repairs_missing_new_hook_events_automatically() {
        let home = TestHome::new();
        silent_install("/Applications/Orbit.app/Contents/MacOS/orbit-helper").unwrap();

        let mut settings = installer::read_settings(&home.settings_path()).unwrap();
        settings
            .get_mut("hooks")
            .and_then(|v| v.as_object_mut())
            .unwrap()
            .remove("Elicitation");
        installer::write_settings(&home.settings_path(), &settings).unwrap();

        let manager = OnboardingManager::new(
            "/Applications/Orbit.app/Contents/MacOS/orbit-helper".to_string(),
        );
        manager.start_background_check();

        assert_eq!(wait_for_completion(&manager), OnboardingState::Connected);

        let repaired = installer::read_settings(&home.settings_path()).unwrap();
        assert!(
            repaired
                .get("hooks")
                .and_then(|v| v.get("Elicitation"))
                .and_then(|v| v.as_array())
                .is_some()
        );
    }
}
