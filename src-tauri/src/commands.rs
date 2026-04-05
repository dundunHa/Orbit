use crate::app::onboarding::{OnboardingManager, OnboardingStatePayload};
use crate::app::permission_dialog;
use crate::history;
use crate::notch::NotchGeometry;
use crate::state::{PendingPermissions, PermissionDecision, Session, SessionMap};
use parking_lot::RwLock;
use std::sync::LazyLock;

pub const LEFT_ZONE_WIDTH: f64 = 45.0;
pub const RIGHT_ZONE_WIDTH: f64 = 45.0;
pub const MASCOT_LEFT_INSET: f64 = 8.0;
const MIN_EXPANDED_HEIGHT: f64 = 168.0;
const MAX_EXPANDED_HEIGHT: f64 = 320.0;

pub static NOTCH_GEOMETRY: LazyLock<RwLock<NotchGeometry>> =
    LazyLock::new(|| RwLock::new(NotchGeometry::fallback()));

pub fn update_notch_geometry(notch: NotchGeometry) {
    let mut geometry = NOTCH_GEOMETRY.write();
    *geometry = notch;
}

fn current_notch_geometry() -> NotchGeometry {
    *NOTCH_GEOMETRY.read()
}

fn collapsed_height() -> f64 {
    current_notch_geometry().notch_height
}

fn pill_width(notch: NotchGeometry) -> f64 {
    LEFT_ZONE_WIDTH + notch.notch_width + RIGHT_ZONE_WIDTH
}

fn pill_left(notch: NotchGeometry) -> f64 {
    let width = pill_width(notch);
    (notch.notch_left - LEFT_ZONE_WIDTH).clamp(0.0, (notch.screen_width - width).max(0.0))
}

pub fn current_pill_width() -> f64 {
    pill_width(current_notch_geometry())
}

pub fn pill_width_for_geometry(notch: NotchGeometry) -> f64 {
    pill_width(notch)
}

fn clamp_expanded_height(height: f64) -> f64 {
    height.clamp(MIN_EXPANDED_HEIGHT, MAX_EXPANDED_HEIGHT)
}

/// Apply frame to NSWindow using native macOS coordinates (bottom-left origin).
/// SAFETY: Must be called on the main thread. `view_addr` must be a valid NSView pointer.
#[cfg(target_os = "macos")]
unsafe fn apply_native_frame(view_addr: usize, x: f64, width: f64, height: f64) {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSView;
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    unsafe {
        let ns_view = view_addr as *mut NSView;
        if let Some(ns_window) = (*ns_view).window() {
            let screen = ns_window
                .screen()
                .or_else(|| MainThreadMarker::new().and_then(objc2_app_kit::NSScreen::mainScreen));
            if let Some(screen) = screen {
                let sf = screen.frame();
                let win_rect = NSRect::new(
                    NSPoint::new(sf.origin.x + x, sf.origin.y + sf.size.height - height),
                    NSSize::new(width, height),
                );
                ns_window.setFrame_display(win_rect, true);
            }
        }
    }
}

/// Dispatch a closure to the macOS main thread via GCD.
#[cfg(target_os = "macos")]
fn dispatch_on_main(f: impl FnOnce() + Send + 'static) {
    use std::ffi::c_void;
    unsafe extern "C" {
        static _dispatch_main_q: c_void;
        fn dispatch_async_f(
            queue: *const c_void,
            context: *mut c_void,
            work: unsafe extern "C" fn(*mut c_void),
        );
    }
    unsafe extern "C" fn trampoline(ctx: *mut c_void) {
        unsafe {
            let f = Box::from_raw(ctx as *mut Box<dyn FnOnce()>);
            f();
        }
    }
    let boxed: Box<Box<dyn FnOnce()>> = Box::new(Box::new(f));
    unsafe {
        dispatch_async_f(
            &_dispatch_main_q as *const c_void,
            Box::into_raw(boxed) as *mut c_void,
            trampoline,
        );
    }
}

pub fn set_window_frame_for_geometry_pub(
    window: &tauri::WebviewWindow,
    notch: NotchGeometry,
    width: f64,
    height: f64,
) {
    set_window_frame_for_geometry(window, notch, width, height);
}

pub fn current_window_height_pub(window: &tauri::WebviewWindow) -> Option<f64> {
    current_window_height(window)
}

