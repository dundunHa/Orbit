use crate::app::onboarding::{OnboardingManager, OnboardingStatePayload};
use crate::history;
use crate::notch::NotchGeometry;
use crate::state::{PendingPermissions, PermissionDecision, Session, SessionMap};
use parking_lot::RwLock;
use serde_json::Value;
use std::sync::LazyLock;

pub const LEFT_ZONE_WIDTH: f64 = 35.0;
pub const RIGHT_ZONE_WIDTH: f64 = 25.0;
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

/// Dispatch a closure to the macOS main thread synchronously via GCD, returning its value.
/// If already on the main thread, calls `f` directly to avoid deadlock.
#[cfg(target_os = "macos")]
fn dispatch_sync_main<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    use std::ffi::c_void;
    use std::sync::mpsc;
    unsafe extern "C" {
        static _dispatch_main_q: c_void;
        fn dispatch_sync_f(
            queue: *const c_void,
            context: *mut c_void,
            work: unsafe extern "C" fn(*mut c_void),
        );
        fn pthread_main_np() -> i32;
    }
    if unsafe { pthread_main_np() } != 0 {
        return f();
    }
    let (tx, rx) = mpsc::sync_channel::<T>(1);
    let boxed: Box<Box<dyn FnOnce()>> = Box::new(Box::new(move || {
        let _ = tx.send(f());
    }));
    unsafe extern "C" fn trampoline(ctx: *mut c_void) {
        unsafe {
            let f = Box::from_raw(ctx as *mut Box<dyn FnOnce()>);
            f();
        }
    }
    unsafe {
        dispatch_sync_f(
            &_dispatch_main_q as *const c_void,
            Box::into_raw(boxed) as *mut c_void,
            trampoline,
        );
    }
    rx.recv()
        .expect("dispatch_sync_main: main thread failed to respond")
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
        if let Ok(wh) = window.window_handle()
            && let RawWindowHandle::AppKit(appkit) = wh.as_raw()
        {
            let view_addr = appkit.ns_view.as_ptr() as usize;
            // AppKit must be accessed on the main thread; dispatch_sync_main ensures this
            // regardless of which thread the Tauri command handler or async task is running on.
            return dispatch_sync_main(move || unsafe { current_native_window_height(view_addr) });
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
        if let Ok(wh) = window.window_handle()
            && let RawWindowHandle::AppKit(appkit) = wh.as_raw()
        {
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
    content: Option<Value>,
    pending: tauri::State<'_, PendingPermissions>,
) -> Result<(), String> {
    let mut pending = pending.lock().await;
    if let Some(perm) = pending.remove(&perm_id) {
        let _ = perm.responder.send(PermissionDecision {
            decision,
            reason,
            content,
        });
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
        // RAII guard: restores the global geometry even if the test panics.
        struct Restore(NotchGeometry);
        impl Drop for Restore {
            fn drop(&mut self) {
                update_notch_geometry(self.0);
            }
        }

        let original = current_notch_geometry();
        let _restore = Restore(original);

        let updated = NotchGeometry {
            screen_width: original.screen_width + 120.0,
            notch_left: original.notch_left + 30.0,
            ..original
        };

        update_notch_geometry(updated);

        assert_eq!(current_notch_geometry().screen_width, updated.screen_width);
        assert_eq!(current_notch_geometry().notch_left, updated.notch_left);
        // _restore drops here, restoring original
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn detect_resume_terminal_prefers_running_alacritty() {
        let processes = "/Applications/Alacritty.app/Contents/MacOS/alacritty\n";
        assert_eq!(
            detect_resume_terminal_from_processes(processes, false),
            Some(ResumeTerminal::Alacritty)
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn detect_resume_terminal_falls_back_to_installed_alacritty() {
        assert_eq!(
            detect_resume_terminal_from_processes("", true),
            Some(ResumeTerminal::Alacritty)
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn build_resume_shell_command_uses_current_claude_cli() {
        let command = build_resume_shell_command("/tmp/demo dir", "session-123");
        // claude binary is shell-quoted (absolute path or bare "claude")
        assert!(command.contains("claude"));
        assert!(command.contains("--resume 'session-123'"));
        assert!(command.contains("cd '/tmp/demo dir'"));
        assert!(!command.contains("claude-code"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn build_resume_launch_spec_uses_alacritty_binary() {
        let spec = build_resume_launch_spec(ResumeTerminal::Alacritty, "/tmp", "session-123");

        match spec {
            ResumeLaunchSpec::Process { program, args } => {
                assert_eq!(program, ALACRITTY_BINARY);
                assert_eq!(args[0], "--working-directory");
                assert_eq!(args[1], "/tmp");
                assert_eq!(args[2], "--command");
                assert_eq!(args[3], "/bin/zsh");
                assert_eq!(args[4], "-lc");
                assert!(args[5].contains("claude"));
                assert!(args[5].contains("--resume 'session-123'"));
            }
            ResumeLaunchSpec::AppleScript(_) => panic!("expected Alacritty process launch"),
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn parse_tmux_clients_picks_most_active() {
        let output = "/dev/ttys001\tmain\t1712000100\n/dev/ttys002\twork\t1712000200\n/dev/ttys003\tdev\t1712000050\n";
        let result = parse_tmux_clients(output);
        assert_eq!(result, Some("/dev/ttys002".to_string()));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn parse_tmux_clients_single_client() {
        let output = "/dev/ttys005\tmysession\t1712000300\n";
        let result = parse_tmux_clients(output);
        assert_eq!(result, Some("/dev/ttys005".to_string()));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn parse_tmux_clients_empty_returns_none() {
        assert_eq!(parse_tmux_clients(""), None);
        assert_eq!(parse_tmux_clients("\n"), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn parse_tmux_display_valid() {
        let output = "main\t0\t1\n";
        assert_eq!(parse_tmux_display(output), Some("main:0.1".to_string()));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn parse_tmux_display_malformed() {
        assert_eq!(parse_tmux_display(""), None);
        assert_eq!(parse_tmux_display("onlyone"), None);
        assert_eq!(parse_tmux_display("two\tfields"), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn build_resume_launch_spec_tmux_uses_split_window() {
        let spec = build_resume_launch_spec(
            ResumeTerminal::Tmux {
                binary: "/opt/homebrew/bin/tmux".to_string(),
                target_pane: "main:0.1".to_string(),
            },
            "/tmp/project",
            "session-abc",
        );

        match spec {
            ResumeLaunchSpec::Process { program, args } => {
                assert_eq!(program, "/opt/homebrew/bin/tmux");
                assert_eq!(args[0], "split-window");
                assert_eq!(args[1], "-h");
                assert_eq!(args[2], "-t");
                assert_eq!(args[3], "main:0.1");
                assert_eq!(args[4], "-c");
                assert_eq!(args[5], "/tmp/project");
                // The last arg is the shell command
                assert!(args[6].contains("claude"));
                assert!(args[6].contains("--resume 'session-abc'"));
            }
            ResumeLaunchSpec::AppleScript(_) => panic!("expected tmux process launch"),
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn build_resume_launch_spec_terminal_app_uses_applescript() {
        let spec =
            build_resume_launch_spec(ResumeTerminal::TerminalApp, "/tmp", "session-xyz");

        match spec {
            ResumeLaunchSpec::AppleScript(script) => {
                assert!(script.contains("tell application \"Terminal\""));
                assert!(script.contains("do script"));
                assert!(script.contains("session-xyz"));
            }
            ResumeLaunchSpec::Process { .. } => panic!("expected AppleScript launch"),
        }
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

#[cfg(target_os = "macos")]
const ALACRITTY_BINARY: &str = "/Applications/Alacritty.app/Contents/MacOS/alacritty";

#[cfg(target_os = "macos")]
#[derive(Debug, Clone, PartialEq, Eq)]
enum ResumeTerminal {
    Tmux {
        binary: String,
        target_pane: String,
    },
    Alacritty,
    TerminalApp,
}

#[cfg(target_os = "macos")]
#[derive(Debug, Clone, PartialEq, Eq)]
enum ResumeLaunchSpec {
    AppleScript(String),
    Process {
        program: String,
        args: Vec<String>,
    },
}

#[cfg(target_os = "macos")]
const TMUX_CANDIDATES: &[&str] = &[
    "/opt/homebrew/bin/tmux",  // Apple Silicon homebrew
    "/usr/local/bin/tmux",     // Intel homebrew / manual
    "/opt/local/bin/tmux",     // MacPorts
];

#[cfg(target_os = "macos")]
const CLAUDE_CANDIDATES: &[&str] = &[
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
];

#[cfg(target_os = "macos")]
fn find_tmux_binary() -> Option<&'static str> {
    TMUX_CANDIDATES
        .iter()
        .find(|p| std::path::Path::new(p).exists())
        .copied()
}

#[cfg(target_os = "macos")]
fn find_claude_binary() -> String {
    CLAUDE_CANDIDATES
        .iter()
        .find(|p| std::path::Path::new(p).exists())
        .map(|s| s.to_string())
        .unwrap_or_else(|| "claude".to_string())
}

/// Parse `tmux list-clients` output to find the most recently active client's tty.
/// Format: `<client_tty>\t<session_name>\t<client_activity>`
#[cfg(target_os = "macos")]
fn parse_tmux_clients(output: &str) -> Option<String> {
    output
        .lines()
        .filter_map(|line| {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 3 {
                let activity: u64 = parts[2].trim().parse().ok()?;
                Some((parts[0].to_string(), activity))
            } else {
                None
            }
        })
        .max_by_key(|(_, activity)| *activity)
        .map(|(tty, _)| tty)
}

/// Parse `tmux display-message` output to extract session:window.pane target.
/// Format: `<session_name>\t<window_index>\t<pane_index>`
#[cfg(target_os = "macos")]
fn parse_tmux_display(output: &str) -> Option<String> {
    let line = output.lines().next()?;
    let parts: Vec<&str> = line.split('\t').collect();
    if parts.len() >= 3 {
        Some(format!("{}:{}.{}", parts[0], parts[1], parts[2]))
    } else {
        None
    }
}

/// Try to match a saved tty to a live tmux pane. Returns the pane target if found.
#[cfg(target_os = "macos")]
fn try_match_tty_to_pane(tmux_binary: &str, saved_tty: &str) -> Option<String> {
    // tmux list-panes -a -F '#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_index}'
    let output = std::process::Command::new(tmux_binary)
        .args([
            "list-panes",
            "-a",
            "-F",
            "#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_index}",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() >= 4 && parts[0] == saved_tty {
            return Some(format!("{}:{}.{}", parts[1], parts[2], parts[3]));
        }
    }
    None
}

/// Detect the currently active tmux pane by finding the most recent client.
#[cfg(target_os = "macos")]
fn detect_tmux_active_pane(tmux_binary: &str) -> Option<String> {
    // Step 1: list attached clients, pick most active
    let output = std::process::Command::new(tmux_binary)
        .args([
            "list-clients",
            "-F",
            "#{client_tty}\t#{session_name}\t#{client_activity}",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let client_tty = parse_tmux_clients(&stdout)?;

    // Step 2: get the current pane of this client
    let output = std::process::Command::new(tmux_binary)
        .args([
            "display-message",
            "-p",
            "-t",
            &client_tty,
            "#{session_name}\t#{window_index}\t#{pane_index}",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_tmux_display(&stdout)
}

#[cfg(target_os = "macos")]
fn shell_single_quote(s: &str) -> String {
    let mut result = String::from("'");
    for c in s.chars() {
        match c {
            '\'' => result.push_str("'\"'\"'"),
            other => result.push(other),
        }
    }
    result.push('\'');
    result
}

#[cfg(target_os = "macos")]
fn detect_resume_terminal_from_processes(
    processes: &str,
    alacritty_installed: bool,
) -> Option<ResumeTerminal> {
    let alacritty_running = processes
        .lines()
        .any(|line| line.contains(ALACRITTY_BINARY));
    if alacritty_running || alacritty_installed {
        return Some(ResumeTerminal::Alacritty);
    }
    None
}

/// Detect a non-tmux terminal for fallback after tmux failure.
#[cfg(target_os = "macos")]
fn detect_non_tmux_terminal() -> ResumeTerminal {
    let alacritty_installed = std::path::Path::new(ALACRITTY_BINARY).exists();

    if let Ok(output) = std::process::Command::new("ps")
        .args(["-ax", "-o", "command="])
        .output()
        && output.status.success()
    {
        let processes = String::from_utf8_lossy(&output.stdout);
        if let Some(terminal) =
            detect_resume_terminal_from_processes(processes.as_ref(), alacritty_installed)
        {
            return terminal;
        }
    }

    if alacritty_installed {
        return ResumeTerminal::Alacritty;
    }

    ResumeTerminal::TerminalApp
}

#[cfg(target_os = "macos")]
fn build_resume_shell_command(cwd: &str, session_id: &str) -> String {
    let claude = find_claude_binary();
    format!(
        "cd {} && exec {} --resume {}",
        shell_single_quote(cwd),
        shell_single_quote(&claude),
        shell_single_quote(session_id)
    )
}

#[cfg(target_os = "macos")]
fn build_resume_launch_spec(
    terminal: ResumeTerminal,
    cwd: &str,
    session_id: &str,
) -> ResumeLaunchSpec {
    let shell_command = build_resume_shell_command(cwd, session_id);

    match terminal {
        ResumeTerminal::Tmux { binary, target_pane } => ResumeLaunchSpec::Process {
            program: binary,
            args: vec![
                "split-window".to_string(),
                "-h".to_string(),
                "-t".to_string(),
                target_pane,
                "-c".to_string(),
                cwd.to_string(),
                shell_command,
            ],
        },
        ResumeTerminal::Alacritty => ResumeLaunchSpec::Process {
            program: ALACRITTY_BINARY.to_string(),
            args: vec![
                "--working-directory".to_string(),
                cwd.to_string(),
                "--command".to_string(),
                "/bin/zsh".to_string(),
                "-lc".to_string(),
                shell_command,
            ],
        },
        ResumeTerminal::TerminalApp => ResumeLaunchSpec::AppleScript(format!(
            r#"tell application "Terminal"
    do script "{}"
    activate
end tell"#,
            escape_for_applescript(&shell_command)
        )),
    }
}

/// Resume a Claude Code session in a new terminal window or tmux pane.
/// Strategy: tty match → active tmux client → Alacritty/Terminal.app
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
        // Mixed strategy: try tty match first, then heuristic tmux, then fallback
        let tmux_binary = find_tmux_binary();

        if let Some(tmux_bin) = tmux_binary {
            // Step 1: Try to match saved tty from history to a live tmux pane
            let saved_tty = crate::history::find_entry(&session_id).and_then(|e| e.tty);
            let tty_target = saved_tty
                .as_deref()
                .and_then(|tty| try_match_tty_to_pane(tmux_bin, tty));

            // Step 2: If tty matched, use that pane; otherwise try active client
            let tmux_target = tty_target.or_else(|| detect_tmux_active_pane(tmux_bin));

            if let Some(target_pane) = tmux_target {
                let terminal = ResumeTerminal::Tmux {
                    binary: tmux_bin.to_string(),
                    target_pane,
                };
                let spec = build_resume_launch_spec(terminal, cwd_str, &session_id);
                match execute_launch_spec(spec) {
                    Ok(()) => return Ok(()),
                    Err(_) => {
                        // tmux failed, fall through to non-tmux terminal
                    }
                }
            }
        }

        // Step 3: Fallback to Alacritty or Terminal.app
        let fallback = detect_non_tmux_terminal();
        let spec = build_resume_launch_spec(fallback, cwd_str, &session_id);
        execute_launch_spec(spec)?;
    }

    #[cfg(not(target_os = "macos"))]
    {
        return Err("Session resume is currently only supported on macOS".to_string());
    }

    Ok(())
}

/// Execute a ResumeLaunchSpec, returning Ok on success.
#[cfg(target_os = "macos")]
fn execute_launch_spec(spec: ResumeLaunchSpec) -> Result<(), String> {
    match spec {
        ResumeLaunchSpec::AppleScript(script) => {
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
        ResumeLaunchSpec::Process { program, args } => {
            std::process::Command::new(&program)
                .args(&args)
                .spawn()
                .map_err(|e| format!("Failed to launch terminal: {}", e))?;
        }
    }
    Ok(())
}
