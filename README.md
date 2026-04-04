# Orbit

Orbit is a macOS Tauri app that watches Claude Code sessions and surfaces status, token usage, and completion state in a Dynamic Island style UI.

## What it does

- listens to Claude Code hook events
- consumes Claude Code statusline JSON for per-session token and cost totals
- shows live session state in the Orbit UI
- preserves a session history for later inspection

## Development

Backend lives in `src-tauri/`.

Common commands:

```bash
cd src-tauri
cargo test
cargo build
cargo build --release
```

The release binary used for Claude Code integration is:

```bash
src-tauri/target/release/orbit-cli
```

## Claude Code integration

Orbit installs two things into Claude Code configuration:

1. hook commands pointing at `orbit-cli hook`
2. a `statusLine` command that points at `~/.orbit/statusline-wrapper.sh`

The wrapper forwards statusline JSON to Orbit and then passes stdin through to the user's original statusline command.

## Safety model for statusline takeover

Orbit is intentionally conservative here. The goal is to avoid breaking a user's existing Claude Code setup.

### Orbit will only auto-take over when `statusLine` is either:

- missing
- exactly a standard command object:

```json
{
  "type": "command",
  "command": "..."
}
```

If `statusLine` is present but not in that shape, Orbit refuses to take it over and exits with a clear error.

### Orbit also refuses to write if:

- `~/.claude/settings.json` parses successfully but its top-level JSON value is not an object
- `settings.json` points at an Orbit wrapper path but Orbit install state is missing
- a previous Orbit install exists and `statusLine` has drifted away from the managed wrapper

### What Orbit preserves

During install, Orbit stores the full original `statusLine` object in:

```text
~/.orbit/statusline-state.json
```

It does not only store the original command string. This is what makes exact restore possible on uninstall.

## Install and uninstall behavior

### Install

```bash
src-tauri/target/release/orbit-cli install
```

Install will:

- add Orbit hook entries for Claude Code events
- write `~/.orbit/statusline-wrapper.sh`
- replace `settings.json.statusLine` with the Orbit wrapper command
- save the original `statusLine` in `~/.orbit/statusline-state.json`

### Uninstall

```bash
src-tauri/target/release/orbit-cli uninstall
```

If Claude Code config still points at the managed Orbit wrapper, uninstall will:

- restore the original `statusLine`
- remove Orbit hook entries
- delete the Orbit wrapper and saved state file

### Drift handling

If the user changes `settings.json.statusLine` after Orbit is installed, Orbit treats that as drift.

In drift mode, plain uninstall is intentionally non-destructive:

- it does **not** overwrite the user's modified `statusLine`
- it does **not** delete `~/.orbit/statusline-state.json`
- it does **not** delete the wrapper file
- it prints a warning and tells the user how to proceed

### Force uninstall

```bash
src-tauri/target/release/orbit-cli uninstall --force
```

Use this when you want Orbit to clean up even after drift or an orphaned wrapper/state situation.

Force uninstall will:

- remove Orbit hook entries
- restore the saved original `statusLine` when state exists
- remove Orbit-managed wrapper/state files

## Notes and limitations

- Orbit currently assumes a single-user local macOS environment
- Orbit uses file locking around `settings.json` mutations to reduce concurrent write races
- wrapper generation is tested both with unit tests and real temporary HOME directories
- the pass-through path uses `bash -lc` for standard command-style statusline entries only

If you rely on a highly custom or non-standard `statusLine` setup, Orbit will refuse takeover instead of guessing.
