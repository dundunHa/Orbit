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
            let payload = format!("{}\n", input);
            if stream.write_all(payload.as_bytes()).is_err() {
                std::process::exit(0);
            }

            if is_permission_request {
                // Block and wait for the server to return the permission decision.
                // The socket server will emit the permission-request event to the
                // frontend, wait for the user's decision, then write the JSON
                // response back on this connection.
                let mut response = String::new();
                match stream.read_to_string(&mut response) {
                    Ok(_) if !response.trim().is_empty() => {
                        print!("{}", response.trim());
                    }
                    _ => {
                        // Connection closed or read error — fall back to "ask"
                        // so Claude Code shows its own approval prompt.
                        let fallback = serde_json::json!({
                            "hookSpecificOutput": {
                                "hookEventName": "PermissionRequest",
                                "decision": { "behavior": "ask" }
                            }
                        });
                        print!("{}", fallback);
                    }
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
        let current_settings =
            installer::read_settings(&settings_path).map_err(installer::InstallError::Other)?;
        installer::ensure_settings_object(&current_settings)
            .map_err(installer::InstallError::Other)?;

        let prepared =
            installer::prepare_install(current_settings.clone(), &orbit_cli, &hook_command)
                .map_err(installer::InstallError::Other)?;

        installer::write_wrapper_script(&prepared.wrapper_path, &prepared.wrapper_script)
            .map_err(installer::InstallError::Other)?;

        if let Err(e) = installer::write_settings(&settings_path, &prepared.settings) {
            let _ = installer::remove_file_if_exists(&prepared.wrapper_path);
            return Err(installer::InstallError::Other(e));
        }

        let state_path =
            installer::get_statusline_state_path().map_err(installer::InstallError::Other)?;
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
            let settings =
                installer::read_settings(&settings_path).map_err(installer::InstallError::Other)?;
            installer::ensure_settings_object(&settings).map_err(installer::InstallError::Other)?;
            settings
        } else {
            Value::Object(Default::default())
        };

        let prepared = installer::prepare_uninstall(current_settings, force)
            .map_err(installer::InstallError::Other)?;

        if matches!(prepared.mode, installer::UninstallMode::PreserveDrift) {
            return Ok(prepared);
        }

        let mut settings_to_write = prepared.settings.clone();
        let hook_commands = installer::collect_hook_commands_for_cleanup(prepared.state.as_ref())
            .map_err(installer::InstallError::Other)?;
        installer::remove_orbit_hooks(&mut settings_to_write, &hook_commands)
            .map_err(installer::InstallError::Other)?;

        if settings_exists {
            installer::write_settings(&settings_path, &settings_to_write)
                .map_err(installer::InstallError::Other)?;
        }

        for path in &prepared.files_to_remove {
            installer::remove_file_if_exists(path).map_err(installer::InstallError::Other)?;
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
