# ce:review run 20260419-195215

Scope: tracked working tree diff against `764911760c7ec1ca0887b4f07a2d7d53fa347d34`

Intent: add scenario-driven UI automation, runtime diagnostics, shared accessibility IDs, and layered test plans for Orbit without turning the test platform into a production feature.

Applied fixes:
- Re-activate Orbit after launch and before click-driven UI regression interactions in `OrbitUITests/Support/OrbitUITestCase.swift`.
- Re-routed `OrbitUIRegressionTests` click sites through the shared helper.
- Verified with `xcodebuild test -project Orbit.xcodeproj -scheme Orbit -testPlan OrbitUIRegression -configuration Debug -derivedDataPath /tmp/orbit-dd -only-testing:OrbitUITests/OrbitUIRegressionTests` (`TEST SUCCEEDED`).

Synthesized findings:
1. P1. `Orbit/AppDelegate.swift:31` enters scenario mode as soon as `ORBIT_TEST_SCENARIO_PATH` exists, so an invalid fixture path still disables the normal socket/anomaly/refresh startup path instead of falling back to ordinary app boot.
2. P1. `Orbit/AppDelegate.swift:597` spawns an unbounded `Task` per diagnostics emission; under bursty state changes, writes can arrive out of order and overwrite newer diagnostics with stale snapshots.
3. P1. `OrbitUITests/OrbitUIRegressionTests.swift:4` only verifies the `Allow` permission path end to end; `Deny` and `Continue in terminal` remain smoke-only and can regress silently.
4. P2. `OrbitUITests/OrbitUIRegressionTests.swift:36` still keys the history regression on visible copy (`"more"` / `"Initial UI test scaffolding"`) even though the app now exports stable accessibility identifiers.
5. P2. `OrbitUITests/Support/OrbitUITestCase.swift:5` duplicates app-owned accessibility and diagnostics contracts inside the test target, creating a drift point that compile time cannot catch.
6. P2. `Orbit/OrbitCore/Testing/AppLaunchScenario.swift:83` and `Orbit/AppDelegate.swift:552` still lack negative-path tests for malformed fixtures and diagnostics disable/write-failure behavior.

Requirements completeness (inferred plan):
- R1 met
- R2 met
- R3 partially addressed
- R4 met
- R5 partially addressed
- R6 met
- R7 partially addressed

Learnings:
- `docs/solutions/runtime-errors/swift-sendable-closure-type-confusion-2026-04-16.md` remains the relevant prior solution. This diff does not reintroduce the removed `@Sendable` socket callback path.

Residual risks:
- Collapsed fixtures stay on the test-only suppression path for the whole run, so production-style collapsed-to-expanded wake-up is still not exercised by UI automation.
- `waitForDiagnostics()` keeps a fixed 5 second poll budget; slower machines may still need a centralized timeout knob.
