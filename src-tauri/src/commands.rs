use crate::history;
use crate::notch::NotchGeometry;
use crate::state::{PendingPermissions, PermissionDecision, Session, SessionMap};

const LEFT_ZONE_WIDTH: f64 = 50.0;
const RIGHT_ZONE_WIDTH: f64 = 50.0;
const MASCOT_LEFT_INSET: f64 = 8.0;
const MIN_EXPANDED_HEIGHT: f64 = 168.0;
const MAX_EXPANDED_HEIGHT: f64 = 320.0;

/// Cached screen geometry from initial notch detection, set during app setup
pub static NOTCH_GEOMETRY: std::sync::OnceLock<NotchGeometry> = std::sync::OnceLock::new();

fn current_notch_geometry() -> NotchGeometry {
    NOTCH_GEOMETRY
        .get()
        .copied()
        .unwrap_or_else(NotchGeometry::fallback)
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

fn clamp_expanded_height(height: f64) -> f64 {
    height.clamp(MIN_EXPANDED_HEIGHT, MAX_EXPANDED_HEIGHT)
}

/// Apply frame to NSWindow using native macOS coordinates (bottom-left origin).
/// SAFETY: Must be called on the main thread. `view_addr` must be a valid NSView pointer.
#[cfg(target_os = "macos")]
unsafe fn apply_native_frame(view_addr: usize, x: f64, width: f64, height: f64) {
    use objc2_app_kit::NSView;
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    unsafe {
        let ns_view = view_addr as *mut NSView;
        if let Some(ns_window) = (*ns_view).window() {
            if let Some(screen) = ns_window.screen() {
                let sf = screen.frame();
                let win_rect = NSRect::new(
                    NSPoint::new(
                        sf.origin.x + x,
                        sf.origin.y + sf.size.height - height,
                    ),
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

/// Set window frame at the physical screen top using native macOS API.
/// On non-macOS, falls back to Tauri's set_position/set_size.
pub fn set_window_frame_pub(window: &tauri::WebviewWindow, width: f64, height: f64) {
    set_window_frame(window, width, height);
}

fn set_window_frame(window: &tauri::WebviewWindow, width: f64, height: f64) {
    let notch = current_notch_geometry();
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
