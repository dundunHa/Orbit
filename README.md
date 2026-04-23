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

Browser UI debugging:

```bash
make debug-ui
```

The server starts scanning at port `6666`, skips browser-blocked ports, and
falls forward if a port is busy. Open the URL printed by the command, for
example:

```text
http://127.0.0.1:6670/debug.html
```

This serves the real frontend module with a mocked Tauri bridge, so the Orbit
surface can be expanded and inspected in a normal browser.

For local development, the bridge binary used for Claude Code integration is:

```bash
src-tauri/target/debug/orbit-cli
```

Tauri stages a dev-only `orbit-helper` shim in `src-tauri/binaries/` that forwards to that binary.

## Claude Code integration

Orbit.app installs two things into Claude Code configuration:

1. hook commands pointing at the app bundle's internal helper (`Orbit.app/Contents/MacOS/orbit-helper hook`)
2. a `statusLine` command that points at `~/.orbit/statusline-wrapper.sh`

The wrapper forwards statusline JSON to Orbit and then passes stdin through to the user's original statusline command. The helper is an internal bridge shipped inside Orbit.app; end users do not need a separate CLI install.

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
Open Orbit.app
```

On first launch, Orbit will attempt to connect itself to Claude Code automatically.

Install will:

- add Orbit hook entries for Claude Code events
- write `~/.orbit/statusline-wrapper.sh`
- replace `settings.json.statusLine` with the Orbit wrapper command
- save the original `statusLine` in `~/.orbit/statusline-state.json`

### Uninstall

Use Orbit's app menu to uninstall the integration.

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

Orbit keeps force cleanup as an internal recovery path for drift or orphaned wrapper/state situations.

Force uninstall will:

- remove Orbit hook entries
- restore the saved original `statusLine` when state exists
- remove Orbit-managed wrapper/state files

## Notes and limitations

- Orbit currently assumes a single-user local macOS environment
- Orbit uses file locking around `settings.json` mutations to reduce concurrent write races
- DMG builds bundle the internal helper as a Tauri sidecar before packaging
- wrapper generation is tested both with unit tests and real temporary HOME directories
- the pass-through path uses `bash -lc` for standard command-style statusline entries only

If you rely on a highly custom or non-standard `statusLine` setup, Orbit will refuse takeover instead of guessing.
