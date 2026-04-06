# Orbit Knowledge Base

**Generated:** 2026-04-06
**Project:** Orbit - macOS Tauri app for Claude Code session monitoring

## Skill Routing

When the user's request matches an available skill, **ALWAYS invoke it using the Skill tool as your FIRST action.**

| Request Type | Invoke Skill |
|-------------|--------------|
| Product ideas, brainstorming | office-hours |
| Bugs, errors, 500 errors | investigate |
| Ship, deploy, create PR | ship |
| QA, test the site | qa |
| Code review | review |
| Update docs after shipping | document-release |
| Weekly retro | retro |
| Design system | design-consultation |
| Visual polish | design-review |
| Architecture review | plan-eng-review |

## Overview

Orbit is a macOS Tauri app that watches Claude Code sessions via hooks, surfaces status/token usage in a Dynamic Island-style UI, and maintains session history.

**Stack:**
- Backend: Rust (Tauri v2)
- Frontend: Vanilla JavaScript (ES modules), no frameworks
- Platform: macOS only (uses macOS Private API)

## Structure

```
Orbit/
├── src/                    # Frontend (HTML/JS/CSS)
│   ├── components/         # SessionTree component
│   ├── constants/          # App constants
│   ├── data/              # Static data
│   ├── types/             # TypeScript definitions
│   └── utils/             # Utility functions
├── src-tauri/             # Rust backend
│   └── src/
│       ├── app/           # UI dialogs (onboarding, permission)
│       ├── bin/           # orbit-cli binary
│       └── tests/         # Unit tests
├── docs/                  # Documentation
├── .claude/               # Claude Code integration config
└── .opencode/             # OpenCode plugin
```

## Where to Look

| Task | Location | Notes |
|------|----------|-------|
| Add Tauri command | src-tauri/src/commands.rs | All IPC commands defined here |
| Modify UI | src/index.html, src/main.js | Vanilla JS, no framework |
| Add CLI command | src-tauri/src/bin/orbit_cli.rs | CLI entry point |
| Change settings | src-tauri/src/state.rs | App state management |
| History logic | src-tauri/src/history.rs | Session persistence |
| Tests | src-tauri/src/tests/mod.rs | Rust unit tests |
| Installer | src-tauri/src/installer.rs | Claude Code integration |

## Conventions

### Rust Backend
- Module structure: flat in `src/`, re-exported in `lib.rs`
- Commands: async functions in `commands.rs`, use `#[tauri::command]`
- Error handling: propagate errors, use `Result<T, String>` for commands
- State: managed via `tauri::State<AppState>`

### JavaScript Frontend
- ES6 modules, no bundler (Tauri serves directly)
- Tauri IPC: `invoke('command_name', args)`
- Event listening: `listen('event_name', handler)`
- Naming: camelCase for functions/variables, kebab-case for files

### Formatting
- Rust: `cargo fmt` + `cargo clippy -- -D warnings`
- JS: Prettier (default config)
- Warnings treated as errors in CI

## Anti-Patterns (Hard Rules)

### From CLAUDE.md (Eight Virtues)
- **Never guess interfaces** — always query seriously
- **Never fuzzy execute** — seek confirmation
- **Never imagine business logic** — confirm with humans
- **Never create interfaces** — reuse existing ones
- **Never pass once** — double-check your work
- **Never destroy architecture** — follow norms
- **Never pretend to understand** — admit ignorance honestly
- **Never modify blindly** — refactor cautiously

### Tool Usage
- **NEVER use built-in webfetch** — use `/browse` skill instead
- Always respond in Chinese-simplified (per CLAUDE.md)

### Safety Model (Critical)
- **Conservative statusline takeover** — only if missing or standard format
- **Preserve original** — store full original in `~/.orbit/statusline-state.json`
- **No guessing** — refuse takeover for custom/non-standard setups
- **Drift handling** — non-destructive uninstall if user modified config

## Commands

```bash
# Development
cd src-tauri && cargo build              # Debug build
cd src-tauri && cargo build --release    # Release build
cd src-tauri && cargo test               # Run tests

# Formatting
make fmt                                 # Format Rust (rustfmt + clippy)
make ffmt                                # Format frontend (Prettier)

# CLI
src-tauri/target/release/orbit-cli install       # Install hooks
src-tauri/target/release/orbit-cli uninstall     # Uninstall hooks
src-tauri/target/release/orbit-cli uninstall --force  # Force cleanup
```

## Notes

### macOS Only
- Uses `macos-private-api` Tauri feature
- Depends on `objc2` crates for native macOS APIs
- Not portable to other platforms

### Session History Backward Compatibility
- New fields use `#[serde(default)]` for backward compatibility
- Graceful degradation if token stats missing (shows "—")

### File Locking
- Uses `parking_lot` for state locking
- File locking around `~/.claude/settings.json` mutations

### Entry Points
- App: `src-tauri/src/main.rs` → `orbit::run()`
- CLI: `src-tauri/src/bin/orbit_cli.rs`
- Frontend: `src/index.html` (loaded by Tauri)

### Dependencies
See `src-tauri/Cargo.toml` for full list. Key ones:
- Tauri v2 with tray-icon + macos-private-api
- tokio (async runtime)
- serde (serialization)
- chrono (datetime)
- objc2-* (macOS bindings)
