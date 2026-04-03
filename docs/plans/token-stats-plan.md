# Token Statistics Feature — Implementation Plan

## Overview
Add token usage tracking to Orbit, displaying tokens per second (TPS) metrics with model-level breakdown.

## Architecture Decision
**Defense-in-depth**: Token data is optional in hook payload. If Claude Code doesn't provide usage data, the feature gracefully degrades (shows "—" instead of metrics).

---

## Files to Modify

### 1. `src-tauri/src/state.rs`

#### Add TokenUsage struct
```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub model: String,
}
```

#### Extend HookPayload
```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HookPayload {
    // ... existing fields ...
    
    #[serde(default)]
    pub usage: Option<TokenUsage>,
}
```

#### Extend Session
```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    // ... existing fields ...
    
    pub tokens_in: u64,
    pub tokens_out: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}

impl Session {
    pub fn new(...) -> Self {
        Self {
            // ... existing init ...
            tokens_in: 0,
            tokens_out: 0,
            model: None,
        }
    }
}
```

#### Update apply_event()
```rust
pub fn apply_event(&mut self, payload: &HookPayload) {
    self.last_event_at = Utc::now();
    
    // Extract token usage if available
    if let Some(usage) = &payload.usage {
        self.tokens_in += usage.input_tokens as u64;
        self.tokens_out += usage.output_tokens as u64;
        self.model = Some(usage.model.clone());
    }
    
    // ... rest of event handling ...
}
```

---

### 2. `src-tauri/src/history.rs`

#### Extend HistoryEntry
```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    // ... existing fields ...
    
    pub tokens_in: u64,
    pub tokens_out: u64,
    pub model: Option<String>,
}
```

#### Update save_entry() in socket_server.rs
```rust
Some(history::HistoryEntry {
    // ... existing fields ...
    tokens_in: session.tokens_in,
    tokens_out: session.tokens_out,
    model: session.model.clone(),
})
```

---

### 3. `src-tauri/src/socket_server.rs`

No changes needed — token extraction happens in Session::apply_event()

---

### 4. `src/main.js` — Frontend Display

#### Calculate TPS
```javascript
function calculateTokensPerSec(session) {
    const duration = (new Date(session.last_event_at) - new Date(session.started_at)) / 1000;
    if (duration <= 0 || session.tokens_out === 0) return null;
    
    return {
        output: Math.round(session.tokens_out / duration),
        total: Math.round((session.tokens_in + session.tokens_out) / duration),
        model: session.model
    };
}
```

#### Update UI
```javascript
function updateUI(session) {
    // ... existing status update ...
    
    const tps = calculateTokensPerSec(session);
    if (tps && isExpanded) {
        detailTokens.textContent = `${tps.output} tok/s out · ${tps.total} tok/s total`;
        detailModel.textContent = tps.model || 'unknown model';
    }
}
```

#### Add to expanded view HTML
```html
<div class="token-stats">
  <span class="token-rate">{{tokensPerSec}} tok/s</span>
  <span class="model-name">{{model}}</span>
  <span class="token-total">{{totalTokens}} tokens</span>
</div>
```

---

### 5. `src/styles.css` — Styling

```css
.token-stats {
    display: flex;
    gap: 12px;
    font-size: 11px;
    color: rgba(255, 255, 255, 0.6);
    margin-top: 8px;
}

.token-rate {
    color: #60a5fa;  /* Blue for processing metric */
    font-weight: 500;
}

.model-name {
    color: rgba(255, 255, 255, 0.4);
}
```

---

## Testing Strategy

### Unit Tests (Rust)

```rust
#[test]
fn test_token_accumulation() {
    let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);
    
    let payload = HookPayload {
        session_id: "test".to_string(),
        hook_event_name: "PostToolUse".to_string(),
        usage: Some(TokenUsage {
            input_tokens: 100,
            output_tokens: 200,
            model: "claude-test".to_string(),
        }),
        // ... other fields ...
    };
    
    session.apply_event(&payload);
    
    assert_eq!(session.tokens_in, 100);
    assert_eq!(session.tokens_out, 200);
    assert_eq!(session.model, Some("claude-test".to_string()));
}

#[test]
fn test_optional_token_usage() {
    let mut session = Session::new("test".to_string(), "/tmp".to_string(), None, None);
    
    let payload = HookPayload {
        session_id: "test".to_string(),
        hook_event_name: "Stop".to_string(),
        usage: None,  // No token data
        // ... other fields ...
    };
    
    session.apply_event(&payload);
    
    // Should not panic, values remain 0
    assert_eq!(session.tokens_in, 0);
    assert_eq!(session.tokens_out, 0);
}
```

### Integration Test

1. Enable Orbit hooks
2. Run Claude Code with a test prompt
3. Check if token stats appear in expanded view
4. Verify history.json contains token fields

---

## Migration Strategy

### History JSON Compatibility

Old history.json entries won't have token fields. Handle gracefully:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    // ... other fields ...
    
    #[serde(default)]
    pub tokens_in: u64,
    #[serde(default)]
    pub tokens_out: u64,
    #[serde(default)]
    pub model: Option<String>,
}
```

The `#[serde(default)]` attribute ensures missing fields deserialize to 0/None.

---

## Verification Steps

### Step 1: Verify Hook Schema

Add temporary debug logging to see actual payload:

```rust
// In socket_server.rs::handle_connection()
eprintln!("Hook payload: {}", buf);  // Temporary debug
```

### Step 2: Check if Usage Data Exists

Look for `usage` field in PostToolUse/Stop events.

### Step 3: If No Data — Document & Defer

If Claude Code doesn't provide token data:
- Keep data structures (forward compatible)
- UI shows "Token stats unavailable" 
- Add TODO to revisit when API supports it

---

## Effort Estimate

| Phase | Human | CC+gstack |
|-------|-------|-----------|
| Data structures | 1h | 5min |
| Backend logic | 2h | 10min |
| Frontend display | 2h | 15min |
| Testing | 2h | 10min |
| **Total** | **7h** | **~40min** |

---

## NOT in Scope

1. **Cost estimation** — Requires pricing API integration, defer to Phase 2
2. **Token usage limits/alerts** — Complex policy system, defer
3. **Aggregate statistics dashboard** — Out of scope for current PR
4. **Third-party model support** — Only Claude Code for now

---

## Open Questions

1. Does Claude Code hook payload include `usage` field? (Requires experiment)
2. If yes — is it on PostToolUse or Stop event?
3. What's the exact schema? (input_tokens vs prompt_tokens?)

**Recommendation**: Implement data structures first, verify with debug logging, then enable UI display once confirmed.

---

## Acceptance Criteria

- [ ] TokenUsage struct with input/output tokens + model
- [ ] Session accumulates token stats across events
- [ ] History persists token data
- [ ] Frontend displays tokens/sec when data available
- [ ] Graceful degradation when no token data
- [ ] Unit tests for accumulation logic
- [ ] Backward compatible with old history.json
