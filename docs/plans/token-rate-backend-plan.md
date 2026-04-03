# Token Rate Backend Plan

## Goal

Replace Orbit's hook-only token accounting path with a backend collector that reads Claude Code's local usage data, updates live session metrics, and persists finalized token totals to Orbit history.

## Why this plan exists

The original hook-based plan assumed Claude Code hook payloads would expose `usage`. They do not appear to in normal operation. Orbit's internal token plumbing works, but the upstream data source is wrong.

This plan keeps Orbit's current session lifecycle model and swaps in a better token source.

## Chosen approach

Use a new backend task to poll Claude's local usage cache and merge cumulative token totals into existing in-memory sessions.

- **Primary source:** `/tmp/.claude_usage_cache`
- **Lifecycle owner:** existing hook `socket_server`
- **Persistence point:** existing `SessionEnd -> history.json`
- **Deferred sources:** `~/.claude/stats-cache.json`, telemetry session-end metadata

## Architecture decisions

1. **Do not create sessions from usage cache**
   Only update sessions that already exist in Orbit via hooks. This avoids phantom sessions and keeps one owner for session lifecycle.

2. **Do not accumulate polled totals as deltas**
   Cache values are treated as authoritative cumulative totals. Orbit must overwrite with monotonic protection, not `+=`, or it will double count.

3. **Keep fallbacks out of v1**
   `stats-cache.json` and telemetry are useful for later reconciliation, but they increase ambiguity and blast radius. Ship the primary collector first.

4. **Persist only finalized values**
   History remains final-only. Live values stay in memory until `SessionEnd`.

## What already exists

- `src-tauri/src/lib.rs` already starts long-running background tasks.
- `src-tauri/src/socket_server.rs` already owns session lifecycle and writes history on `SessionEnd`.
- `src-tauri/src/state.rs` already stores `tokens_in`, `tokens_out`, and `model` on each `Session`.
- `src-tauri/src/history.rs` already persists token fields.

This means the minimum viable change is one new collector module plus small edits to existing state/socket startup logic.

## Backend data flow

```text
Claude Code local cache
    |
    | poll every N seconds
    v
usage_collector.rs
    |
    | parse + normalize
    v
UsageSnapshot
    |
    | session_id match only
    v
existing SessionMap
    |
    | emit session-update
    v
frontend live token view

SessionEnd hook
    |
    | best-effort final refresh
    v
history::save_entry(...)
    |
    v
~/.orbit/history.json
```

## Modules to touch

### 1. `src-tauri/src/lib.rs`

Add one more background task startup.

- start `usage_collector::start(...)`
- pass cloned `SessionMap`
- optionally pass `tauri::AppHandle` for `session-update` emission

### 2. `src-tauri/src/state.rs`

Add a small helper for applying authoritative usage snapshots.

Example shape:

```rust
pub struct UsageSnapshot {
    pub session_id: String,
    pub model: Option<String>,
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
}

impl Session {
    pub fn apply_usage_snapshot(&mut self, snapshot: &UsageSnapshot) {
        self.tokens_in = self.tokens_in.max(snapshot.total_input_tokens);
        self.tokens_out = self.tokens_out.max(snapshot.total_output_tokens);
        if self.model.is_none() {
            self.model = snapshot.model.clone();
        }
    }
}
```

Important: keep the old hook-based `usage` path compatible in case Anthropic adds it later, but stop depending on it.

### 3. `src-tauri/src/socket_server.rs`

Small changes only.

- before building `HistoryEntry` on `SessionEnd`, do a best-effort one-shot refresh from the usage collector path
- keep hooks as the lifecycle owner
- do **not** move parsing logic here

### 4. `src-tauri/src/usage_collector.rs` (new)

One small module, no framework.

Responsibilities:

- poll `/tmp/.claude_usage_cache`
- handle file missing / partial writes / malformed JSON safely
- normalize into `UsageSnapshot`
- update matching sessions already present in `SessionMap`
- emit `session-update` when values change

Non-responsibilities:

- do not create sessions
- do not write history directly
- do not scan transcript directories in v1
- do not own fallback reconciliation in v1

## Suggested polling design

```text
loop every 2s
  read /tmp/.claude_usage_cache
  if missing -> continue
  if malformed -> continue
  extract session_id + model + totals
  if no session_id -> continue
  lock SessionMap
  if session exists
    apply monotonic totals
    emit session-update if changed
```

### Poll interval

- **Default:** 2 seconds
- Why: fast enough for a live pill UI, cheap enough for local file reads

### Read strategy

- Read whole file each time
- On parse failure: no-op
- Never zero out tokens because of a bad read

## Data contract for v1

Orbit v1 only cares about these normalized fields:

- `session_id`
- `model`
- `total_input_tokens`
- `total_output_tokens`

Nice-to-have but deferred:

- cache read tokens
- cache creation tokens
- cost
- context window percentage

Reason: keep the first diff focused on live TPS and final history accuracy.

## Token rate formulas

### Live session rate

```text
TPS_out = total_output_tokens / elapsed_wall_seconds
TPS_total = (total_input_tokens + total_output_tokens) / elapsed_wall_seconds
```

### Notes

- `elapsed_wall_seconds` continues to come from Orbit session start/end times
- this is wall-clock rate, not API-only throughput
- API-only throughput can be a later enhancement if we ingest duration fields from a stronger source

## Failure modes

| Failure mode | Handling in v1 | User impact |
|---|---|---|
| cache file missing | skip poll | token UI shows last known value or `—` |
| cache file partially written | skip poll on parse error | brief stale value |
| cache regresses to lower totals | ignore via monotonic max | prevents negative or double-count bugs |
| session_id missing from cache | skip update | no token metrics for that session |
| Orbit starts after Claude session already running | no phantom session creation | existing session only updates after hooks arrive |
| SessionEnd races with last cache refresh | best-effort final refresh before save | possible small undercount |

## Test plan

### Unit tests

Add tests for:

1. parse valid usage cache into `UsageSnapshot`
2. malformed cache read is ignored
3. lower totals do not overwrite higher totals
4. matching session gets updated
5. missing session does not create phantom session
6. SessionEnd save uses latest refreshed totals

### Integration tests

1. simulate session lifecycle with hooks + collector updates + SessionEnd save
2. verify `history.json` receives final token totals
3. verify frontend event emission happens when token totals change

## Phased implementation

### Phase 1

- add `usage_collector.rs`
- wire startup in `lib.rs`
- add snapshot application helper in `state.rs`
- add minimal SessionEnd refresh in `socket_server.rs`
- add tests

### Phase 2

- optionally ingest cache read / cache creation tokens
- optionally show cost / context window
- optionally use `stats-cache.json` for historical reconciliation

### Phase 3

- telemetry session-end reconciliation if v1 shows final undercount in practice

## NOT in scope

- transcript JSONL parsing
  - Too many accuracy questions for the first implementation.
- telemetry continuous ingestion
  - Stronger as an audit/reconciliation path than as a primary live source.
- replacing hooks entirely
  - Hooks still own session lifecycle and permissions.
- historical backfill for past sessions
  - Goal is correct live metrics and future history entries.

## Minimal diff summary

The minimal version should touch only these backend files:

- `src-tauri/src/lib.rs`
- `src-tauri/src/state.rs`
- `src-tauri/src/socket_server.rs`
- `src-tauri/src/usage_collector.rs` (new)
- related tests

That is the smallest change that gets Orbit off the broken assumption that hooks carry usage.
