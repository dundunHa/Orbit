//! Orbit CLI binary
//!
//! This helper binary bridges Claude Code hooks and statusline payloads into Orbit.
//! Install and uninstall flows live in the GUI via the shared installer module.

use serde_json::Value;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;

use orbit::{hook_debug, installer};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HookResponseMode {
    None,
    PermissionRequest,
    Elicitation,
}

#[derive(Debug, Default)]
struct HookDebugContext {
    session_id: Option<String>,
    hook_event_name: Option<String>,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage: orbit-cli <command>");
        eprintln!("Commands:");
        eprintln!("  hook       Internal helper: forward hook event from stdin to Orbit");
        eprintln!("  statusline Internal helper: forward statusline event from stdin to Orbit");
        std::process::exit(1);
    }

    match args[1].as_str() {
        "hook" => cmd_hook(),
        "statusline" => cmd_statusline(),
        _ => {
            eprintln!("Unknown command: {}", args[1]);
            std::process::exit(1);
        }
    }
}

fn cmd_hook() {
    let socket_path = installer::socket_path();
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        std::process::exit(1);
    }

    let input = input.trim();
    if input.is_empty() {
        std::process::exit(0);
    }

    let debug_context = hook_debug_context(input);
    let payload_summary = hook_debug_payload_summary(input);

    hook_debug::append_hook_debug_log(
        "orbit_cli",
        debug_context.session_id.as_deref(),
        debug_context.hook_event_name.as_deref(),
        None,
        "hook-received",
        None,
        Some(payload_summary.as_str()),
    );

    match UnixStream::connect(&socket_path) {
        Ok(mut stream) => {
            if let Some(response) = forward_hook_payload(input, &mut stream) {
                print!("{}", response);
            }
        }
        Err(_) => {
            hook_debug::append_hook_debug_log(
                "orbit_cli",
                debug_context.session_id.as_deref(),
                debug_context.hook_event_name.as_deref(),
                None,
                "socket-connect-failed",
                None,
                Some(payload_summary.as_str()),
            );
            std::process::exit(0);
        }
    }
}

fn forward_hook_payload<S: Read + Write>(input: &str, stream: &mut S) -> Option<String> {
    let payload = format!("{}\n", input);
    let debug_context = hook_debug_context(input);
    let payload_summary = hook_debug_payload_summary(input);
    let response_mode = expected_hook_response(input);

    if stream.write_all(payload.as_bytes()).is_err() {
        hook_debug::append_hook_debug_log(
            "orbit_cli",
            debug_context.session_id.as_deref(),
            debug_context.hook_event_name.as_deref(),
            None,
            "socket-write-failed",
            None,
            Some(payload_summary.as_str()),
        );
        return None;
    }

    let response = match response_mode {
        HookResponseMode::None => None,
        HookResponseMode::PermissionRequest | HookResponseMode::Elicitation => {
            let mut response = String::new();
            match stream.read_to_string(&mut response) {
                Ok(_) => {
                    let trimmed = response.trim();
                    if trimmed.is_empty() {
                        None
                    } else {
                        Some(trimmed.to_string())
                    }
                }
                Err(_) => None,
            }
        }
    };

    let decision = match response_mode {
        HookResponseMode::None => "forward-only",
        HookResponseMode::PermissionRequest | HookResponseMode::Elicitation => {
            if response.is_some() {
                "socket-json-response"
            } else {
                "socket-eof-no-response"
            }
        }
    };

    hook_debug::append_hook_debug_log(
        "orbit_cli",
        debug_context.session_id.as_deref(),
        debug_context.hook_event_name.as_deref(),
        None,
        decision,
        response.as_deref(),
        Some(payload_summary.as_str()),
    );

    response
}

