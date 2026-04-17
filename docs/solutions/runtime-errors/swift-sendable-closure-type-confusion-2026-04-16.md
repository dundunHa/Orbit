---
title: "Swift @Sendable closure type confusion in Task.detached on @unchecked Sendable class"
date: 2026-04-16
category: runtime-errors
module: orbit
problem_type: runtime_error
component: tooling
severity: critical
symptoms:
  - "[UInt8] closure parameters received as 0 or 1 byte of corrupted data instead of full message"
  - "Crash: Unrecognized selector -[Foundation.__DataStorage _fastCStringContents:] on String? parameter"
  - "Data parameters received as 0 bytes through @Sendable closure"
  - "All hook events silently fail — UI shows no sessions"
root_cause: thread_violation
resolution_type: code_fix
tags:
  - swift-concurrency
  - sendable-closure
  - task-detached
  - type-confusion
  - actor-pattern
  - unix-domain-socket
  - message-bridge
related_components:
  - assistant
---

# Swift @Sendable closure type confusion in Task.detached on @unchecked Sendable class

## Problem

Orbit's `SocketServer` through `@Sendable` closure parameters passed from `Task.detached` contexts on an `@unchecked Sendable` class suffered Swift runtime type confusion, causing all closure parameters to be corrupted. This broke the entire hook event pipeline — Claude Code session events sent to `/tmp/orbit.sock` were silently dropped, and the overlay UI showed no sessions.

## Symptoms

- `messageHandler` closure's `[UInt8]` parameter received 0 or 1 byte of `0x00` instead of the full JSON message (e.g., 93 bytes for a SessionStart payload)
- Changing the parameter type to `Data` changed the corruption pattern: 0 bytes instead of 1 byte — confirming the issue is in parameter passing, not the type itself
- Passing data through the `String?` parameter caused a runtime crash: `Unrecognized selector -[Foundation.__DataStorage _fastCStringContents:]` — the runtime treated a `Foundation.__DataStorage` object as a `String`
- All hook events (SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, etc.) failed silently

## What Didn't Work

1. **Pre-copying data before buffer modification** — Tried `Array(buffered[...])` before `removeSubrange` to rule out Copy-on-Write (COW) issues. Still 0 bytes. Conclusion: not a COW problem; the data was correct before the closure call, corruption occurred during parameter passing.

2. **Changing parameter type from `[UInt8]` to `Data`** — Handler received 0 bytes instead of 1 byte. Different corruption pattern, same root cause. Confirmed the issue is in `@Sendable` closure parameter passing, not specific to `[UInt8]`.

3. **Encoding data as String through the meta parameter** — Triggered `_fastCStringContents:` crash. Confirmed BOTH closure parameters (`[UInt8]`/`Data` and `String?`) are subject to the same type confusion — no closure parameter is safe.

4. **First MessageBridge attempt (passing message ID through `String?` meta)** — Created a `MessageBridge` actor to store bytes, passing only the numeric message ID through the `String?` meta parameter. But the meta parameter was ALSO corrupted. Tests showed `nc=1` failures and no handler logs — the handler couldn't even read the message ID to retrieve the stored data.

## Solution

Completely eliminate `@Sendable` closure parameters from data transfer. Replace with a `MessageBridge` actor where data flows exclusively through actor method parameters.

### New MessageBridge Actor

```swift
actor MessageBridge {
    static let shared = MessageBridge()

    private var pending: [UInt64: [UInt8]] = [:]
    private var responseWaiters: [UInt64: CheckedContinuation<Data?, Never>] = [:]
    private var messageWaiters: [CheckedContinuation<(UInt64, [UInt8]), Never>] = []
    private var nextId: UInt64 = 0

    /// SocketServer stores bytes and blocks until processor responds
    func submitAndWait(_ bytes: [UInt8]) async -> Data? {
        let id = nextId
        nextId += 1
        if !messageWaiters.isEmpty {
            let waiter = messageWaiters.removeFirst()
            waiter.resume(returning: (id, bytes))
        } else {
            pending[id] = bytes
        }
        return await withCheckedContinuation { continuation in
            responseWaiters[id] = continuation
        }
    }

    /// Processor retrieves next message (suspends if none available)
    func dequeue() async -> (id: UInt64, bytes: [UInt8]) {
        if let firstKey = pending.keys.sorted().first,
           let bytes = pending.removeValue(forKey: firstKey) {
            return (firstKey, bytes)
        }
        return await withCheckedContinuation { continuation in
            messageWaiters.append(continuation)
        }
    }

    /// Processor delivers the response for a message ID
    func respond(id: UInt64, data: Data?) {
        if let continuation = responseWaiters.removeValue(forKey: id) {
            continuation.resume(returning: data)
        }
    }
}
```