fn set_window_frame(window: &tauri::WebviewWindow, width: f64, height: f64) {
    set_window_frame_for_geometry(window, current_notch_geometry(), width, height);
}

fn current_window_height(window: &tauri::WebviewWindow) -> Option<f64> {
    #[cfg(target_os = "macos")]
    {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        if let Ok(wh) = window.window_handle() {
            if let RawWindowHandle::AppKit(appkit) = wh.as_raw() {
                let view_addr = appkit.ns_view.as_ptr() as usize;
                return unsafe { current_native_window_height(view_addr) };
            }
        }
        None
    }

    #[cfg(not(target_os = "macos"))]
    {
        let size = window.inner_size().ok()?;
        Some(size.height as f64)
    }
}

#[cfg(target_os = "macos")]
unsafe fn current_native_window_height(view_addr: usize) -> Option<f64> {
    use objc2_app_kit::NSView;

    let ns_view = view_addr as *mut NSView;
    let ns_window = unsafe { (*ns_view).window()? };
    Some(ns_window.frame().size.height)
}

fn set_window_frame_for_geometry(
    window: &tauri::WebviewWindow,
    notch: NotchGeometry,
    width: f64,
    height: f64,
) {
    let x = pill_left(notch);

    #[cfg(target_os = "macos")]
    {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        if let Ok(wh) = window.window_handle() {
            if let RawWindowHandle::AppKit(appkit) = wh.as_raw() {
                let view_addr = appkit.ns_view.as_ptr() as usize;

                unsafe extern "C" {
                    fn pthread_main_np() -> i32;
                }

                if unsafe { pthread_main_np() } != 0 {
                    // Already on main thread (e.g. during setup), call directly
                    unsafe {
                        apply_native_frame(view_addr, x, width, height);
                    }
                } else {
                    // Tauri commands run on tokio threads; dispatch to main
                    dispatch_on_main(move || unsafe {
                        apply_native_frame(view_addr, x, width, height);
                    });
                }
            }
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = window.set_position(tauri::LogicalPosition::new(x, 0.0));
        let _ = window.set_size(tauri::LogicalSize::new(width, height));
    }
}

#[tauri::command]
pub fn get_notch_info() -> Result<serde_json::Value, String> {
    let notch = current_notch_geometry();
    Ok(serde_json::json!({
        "notch_height": notch.notch_height,
        "screen_width": notch.screen_width,
        "notch_left": notch.notch_left,
        "notch_right": notch.notch_right,
        "notch_width": notch.notch_width,
        "left_safe_width": notch.left_safe_width,
        "right_safe_width": notch.right_safe_width,
        "has_notch": notch.notch_height > 28.0,
        "pill_width": pill_width(notch),
        "left_zone_width": LEFT_ZONE_WIDTH,
        "right_zone_width": RIGHT_ZONE_WIDTH,
        "mascot_left_inset": MASCOT_LEFT_INSET
    }))
}

#[tauri::command]
pub async fn get_sessions(sessions: tauri::State<'_, SessionMap>) -> Result<Vec<Session>, String> {
    let sessions = sessions.lock().await;
    Ok(sessions.values().cloned().collect())
}

#[tauri::command]
pub async fn get_history() -> Result<Vec<history::HistoryEntry>, String> {
    Ok(history::load_entries())
}

#[tauri::command]
pub async fn permission_decision(
    perm_id: String,
    decision: String,
    reason: Option<String>,
    pending: tauri::State<'_, PendingPermissions>,
) -> Result<(), String> {
    let mut pending = pending.lock().await;
    if let Some(perm) = pending.remove(&perm_id) {
        let _ = perm.responder.send(PermissionDecision { decision, reason });
    }
    Ok(())
}

#[tauri::command]
pub async fn open_system_settings() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let status = std::process::Command::new("open")
            .args(["-b", "com.apple.SystemSettings"])
            .status()
            .map_err(|e| format!("Failed to open System Settings: {}", e))?;

        if status.success() {
            Ok(())
        } else {
            Err("Failed to open System Settings".to_string())
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("Opening System Settings is only supported on macOS".to_string())
    }
}

