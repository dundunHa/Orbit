//! Settings menu integration for the system tray.

use super::onboarding::{OnboardingManager, OnboardingState};
use std::thread;
use tauri::{
    AppHandle, Manager, Runtime,
    menu::{MenuId, MenuItem, Submenu, SubmenuBuilder},
};

const SETTINGS_SUBMENU_ID: &str = "tray-settings";
const UNINSTALL_MENU_ID: &str = "tray-settings-uninstall";
const RECHECK_MENU_ID: &str = "tray-settings-recheck";

pub fn build_submenu<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<Submenu<R>> {
    let uninstall_item = MenuItem::with_id(app, UNINSTALL_MENU_ID, "卸载Orbit", true, None::<&str>)?;
    let recheck_item = MenuItem::with_id(app, RECHECK_MENU_ID, "重新检查连接", true, None::<&str>)?;

    SubmenuBuilder::with_id(app, SETTINGS_SUBMENU_ID, "设置")
        .item(&uninstall_item)
        .item(&recheck_item)
        .build()
}

pub fn handle_menu_event<R: Runtime>(app: &AppHandle<R>, id: &MenuId) -> bool {
    if id == UNINSTALL_MENU_ID {
        trigger_uninstall(app);
        true
    } else if id == RECHECK_MENU_ID {
        trigger_recheck(app);
        true
    } else {
        false
    }
}

fn trigger_uninstall<R: Runtime>(app: &AppHandle<R>) {
    let Some(onboarding) = app
        .try_state::<OnboardingManager>()
        .map(|state| state.inner().clone())
    else {
        return;
    };

    thread::spawn(move || match onboarding.uninstall(false) {
        Ok(()) => onboarding.set_state(OnboardingState::Welcome),
        Err(err) => onboarding.set_state(OnboardingState::Error(err)),
    });
}

fn trigger_recheck<R: Runtime>(app: &AppHandle<R>) {
    let Some(onboarding) = app
        .try_state::<OnboardingManager>()
        .map(|state| state.inner().clone())
    else {
        return;
    };

    onboarding.start_background_check();
}
