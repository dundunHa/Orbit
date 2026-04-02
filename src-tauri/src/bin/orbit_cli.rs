use serde_json::Value;
use std::io::{self, Read};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

const SOCKET_PATH: &str = "/tmp/orbit.sock";

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage: orbit-cli <command>");
        eprintln!("Commands:");
        eprintln!("  hook      Forward hook event from stdin to Orbit app");
        eprintln!("  install   Configure Claude Code hooks for Orbit");
        eprintln!("  uninstall Remove Orbit hooks from Claude Code settings");
        std::process::exit(1);
    }

    match args[1].as_str() {
        "hook" => cmd_hook(),
        "install" => cmd_install(),
        "uninstall" => cmd_uninstall(),
        _ => {
            eprintln!("Unknown command: {}", args[1]);
            std::process::exit(1);
        }
    }
}

fn cmd_hook() {
    // Read JSON from stdin
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        std::process::exit(1);
    }

    let input = input.trim();
    if input.is_empty() {
        std::process::exit(0);
    }

    // Connect to Orbit socket and send the payload
    match UnixStream::connect(SOCKET_PATH) {
        Ok(mut stream) => {
            use std::io::Write;
            let payload = format!("{}\n", input);
            if stream.write_all(payload.as_bytes()).is_err() {
                // Orbit not running, silently exit
                std::process::exit(0);
            }

            // For PermissionRequest, read response
            let parsed: Result<Value, _> = serde_json::from_str(input);
            if let Ok(val) = parsed {
                if val.get("hook_event_name").and_then(|v| v.as_str()) == Some("PermissionRequest")
                {
                    // Wait for response from Orbit
                    use std::io::Read;
                    let mut response = String::new();
                    let _ = stream.read_to_string(&mut response);
                    if !response.is_empty() {
                        // Print response to stdout (Claude Code reads this)
                        print!("{}", response);
                    }
                }
            }
        }
        Err(_) => {
            // Orbit not running, silently exit
            std::process::exit(0);
        }
    }
}

fn cmd_install() {
    let settings_path = get_claude_settings_path();
    println!("Installing Orbit hooks...");

    // Read existing settings
    let mut settings: Value = if settings_path.exists() {
        let content = std::fs::read_to_string(&settings_path).unwrap_or_else(|_| "{}".to_string());
        serde_json::from_str(&content).unwrap_or(Value::Object(Default::default()))
    } else {
        Value::Object(Default::default())
    };

    // Get orbit-cli path (current binary)
    let orbit_cli = std::env::current_exe()
        .unwrap_or_else(|_| PathBuf::from("orbit-cli"))
        .to_string_lossy()
        .to_string();

    let hook_command = format!("{} hook", orbit_cli);

    // Events to hook
    let events = [
        "PreToolUse",
        "PostToolUse",
        "Stop",
        "SessionStart",
        "SessionEnd",
        "PermissionRequest",
        "Notification",
        "UserPromptSubmit",
        "SubagentStop",
        "PreCompact",
    ];

    // Build hooks config
    let hooks_obj = settings
        .as_object_mut()
        .unwrap()
        .entry("hooks")
        .or_insert_with(|| Value::Object(Default::default()));

    let hooks = hooks_obj.as_object_mut().unwrap();

    for event in &events {
        let event_hooks = hooks
            .entry(event.to_string())
            .or_insert_with(|| Value::Array(vec![]));

        let arr = event_hooks.as_array_mut().unwrap();

        // Check if orbit hook already registered
        let already_registered = arr.iter().any(|entry| {
            entry
                .get("hooks")
                .and_then(|h| h.as_array())
                .map(|hooks| {
                    hooks.iter().any(|h| {
                        h.get("command")
                            .and_then(|c| c.as_str())
                            .map(|c| c.contains("orbit"))
                            .unwrap_or(false)
                    })
                })
                .unwrap_or(false)
        });

        if !already_registered {
            let hook_entry = serde_json::json!({
                "hooks": [{
                    "type": "command",
                    "command": hook_command
                }]
            });
            arr.push(hook_entry);
        }
    }

    // Write back
    if let Some(parent) = settings_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let pretty = serde_json::to_string_pretty(&settings).unwrap();
    std::fs::write(&settings_path, pretty).expect("Failed to write settings");

    println!("Done! Hooks registered in {}", settings_path.display());
    println!("Events: {}", events.join(", "));
    println!("\nStart Orbit app, then use Claude Code as normal.");
}

fn cmd_uninstall() {
    let settings_path = get_claude_settings_path();

    if !settings_path.exists() {
        println!("No settings file found at {}", settings_path.display());
        return;
    }

    let content = std::fs::read_to_string(&settings_path).unwrap_or_else(|_| "{}".to_string());
    let mut settings: Value =
        serde_json::from_str(&content).unwrap_or(Value::Object(Default::default()));

    if let Some(hooks) = settings.get_mut("hooks").and_then(|h| h.as_object_mut()) {
        for (_event, entries) in hooks.iter_mut() {
            if let Some(arr) = entries.as_array_mut() {
                arr.retain(|entry| {
                    !entry
                        .get("hooks")
                        .and_then(|h| h.as_array())
                        .map(|hooks| {
                            hooks.iter().any(|h| {
                                h.get("command")
                                    .and_then(|c| c.as_str())
                                    .map(|c| c.contains("orbit"))
                                    .unwrap_or(false)
                            })
                        })
                        .unwrap_or(false)
                });
            }
        }

        // Remove empty event arrays
        hooks.retain(|_, v| {
            v.as_array().map(|a| !a.is_empty()).unwrap_or(true)
        });
    }

    let pretty = serde_json::to_string_pretty(&settings).unwrap();
    std::fs::write(&settings_path, pretty).expect("Failed to write settings");

    println!("Orbit hooks removed from {}", settings_path.display());
}

fn get_claude_settings_path() -> PathBuf {
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join(".claude").join("settings.json")
}