#[tauri::command]
pub async fn copy_permission_cli_command() -> Result<String, String> {
    use std::io::Write as _;
    use std::process::Stdio;

    let command = permission_dialog::install_command();

    #[cfg(target_os = "macos")]
    {
        let mut child = std::process::Command::new("pbcopy")
            .stdin(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to launch pbcopy: {}", e))?;

        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| "Failed to access pbcopy stdin".to_string())?;
        stdin
            .write_all(command.as_bytes())
            .map_err(|e| format!("Failed to copy install command: {}", e))?;
        drop(stdin);

        let status = child
            .wait()
            .map_err(|e| format!("Failed to wait for pbcopy: {}", e))?;

        if status.success() {
            Ok(command)
        } else {
            Err("pbcopy exited with a non-zero status".to_string())
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("Copying the install command is only supported on macOS".to_string())
    }
}

#[tauri::command]
pub async fn expand_window(window: tauri::WebviewWindow) -> Result<(), String> {
    set_window_frame(&window, current_pill_width(), MAX_EXPANDED_HEIGHT);
    Ok(())
}

#[tauri::command]
pub async fn set_expanded_height(window: tauri::WebviewWindow, height: f64) -> Result<(), String> {
    set_window_frame(&window, current_pill_width(), clamp_expanded_height(height));
    Ok(())
}

#[tauri::command]
pub async fn collapse_window(window: tauri::WebviewWindow) -> Result<(), String> {
    set_window_frame(&window, current_pill_width(), collapsed_height());
    Ok(())
}

#[tauri::command]
pub fn get_onboarding_state(
    onboarding: tauri::State<'_, OnboardingManager>,
) -> Result<OnboardingStatePayload, String> {
    Ok(onboarding.state_payload())
}

#[tauri::command]
pub fn retry_onboarding_install(
    app_handle: tauri::AppHandle,
    onboarding: tauri::State<'_, OnboardingManager>,
) -> Result<(), String> {
    onboarding.retry_install_with_emitter(app_handle);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn updates_cached_geometry() {
        let original = current_notch_geometry();
        let updated = NotchGeometry {
            screen_width: original.screen_width + 120.0,
            notch_left: original.notch_left + 30.0,
            ..original
        };

        update_notch_geometry(updated);

        assert_eq!(current_notch_geometry().screen_width, updated.screen_width);
        assert_eq!(current_notch_geometry().notch_left, updated.notch_left);

        update_notch_geometry(original);
    }
}

fn validate_session_id(session_id: &str) -> Result<(), String> {
    if session_id.is_empty() {
        return Err("Session ID cannot be empty".to_string());
    }
    if session_id.len() > 128 {
        return Err("Session ID too long".to_string());
    }
    if session_id.starts_with('-') || session_id.starts_with('.') {
        return Err("Session ID cannot start with '-' or '.'".to_string());
    }
    if session_id.contains("..") || session_id.contains('/') || session_id.contains('\\') {
        return Err("Session ID contains invalid sequence".to_string());
    }
    if !session_id
        .chars()
        .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
    {
        return Err("Session ID contains invalid characters".to_string());
    }
    Ok(())
}

fn escape_for_applescript(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\'', "\\'")
}

/// Resume a Claude Code session in a new terminal window
/// Opens the specified working directory and resumes the session
#[tauri::command]
pub async fn resume_session(session_id: String, cwd: String) -> Result<(), String> {
    validate_session_id(&session_id)?;

    let path = std::path::Path::new(&cwd);
    if !path.exists() {
        return Err(format!("Working directory does not exist: {}", cwd));
    }

    let canonical_cwd = path
        .canonicalize()
        .map_err(|e| format!("Failed to canonicalize path: {}", e))?;
    let cwd_str = canonical_cwd.to_str().ok_or("Invalid path encoding")?;

    #[cfg(target_os = "macos")]
    {
        let safe_cwd = escape_for_applescript(cwd_str);
        let safe_session_id = escape_for_applescript(&session_id);
        let script = format!(
            r#"tell application "Terminal"
    do script "cd \"{}\" && claude-code resume --session-id \"{}\""
    activate
end tell"#,
            safe_cwd, safe_session_id
        );

        let output = std::process::Command::new("osascript")
            .arg("-e")
            .arg(&script)
            .output()
            .map_err(|e| format!("Failed to execute AppleScript: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("AppleScript failed: {}", stderr));
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        return Err("Session resume is currently only supported on macOS".to_string());
    }

    Ok(())
}
