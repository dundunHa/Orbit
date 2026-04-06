# Orbit Backend (Rust/Tauri)

**Parent:** ../AGENTS.md
**Stack:** Rust 2024 edition, Tauri v2

## Overview

Rust backend for Orbit macOS app. Provides Tauri commands, CLI tooling, and macOS-specific integrations via objc2.

## Structure

```
src-tauri/src/
├── lib.rs              # Module re-exports, app entry
├── main.rs             # App binary (calls orbit::run())
├── commands.rs         # Tauri IPC commands
├── state.rs            # AppState, managed state
├── installer.rs        # Claude Code hook installation
├── history.rs          # Session persistence
├── socket_server.rs    # Unix socket for hook events
├── notch.rs            # macOS notch geometry
├── tray.rs             # System tray icon/menu
├── anomaly.rs          # Anomaly detection
├── app/                # Tauri windows/monitors
│   ├── mod.rs
│   ├── onboarding.rs
│   ├── conflict_monitor.rs
│   └── settings.rs
├── bin/                # Additional binaries
│   └── orbit_cli.rs    # CLI tool
└── tests/              # Unit tests
    └── mod.rs
```

## Conventions

### Module Organization
- Flat module structure in `src/`, declared in `lib.rs`
- Subdirectories only for complex subsystems (app/, bin/, tests/)
- Each module has single responsibility

### Tauri Commands
- Define in `commands.rs` with `#[tauri::command]`
- Use `async fn` for I/O-bound operations
- Return `Result<T, String>` for error handling
- Accept `tauri::State<AppState>` for state access
- Use `tauri::AppHandle` for event emission

### Error Handling
- Propagate errors with `?` operator
- Convert to String for command returns: `.map_err(|e| e.to_string())?`
- Use `anyhow` or `thiserror` for complex error types
- Log errors before returning when context matters

### State Management
- `AppState` in `state.rs` is single source of truth
- Use `parking_lot::Mutex` for interior mutability
- Wrap Tauri types in custom structs for testability
- State initialized in `lib.rs::run()`

### macOS-Specific Code
- Guard with `#[cfg(target_os = "macos")]`
- Use `objc2` crates for native API access
- Handle optional features gracefully (fallback when not on macOS)

## Testing

```bash
cargo test              # Run all tests
cargo test -- --nocapture  # Show println! output
cargo test <filter>     # Run specific tests
```

### Test Patterns
- Located in `src/tests/mod.rs`
- Use `#[cfg(test)]` modules for unit tests
- Mock external dependencies when possible
- Test both success and error paths

## Key Dependencies

| Crate | Purpose |
|-------|---------|
| tauri | App framework (v2, macos-private-api, tray-icon) |
| tokio | Async runtime (full features) |
| serde | Serialization |
| chrono | Datetime handling |
| parking_lot | Fast mutexes |
| objc2* | macOS native bindings |

## Commands

```bash
# Build
cargo build
cargo build --release

# Check/Lint
cargo check
cargo clippy -- -D warnings
cargo fmt

# Test
cargo test

# Run
cargo run                    # Run app
cargo run --bin orbit-cli    # Run CLI
```

## Notes

### Binary Targets
- `orbit` (default): Main Tauri app
- `orbit-cli`: CLI tool for hook management

### Feature Flags
- `macos-private-api`: Required for notch detection
- Only enabled on macOS builds

### Unsafe Code
- Minimize `unsafe` blocks
- Concentrate in `notch.rs` for objc2 interop
- Document safety invariants in comments