### SocketServer handleClient change

**Before** (corrupted):
```swift
let handler = handlerQueue.sync { _messageHandler }
let response = await handler(bytes, nil)  // ALL parameters type-confused!
```

**After** (fixed):
```swift
let response = await MessageBridge.shared.submitAndWait(bytes)
// Data flows through actor method parameters — no @Sendable closure involved
```

### AppDelegate change

**Before**: Set a `@Sendable` handler closure on SocketServer:
```swift
socketServer.messageHandler = { bytes, meta in
    // bytes is corrupted here — 0 or 1 byte instead of full message
    let data = Data(bytes)
    // ...
}
```

**After**: Start a processor loop that reads from MessageBridge:
```swift
private func startMessageProcessor(hookRouter: HookRouter, viewModel: AppViewModel) {
    let processorTask = Task.detached {
        while !Task.isCancelled {
            let (messageId, bytes) = await MessageBridge.shared.dequeue()
            Task {
                let response = await AppDelegate.processSocketMessage(
                    bytes: bytes, hookRouter: hookRouter, viewModel: viewModel)
                await MessageBridge.shared.respond(id: messageId, data: response)
            }
        }
    }
    startupTasks.append(processorTask)
}
```

Removed from SocketServer: `messageHandler` closure property, `handlerQueue`, `_messageHandler`, and `MessageHandler` typealias.

## Why This Works

The root cause is Swift runtime type metadata corruption when `@Sendable` closure parameters cross isolation boundaries from `Task.detached` on `@unchecked Sendable` classes. The runtime incorrectly interprets the memory layout of closure parameters — `[UInt8]` array's buffer pointer and count are read from wrong offsets, and `String?`'s internal storage object is misidentified as a different type.

The `MessageBridge` actor fix works because:
1. **Actor method parameters use a different call path** — calling `submitAndWait(bytes)` on an actor goes through Swift's actor isolation mechanism, which correctly handles parameter type metadata
2. **`CheckedContinuation` resume values are also safe** — the `dequeue()` return value passes through `CheckedContinuation.resume(returning:)`, which uses the standard concurrency value-passing path
3. **No `@Sendable` closure captures message data** — the problematic code pattern (`@unchecked Sendable` class + `Task.detached` + `@Sendable` closure parameters) is completely eliminated

## Prevention

1. **Avoid `@unchecked Sendable` + `Task.detached` + `@Sendable` closure parameter data passing** — This specific combination triggers the Swift runtime type confusion. Use actor methods or `AsyncStream` for cross-concurrency-boundary data transfer instead.

2. **Prefer actor isolation over closure callbacks** — For producer-consumer patterns across concurrency boundaries, actor method calls are safer than `@Sendable` closures because actor parameter passing goes through the compiler-verified actor isolation path.

3. **Add byte-count assertions on critical data paths** — `assert(bytes.count > 0)` or NSLog after receiving data and before processing catches silent corruption early.

4. **Eliminate `@unchecked Sendable` where possible** — Use proper `actor` types or ensure all state is safely guarded. `@unchecked` disables compiler verification of concurrency safety, making runtime-only bugs like this undetectable at compile time.

5. **Use `AsyncStream` for producer-consumer patterns** — `AsyncStream` provides type-safe cross-concurrency-boundary data transfer without relying on closure parameters.

## Related Issues

- `OrbitTests/SocketServerTests.swift` and `OrbitTests/CLITests.swift` reference the removed `messageHandler` API and need updating
- Files changed: `Orbit/OrbitCore/SocketServer.swift` (MessageBridge actor + simplified handleClient), `Orbit/AppDelegate.swift` (processor loop replaces handler closure)
- Test scripts: `test_hooks.sh` (single-line JSON hook event simulator), `test_permission.py` (PermissionRequest end-to-end test)
