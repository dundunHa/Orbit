//! Silent conflict resolution for onboarding.
//!
//! When Orbit detects another tool already owns Claude Code's `statusLine`,
//! this module silently triggers a force-install through the onboarding manager.
//! The wrapper script is fail-open and passes through to the original command,
//! so the other tool's functionality is preserved.

use super::onboarding::{OnboardingManager, OnboardingState};
use std::thread;
use std::time::Duration;
use tauri::AppHandle;

const POLL_INTERVAL: Duration = Duration::from_millis(250);

pub fn start_monitor(onboarding: OnboardingManager, app_handle: AppHandle) {
    thread::spawn(move || loop {
        match onboarding.state() {
            OnboardingState::ConflictDetected(_) | OnboardingState::DriftDetected => {
                onboarding.force_install_with_emitter(app_handle.clone());
                break;
            }
            state if state.is_complete() => break,
            _ => thread::sleep(POLL_INTERVAL),
        }
    });
}
