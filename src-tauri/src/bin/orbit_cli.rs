//! Orbit CLI binary
//!
//! This is the command-line interface for Orbit. The core installation logic
//! has been extracted to the `installer` module for reuse by the GUI.

use serde_json::Value;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;

use orbit::installer;

const SOCKET_PATH: &str = "/tmp/orbit.sock";

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage: orbit-cli <command>");
        eprintln!("Commands:");
        eprintln!("  hook       Forward hook event from stdin to Orbit app");
        eprintln!("  statusline Forward statusline event from stdin to Orbit app");
        eprintln!("  install    Configure Claude Code hooks for Orbit");
        eprintln!("  uninstall  Remove Orbit hooks from Claude Code settings");
        std::process::exit(1);
    }

    match args[1].as_str() {
        "hook" => cmd_hook(),
        "statusline" => cmd_statusline(),
        "install" => cmd_install(),
        "uninstall" => cmd_uninstall(args.iter().any(|arg| arg == "--force")),
        _ => {
            eprintln!("Unknown command: {}", args[1]);
            std::process::exit(1);
        }
    }
}

fn cmd_hook() {
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        std::process::exit(1);
    }

    let input = input.trim();
    if input.is_empty() {
        std::process::exit(0);
    }

    let is_permission_request = serde_json::from_str::<Value>(input)
        .ok()
        .and_then(|val| {
            val.get("hook_event_name")
                .and_then(|v| v.as_str())
                .map(|s| s == "PermissionRequest")
        })
        .unwrap_or(false);

    match UnixStream::connect(SOCKET_PATH) {
        Ok(mut stream) => {
            if is_permission_request {
                if let Ok(val) = serde_json::from_str::<Value>(input) {
                    let control_msg = serde_json::json!({
                        "type": "PermissionRequestHandledByCli",
                        "session_id": val.get("session_id"),
                        "tool_use_id": val.get("tool_use_id")
                    });
                    let control_payload = format!("{}\n", control_msg);
                    let _ = stream.write_all(control_payload.as_bytes());
                }

                let ask_response = serde_json::json!({
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": { "behavior": "ask" }
                    }
                });
                print!("{}", ask_response);
            } else {
                let payload = format!("{}\n", input);
                if stream.write_all(payload.as_bytes()).is_err() {
                    std::process::exit(0);
                }
            }
        }
        Err(_) => {
            std::process::exit(0);
        }
    }
}

fn cmd_statusline() {
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        std::process::exit(0);
    }

    let input = input.trim();
    if input.is_empty() {
        std::process::exit(0);
    }

    let Ok(val) = serde_json::from_str::<Value>(input) else {
        std::process::exit(0)
    };

    let session_id = val
        .get("session_id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let tokens_in = val
        .get("context_window")
        .and_then(|v| v.get("total_input_tokens"))
        .and_then(|v| v.as_u64());
    let tokens_out = val
        .get("context_window")
        .and_then(|v| v.get("total_output_tokens"))
        .and_then(|v| v.as_u64());
    let cost_usd = val
        .get("cost")
        .and_then(|v| v.get("total_cost_usd"))
        .and_then(|v| v.as_f64());
    let model = val
        .get("model")
        .and_then(|v| v.get("id"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let msg = serde_json::json!({
        "type": "StatuslineUpdate",
        "session_id": session_id,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "cost_usd": cost_usd,
        "model": model
    });

    if let Ok(mut stream) = UnixStream::connect(SOCKET_PATH) {
        let payload = format!("{}\n", msg);
        let _ = stream.write_all(payload.as_bytes());
    }

    std::process::exit(0);
}

fn cmd_install() {
    let settings_path = match installer::get_claude_settings_path() {
        Ok(path) => path,
        Err(e) => {
            eprintln!("Failed to locate Claude settings path: {e}");
            std::process::exit(1)
        }
    };

    let orbit_cli = match installer::resolve_current_exe_path() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Failed to resolve orbit-cli path: {e}");
            std::process::exit(1)
        }
    };

    let hook_command = format!("{} hook", orbit_cli);
    println!("Installing Orbit hooks...");

    let result = installer::with_file_lock(&settings_path, || {
        let current_settings = installer::read_settings(&settings_path)
            .map_err(|e| installer::InstallError::Other(e))?;
        installer::ensure_settings_object(&current_settings)
            .map_err(|e| installer::InstallError::Other(e))?;

        let prepared =
            installer::prepare_install(current_settings.clone(), &orbit_cli, &hook_command)
                .map_err(|e| installer::InstallError::Other(e))?;

        installer::write_wrapper_script(&prepared.wrapper_path, &prepared.wrapper_script)
            .map_err(|e| installer::InstallError::Other(e))?;

        if let Err(e) = installer::write_settings(&settings_path, &prepared.settings) {
            let _ = installer::remove_file_if_exists(&prepared.wrapper_path);
            return Err(installer::InstallError::Other(e));
        }

        let state_path = installer::get_statusline_state_path()
            .map_err(|e| installer::InstallError::Other(e))?;
        if let Err(e) = installer::write_statusline_state(&state_path, &prepared.state) {
            let _ = installer::write_settings(&settings_path, &current_settings);
            let _ = installer::remove_file_if_exists(&prepared.wrapper_path);
            let _ = installer::remove_file_if_exists(&state_path);
            return Err(installer::InstallError::Other(e));
        }

        Ok(())
    });

    match result {
        Ok(()) => {
            println!("Done! Hooks registered in {}", settings_path.display());
            println!("Events: {}", installer::HOOK_EVENTS.join(", "));
            println!("\nStart Orbit app, then use Claude Code as normal.");
        }
        Err(installer::InstallError::PermissionDenied) => {
            eprintln!("Failed to install Orbit: Permission denied");
            eprintln!("Try running with elevated permissions or use the GUI installer.");
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("Failed to install Orbit: {e}");
            std::process::exit(1);
        }
    }
}