fn hook_debug_context(input: &str) -> HookDebugContext {
    let Ok(value) = serde_json::from_str::<Value>(input) else {
        return HookDebugContext::default();
    };

    HookDebugContext {
        session_id: value
            .get("session_id")
            .or_else(|| value.get("sessionId"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        hook_event_name: value
            .get("hook_event_name")
            .or_else(|| value.get("hookEventName"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
    }
}

fn hook_debug_payload_summary(input: &str) -> String {
    const MAX_CHARS: usize = 2000;
    let mut summary: String = input.chars().take(MAX_CHARS).collect();
    if input.chars().count() > MAX_CHARS {
        summary.push_str("…<truncated>");
    }
    summary
}

fn expected_hook_response(input: &str) -> HookResponseMode {
    serde_json::from_str::<Value>(input)
        .ok()
        .and_then(|val| {
            val.get("hook_event_name")
                .or_else(|| val.get("hookEventName"))
                .and_then(|v| v.as_str())
                .map(|s| match s {
                    "PermissionRequest" => HookResponseMode::PermissionRequest,
                    "Elicitation" => HookResponseMode::Elicitation,
                    _ => HookResponseMode::None,
                })
        })
        .unwrap_or(HookResponseMode::None)
}

fn cmd_statusline() {
    let socket_path = installer::socket_path();
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        std::process::exit(0);
    }

    let input = input.trim();
    if input.is_empty() {
        std::process::exit(0);
    }

    let Some(msg) = build_statusline_message(input) else {
        std::process::exit(0)
    };

    if let Ok(mut stream) = UnixStream::connect(&socket_path) {
        let payload = format!("{}\n", msg);
        let _ = stream.write_all(payload.as_bytes());
    }

    std::process::exit(0);
}

fn build_statusline_message(input: &str) -> Option<String> {
    let Ok(val) = serde_json::from_str::<Value>(input) else {
        return None;
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
    let status = val
        .get("status")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    Some(
        serde_json::json!({
            "type": "StatuslineUpdate",
            "session_id": session_id,
            "tokens_in": tokens_in,
            "tokens_out": tokens_out,
            "cost_usd": cost_usd,
            "model": model,
            "status": status
        })
        .to_string(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::thread;

    #[test]
    fn forward_hook_payload_writes_plain_hook_events() {
        let payload = r#"{"session_id":"session-1","hook_event_name":"SessionStart","cwd":"/tmp"}"#;
        let (mut client, server) = UnixStream::pair().unwrap();

        let server_thread = thread::spawn(move || {
            let mut line = String::new();
            let mut reader = BufReader::new(server);
            reader.read_line(&mut line).unwrap();
            line
        });

        let response = forward_hook_payload(payload, &mut client);
        let received = server_thread.join().unwrap();

        assert!(response.is_none());
        assert_eq!(received.trim(), payload);
    }

    #[test]
    fn forward_hook_payload_returns_permission_response() {
        let payload =
            r#"{"session_id":"session-2","hook_event_name":"PermissionRequest","cwd":"/tmp"}"#;
        let expected = r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#;
        let (mut client, mut server) = UnixStream::pair().unwrap();

        let server_thread = thread::spawn(move || {
            let mut line = String::new();
            {
                let mut reader = BufReader::new(server.try_clone().unwrap());
                reader.read_line(&mut line).unwrap();
            }
            server.write_all(expected.as_bytes()).unwrap();
            line
        });

        let response = forward_hook_payload(payload, &mut client);
        let received = server_thread.join().unwrap();

        assert_eq!(response.as_deref(), Some(expected));
        assert_eq!(received.trim(), payload);
    }

    #[test]
    fn forward_hook_payload_returns_elicitation_response() {
        let payload = r#"{"session_id":"session-elicit","hook_event_name":"Elicitation","cwd":"/tmp","mcp_server_name":"compound","message":"Pick one","mode":"form"}"#;
        let expected = r#"{"hookSpecificOutput":{"hookEventName":"Elicitation","action":"accept","content":{"choice":"plan_a"}}}"#;
        let (mut client, mut server) = UnixStream::pair().unwrap();

        let server_thread = thread::spawn(move || {
            let mut line = String::new();
            {
                let mut reader = BufReader::new(server.try_clone().unwrap());
                reader.read_line(&mut line).unwrap();
            }
            server.write_all(expected.as_bytes()).unwrap();
            line
        });

        let response = forward_hook_payload(payload, &mut client);
        let received = server_thread.join().unwrap();

        assert_eq!(response.as_deref(), Some(expected));
        assert_eq!(received.trim(), payload);
    }

    #[test]
    fn forward_hook_payload_returns_none_when_permission_socket_closes_without_response() {
        let payload =
            r#"{"session_id":"session-3","hook_event_name":"PermissionRequest","cwd":"/tmp"}"#;
        let (mut client, server) = UnixStream::pair().unwrap();

        let server_thread = thread::spawn(move || {
            let mut line = String::new();
            let mut reader = BufReader::new(server);
            reader.read_line(&mut line).unwrap();
            line
        });

        let response = forward_hook_payload(payload, &mut client);
        let received = server_thread.join().unwrap();

        assert_eq!(received.trim(), payload);
        assert!(response.is_none());
    }

    #[test]
    fn forward_hook_payload_returns_none_when_elicitation_socket_closes_without_response() {
        let payload = r#"{"session_id":"session-elicit-2","hook_event_name":"Elicitation","cwd":"/tmp","mcp_server_name":"compound","message":"Pick one","mode":"form"}"#;
        let (mut client, server) = UnixStream::pair().unwrap();

        let server_thread = thread::spawn(move || {
            let mut line = String::new();
            let mut reader = BufReader::new(server);
            reader.read_line(&mut line).unwrap();
            line
        });

        let response = forward_hook_payload(payload, &mut client);
        let received = server_thread.join().unwrap();

        assert_eq!(received.trim(), payload);
        assert!(response.is_none());
    }

    #[test]
    fn expected_hook_response_forwards_elicitation_result_without_waiting() {
        let payload = r#"{"session_id":"session-elicit-3","hook_event_name":"ElicitationResult","cwd":"/tmp"}"#;

        assert_eq!(expected_hook_response(payload), HookResponseMode::None);
    }

    #[test]
    fn build_statusline_message_transforms_claude_payload() {
        let payload = r#"{"session_id":"session-4","status":"Stewing","context_window":{"total_input_tokens":123,"total_output_tokens":456},"cost":{"total_cost_usd":0.78},"model":{"id":"claude-sonnet-4-20250514"}}"#;

        let msg = build_statusline_message(payload).unwrap();
        let forwarded: Value = serde_json::from_str(&msg).unwrap();

        assert_eq!(forwarded["type"], "StatuslineUpdate");
        assert_eq!(forwarded["session_id"], "session-4");
        assert_eq!(forwarded["tokens_in"], 123);
        assert_eq!(forwarded["tokens_out"], 456);
        assert_eq!(forwarded["cost_usd"], 0.78);
        assert_eq!(forwarded["model"], "claude-sonnet-4-20250514");
        assert_eq!(forwarded["status"], "Stewing");
    }
}
