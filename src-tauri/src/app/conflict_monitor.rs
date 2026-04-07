//! Lightweight onboarding state monitor.
//!
//! Orbit used to silently force-install when it detected a statusline conflict.
//! The app now takes a conservative path: automatic setup only for clean installs,
//! explicit user retry for reconnect/repair scenarios.

use super::onboarding::{OnboardingManager, OnboardingState};
use std::thread;
use std::time::Duration;

const POLL_INTERVAL: Duration = Duration::from_millis(250);

pub fn start_monitor(onboarding: OnboardingManager) {
    thread::spawn(move || {
        loop {
            match onboarding.state() {
                // Keep the monitor alive only while startup is still converging.
                // Once Orbit needs user input or finishes setup, stop polling.
                OnboardingState::Welcome
                | OnboardingState::Checking
                | OnboardingState::Installing => thread::sleep(POLL_INTERVAL),
                state if state.is_complete() || state.needs_attention() => break,
                _ => thread::sleep(POLL_INTERVAL),
            }
        }
    });
}