fn cmd_uninstall(force: bool) {
    let settings_path = match installer::get_claude_settings_path() {
        Ok(path) => path,
        Err(e) => {
            eprintln!("Failed to locate Claude settings path: {e}");
            std::process::exit(1)
        }
    };

    let settings_exists = settings_path.exists();
    if !settings_exists {
        println!("No settings file found at {}", settings_path.display());
    }

    let result = installer::with_file_lock(&settings_path, || {
        let current_settings = if settings_exists {
            let settings = installer::read_settings(&settings_path)
                .map_err(|e| installer::InstallError::Other(e))?;
            installer::ensure_settings_object(&settings)
                .map_err(|e| installer::InstallError::Other(e))?;
            settings
        } else {
            Value::Object(Default::default())
        };

        let prepared = installer::prepare_uninstall(current_settings, force)
            .map_err(|e| installer::InstallError::Other(e))?;

        if matches!(prepared.mode, installer::UninstallMode::PreserveDrift) {
            return Ok(prepared);
        }

        let mut settings_to_write = prepared.settings.clone();
        let hook_commands = installer::collect_hook_commands_for_cleanup(prepared.state.as_ref())
            .map_err(|e| installer::InstallError::Other(e))?;
        installer::remove_orbit_hooks(&mut settings_to_write, &hook_commands)
            .map_err(|e| installer::InstallError::Other(e))?;

        if settings_exists {
            installer::write_settings(&settings_path, &settings_to_write)
                .map_err(|e| installer::InstallError::Other(e))?;
        }

        for path in &prepared.files_to_remove {
            installer::remove_file_if_exists(path)
                .map_err(|e| installer::InstallError::Other(e))?;
        }

        Ok(prepared)
    });

    match result {
        Ok(prepared) => {
            if matches!(prepared.mode, installer::UninstallMode::PreserveDrift) {
                println!("Warning: statusLine was modified by user.");
                println!("Original config preserved.");
                println!("Run `orbit-cli uninstall --force` to forcibly clean up Orbit files.");
                return;
            }
            if settings_exists {
                println!("Orbit hooks removed from {}", settings_path.display());
            }
        }
        Err(installer::InstallError::PermissionDenied) => {
            eprintln!("Failed to uninstall Orbit: Permission denied");
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("Failed to uninstall Orbit: {e}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use installer::{
        StatusLineConfig, atomic_write, classify_statusline, ensure_settings_object,
        entry_has_hook_command, generate_install_id, shell_single_quote,
    };
    use serde_json::json;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::{Mutex, MutexGuard};

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct TestHome {
        _guard: MutexGuard<'static, ()>,
        path: PathBuf,
        old_home: Option<String>,
    }

    impl TestHome {
        fn new() -> Self {
            let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let path =
                std::env::temp_dir().join(format!("orbit-cli-home-{}", generate_install_id()));
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

        fn state_path(&self) -> PathBuf {
            self.path.join(".orbit").join("statusline-state.json")
        }

        fn wrapper_path(&self) -> PathBuf {
            self.path.join(".orbit").join("statusline-wrapper.sh")
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

    fn run_install_for_test(
        home: &TestHome,
        initial_settings: serde_json::Value,
    ) -> Result<(), String> {
        let settings_path = home.settings_path();
        if let Some(parent) = settings_path.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        installer::write_settings(&settings_path, &initial_settings)?;

        let orbit_cli = "/opt/orbit-cli".to_string();
        let hook_command = format!("{} hook", orbit_cli);

        installer::with_file_lock(&settings_path, || {
            let current_settings = installer::read_settings(&settings_path)?;
            installer::ensure_settings_object(&current_settings)?;
            let prepared =
                installer::prepare_install(current_settings.clone(), &orbit_cli, &hook_command)?;

            installer::write_wrapper_script(&prepared.wrapper_path, &prepared.wrapper_script)?;
            installer::write_settings(&settings_path, &prepared.settings)?;
            installer::write_statusline_state(&home.state_path(), &prepared.state)?;
            Ok(())
        })
        .map_err(|e: installer::InstallError| e.to_string())
    }

    fn run_uninstall_for_test(home: &TestHome, force: bool) -> Result<(), String> {
        let settings_path = home.settings_path();
        installer::with_file_lock(&settings_path, || {
            let current_settings = installer::read_settings(&settings_path)?;
            installer::ensure_settings_object(&current_settings)?;
            let prepared = installer::prepare_uninstall(current_settings, force)?;
            if matches!(prepared.mode, installer::UninstallMode::PreserveDrift) {
                return Ok(());
            }

            let mut settings_to_write = prepared.settings.clone();
            installer::remove_orbit_hooks(
                &mut settings_to_write,
                &installer::collect_hook_commands_for_cleanup(prepared.state.as_ref())?,
            )?;
            installer::write_settings(&settings_path, &settings_to_write)?;
            for path in &prepared.files_to_remove {
                installer::remove_file_if_exists(path)?;
            }
            Ok(())
        })
        .map_err(|e: installer::InstallError| e.to_string())
    }

    fn managed_command() -> &'static str {
        "/Users/test/.orbit/statusline-wrapper.sh"
    }

    fn settings_with_statusline(statusline: Option<serde_json::Value>) -> serde_json::Value {
        let mut obj = serde_json::Map::new();
        if let Some(statusline) = statusline {
            obj.insert("statusLine".to_string(), statusline);
        }
        serde_json::Value::Object(obj)
    }

    #[test]
    fn classify_statusline_absent() {
        assert_eq!(
            classify_statusline(&json!({}), managed_command()),
            StatusLineConfig::Absent
        );
    }

    #[test]
    fn classify_statusline_standard_command() {
        assert_eq!(
            classify_statusline(
                &settings_with_statusline(Some(
                    json!({"type": "command", "command": "/usr/local/bin/foo"})
                )),
                managed_command(),
            ),
            StatusLineConfig::StandardCommand {
                command: "/usr/local/bin/foo".to_string(),
            }
        );
    }

    #[test]
    fn classify_statusline_rejects_non_object() {
        assert_eq!(
            classify_statusline(
                &settings_with_statusline(Some(json!(true))),
                managed_command()
            ),
            StatusLineConfig::Unsupported
        );
    }

    #[test]
    fn classify_statusline_rejects_missing_command() {
        assert_eq!(
            classify_statusline(
                &settings_with_statusline(Some(json!({"type": "command"}))),
                managed_command(),
            ),
            StatusLineConfig::Unsupported
        );
    }

    #[test]
    fn classify_statusline_detects_orphaned_wrapper() {
        assert_eq!(
            classify_statusline(
                &settings_with_statusline(Some(
                    json!({"type": "command", "command": managed_command()})
                )),
                managed_command(),
            ),
            StatusLineConfig::OrbitOrphaned
        );
    }

    #[test]
    fn ensure_settings_object_fails_for_non_object() {
        assert!(ensure_settings_object(&json!([1, 2, 3])).is_err());
    }

    #[test]
    fn add_orbit_hooks_is_exact_and_idempotent() {
        let mut settings = json!({
            "hooks": {
                "PostToolUse": [
                    {"hooks": [{"type": "command", "command": "/usr/local/bin/orbital-tool hook"}]}
                ]
            }
        });

        installer::add_orbit_hooks(&mut settings, "/opt/orbit-cli hook").unwrap();
        installer::add_orbit_hooks(&mut settings, "/opt/orbit-cli hook").unwrap();

        let post_tool_use = settings
            .get("hooks")
            .and_then(|v| v.get("PostToolUse"))
            .and_then(|v| v.as_array())
            .unwrap();

        let exact_count = post_tool_use
            .iter()
            .filter(|entry| entry_has_hook_command(entry, "/opt/orbit-cli hook"))
            .count();
        assert_eq!(exact_count, 1);
        assert!(
            post_tool_use
                .iter()
                .any(|entry| entry_has_hook_command(entry, "/usr/local/bin/orbital-tool hook"))
        );
    }

    #[test]
    fn remove_orbit_hooks_keeps_non_orbit_strings() {
        let mut settings = json!({
            "hooks": {
                "PostToolUse": [
                    {"hooks": [{"type": "command", "command": "/opt/orbit-cli hook"}]},
                    {"hooks": [{"type": "command", "command": "/usr/local/bin/orbital-tool hook"}]}
                ]
            }
        });

        installer::remove_orbit_hooks(&mut settings, &["/opt/orbit-cli hook".to_string()]).unwrap();

        let post_tool_use = settings
            .get("hooks")
            .and_then(|v| v.get("PostToolUse"))
            .and_then(|v| v.as_array())
            .unwrap();

        assert_eq!(post_tool_use.len(), 1);
        assert!(entry_has_hook_command(
            &post_tool_use[0],
            "/usr/local/bin/orbital-tool hook"
        ));
    }

    #[test]
    fn uninstall_mode_preserves_drift_without_force() {
        let state = installer::StatuslineState {
            original_statusline: None,
            original_was_absent: true,
            managed_command: managed_command().to_string(),
            hook_command: Some("/opt/orbit-cli hook".to_string()),
            install_id: "test".to_string(),
            installed_at: "2026-01-01T00:00:00Z".to_string(),
        };

        assert_eq!(
            installer::evaluate_uninstall_mode(Some("/usr/local/bin/other"), &state, false),
            installer::UninstallMode::PreserveDrift
        );
        assert_eq!(
            installer::evaluate_uninstall_mode(Some("/usr/local/bin/other"), &state, true),
            installer::UninstallMode::ForceCleanup
        );
        assert_eq!(
            installer::evaluate_uninstall_mode(Some(managed_command()), &state, false),
            installer::UninstallMode::RestoreOriginal
        );
    }

    #[test]
    fn render_wrapper_script_is_fail_open() {
        let script = installer::render_wrapper_script(
            "/Applications/Orbit.app/Contents/MacOS/orbit-cli",
            Some("/usr/local/bin/my-statusline --flag"),
        );
        assert!(script.contains("bash -lc \"$ORIGINAL_CMD\""));
        assert!(script.contains("cat 2>/dev/null || true"));
        assert!(!script.contains("set -eo pipefail"));
    }

    #[test]
    fn atomic_write_uses_unique_suffix_and_writes_content() {
        let path =
            std::env::temp_dir().join(format!("orbit-cli-test-{}.json", generate_install_id()));
        atomic_write(&path, br#"{"ok":true}"#).unwrap();
        let content = fs::read_to_string(&path).unwrap();
        assert_eq!(content, r#"{"ok":true}"#);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn shell_single_quote_handles_quotes() {
        assert_eq!(shell_single_quote("foo'bar"), "'foo'\"'\"'bar'");
    }

    #[test]
    fn entry_has_hook_command_requires_exact_match() {
        let entry = json!({
            "hooks": [{"type": "command", "command": "/usr/local/bin/orbital-tool hook"}]
        });
        assert!(entry_has_hook_command(
            &entry,
            "/usr/local/bin/orbital-tool hook"
        ));
        assert!(!entry_has_hook_command(
            &entry,
            "/usr/local/bin/orbit-cli hook"
        ));
    }

    #[test]
    fn install_then_uninstall_restores_original_statusline_and_removes_files() {
        let home = TestHome::new();
        let original_settings = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/original-status --flag"
            }
        });

        run_install_for_test(&home, original_settings.clone()).unwrap();

        let installed = installer::read_settings(&home.settings_path()).unwrap();
        let installed_command = installer::get_statusline_command(&installed)
            .unwrap()
            .to_string();
        assert_eq!(installed_command, home.wrapper_path().to_string_lossy());
        assert!(home.wrapper_path().exists());
        assert!(home.state_path().exists());

        run_uninstall_for_test(&home, false).unwrap();

        let restored = installer::read_settings(&home.settings_path()).unwrap();
        assert_eq!(restored, original_settings);
        assert!(!home.wrapper_path().exists());
        assert!(!home.state_path().exists());
    }

    #[test]
    fn install_then_uninstall_restores_absent_statusline() {
        let home = TestHome::new();
        let original_settings = json!({
            "hooks": {}
        });

        run_install_for_test(&home, original_settings).unwrap();
        let installed = installer::read_settings(&home.settings_path()).unwrap();
        assert_eq!(
            installer::get_statusline_command(&installed).unwrap(),
            home.wrapper_path().to_string_lossy()
        );

        run_uninstall_for_test(&home, false).unwrap();
        let restored = installer::read_settings(&home.settings_path()).unwrap();
        assert!(restored.get("statusLine").is_none());
    }

    #[test]
    fn uninstall_drift_keeps_state_and_wrapper_until_force() {
        let home = TestHome::new();
        let original_settings = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/original-status"
            }
        });

        run_install_for_test(&home, original_settings).unwrap();

        let drifted = json!({
            "statusLine": {
                "type": "command",
                "command": "/usr/local/bin/user-modified"
            }
        });
        installer::write_settings(&home.settings_path(), &drifted).unwrap();

        run_uninstall_for_test(&home, false).unwrap();
        let after_drift_uninstall = installer::read_settings(&home.settings_path()).unwrap();
        assert_eq!(after_drift_uninstall, drifted);
        assert!(home.wrapper_path().exists());
        assert!(home.state_path().exists());

        run_uninstall_for_test(&home, true).unwrap();
        let after_force = installer::read_settings(&home.settings_path()).unwrap();
        assert_eq!(
            after_force,
            json!({
                "statusLine": {
                    "type": "command",
                    "command": "/usr/local/bin/original-status"
                }
            })
        );
        assert!(!home.wrapper_path().exists());
        assert!(!home.state_path().exists());
    }

    #[test]
    fn install_rejects_non_standard_statusline_on_real_filesystem() {
        let home = TestHome::new();
        let settings = json!({
            "statusLine": {
                "type": "builtin",
                "name": "unsupported"
            }
        });

        let err = run_install_for_test(&home, settings).unwrap_err();
        assert!(err.contains("refusing to take over"));
        assert!(!home.wrapper_path().exists());
        assert!(!home.state_path().exists());
    }

    #[test]
    fn install_rejects_non_object_settings_top_level_on_real_filesystem() {
        let home = TestHome::new();
        let settings_path = home.settings_path();
        if let Some(parent) = settings_path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&settings_path, "[]").unwrap();

        let orbit_cli = "/opt/orbit-cli".to_string();
        let hook_command = format!("{} hook", orbit_cli);
        let err = installer::with_file_lock(&settings_path, || {
            let current_settings = installer::read_settings(&settings_path)?;
            installer::ensure_settings_object(&current_settings)?;
            let _ = installer::prepare_install(current_settings, &orbit_cli, &hook_command)?;
            Ok(())
        })
        .map_err(|e: installer::InstallError| e.to_string())
        .unwrap_err();

        assert!(err.contains("top-level value must be a JSON object"));
        assert!(!home.wrapper_path().exists());
        assert!(!home.state_path().exists());
    }
}
