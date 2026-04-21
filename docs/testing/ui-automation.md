# Orbit UI Automation And Diagnostics

## 目的

本文档定义 Orbit UI 自动化场景文件与 diagnostics 证据链的约定，供后续 `OrbitUITests`、本地排障和 reviewer 复测共用。这里约定的是测试 contract，不改变 release 路径。

当前约定只覆盖场景注入与验证文档子集：

- `ORBIT_TEST_SCENARIO_PATH` 指向单个 JSON fixture，用于在 app 启动时注入稳定初始状态。
- `ORBIT_TEST_DIAGNOSTICS_PATH` 指向 DEBUG diagnostics JSON 输出位置，用于 UI test 等待状态和失败留证。
- `ORBIT_HOOK_DEBUG_LOG_PATH` 继续作为 hook JSONL 审计通道，不替代 runtime diagnostics。

启动边界约束：

- 只有当 `ORBIT_TEST_SCENARIO_PATH` 指向的 fixture 成功读取、解码并通过 schema 校验后，app 才进入 scenario mode。
- 路径缺失、文件不存在、schema version 不支持或 seed 校验失败时，都只记录可诊断错误，不改变正常启动分支、temp-path 选择或 store wiring。

## Fixture 命名与用途

fixture 使用 `kebab-case`，名称直接对应“首帧主场景”，不要把实现细节塞进文件名。

- `idle.json`
  用于最小 smoke 场景，验证 app 可启动且 overlay 保持 pill-only。
- `pending-permission.json`
  用于 permission pending 场景，验证 expanded permission UI、按钮存在性和 decision 后状态流转。
- `onboarding-drift.json`
  用于 onboarding drift 场景，验证 onboarding 卡片和 retry 入口。
- `active-and-history.json`
  用于 active sessions + recent history 场景，验证 session tree、recent 列表和分页入口。

命名约束：

- 一个 fixture 只表达一个主场景，不把多个相互竞争的 UI 根状态混在同一个首帧里。
- 如果需要覆盖交互后的状态，优先复用已有 fixture 并依赖 diagnostics/assertion 判断，不为每个按钮结果单独再造首帧 fixture。
- 允许在 `expected` 中放辅助断言元数据，但 app loader 只消费 `seed`。

## Fixture Schema

四个 fixture 共享同一顶层结构：

```json
{
  "schema_version": 1,
  "fixture_name": "pending-permission",
  "description": "Expanded permission prompt with one live session.",
  "seed": {
    "sessions": [],
    "history_entries": [],
    "selected_session_id": null,
    "onboarding_state": {
      "type": "Connected",
      "detail": null
    },
    "pending_interaction": null,
    "today_stats": {
      "date": 20260419,
      "tokens_in": 0,
      "tokens_out": 0,
      "session_baselines": {}
    },
    "overlay": {
      "initial_intent": "expanded"
    }
  },
  "expected": {
    "ui": {},
    "diagnostics": {}
  }
}
```

字段约定：

- `schema_version`
  场景 schema 版本。未来只做显式升版，不做 silent drift。
- `fixture_name`
  稳定 fixture 标识。推荐与文件名去掉扩展名后的值一致。
- `description`
  给人看的场景说明，简短描述首帧状态。
- `seed.sessions`
  使用 `Session` 当前编码格式，尽量沿用现模型字段：
  `id`、`cwd`、`has_spawned_subagent`、`parent_session_id`、`status`、`started_at`、`last_event_at`、`tool_count`、`pid`、`tty`、`title`、`title_source`、`tokens_in`、`tokens_out`、`cost_usd`、`model`。
- `seed.history_entries`
  使用 `HistoryEntry` 当前编码格式：
  `session_id`、`parent_session_id`、`cwd`、`started_at`、`ended_at`、`tool_count`、`duration_secs`、`title`、`tokens_in`、`tokens_out`、`cost_usd`、`model`、`tty`。
- `seed.selected_session_id`
  对应 `AppViewModel.selectedSessionId`。留空时允许 app 按现有优先级自动选择 active session。
- `seed.onboarding_state`
  用于表达 `OnboardingState`，约定 `type` 为：
  `Welcome`、`Checking`、`Installing`、`Connected`、`ConflictDetected`、`PermissionDenied`、`DriftDetected`、`Error`。
  只有 `ConflictDetected` 和 `Error` 允许使用 `detail`。
- `seed.pending_interaction`
  对应 `PendingInteraction` 的测试态表示，字段使用 snake_case：
  `id`、`kind`、`session_id`、`tool_name`、`tool_input`、`message`、`requested_schema`、`permission_suggestions`。
- `seed.today_stats`
  使用 `TodayTokenStats` 当前编码格式：
  `date`、`tokens_in`、`tokens_out`、`session_baselines`。
  `out_rate`、`last_rate_sample_ts`、`last_rate_sample_out` 不属于持久化输入 schema。
- `seed.overlay.initial_intent`
  当前只允许 `collapsed` 或 `expanded`，表示首帧期望的 overlay 意图，不承诺动画细节。
- `expected.ui`
  供 UI harness 和 reviewer 使用的可见行为断言摘要，不作为 app 注入输入。
- `expected.diagnostics`
  供 diagnostics 对照的期望摘要，不要求与最终 exporter 完全一比一镜像，但字段语义要稳定。

设计原则：

- 优先贴合现有模型编码，而不是重新发明测试专用字段。
- `seed` 只描述启动时可稳定注入的状态，不编码点击后的结果。
- `expected` 只放高价值断言摘要，避免把整份 diagnostics JSON 镜像一遍。

## Diagnostics JSON 的预期用途

`ORBIT_TEST_DIAGNOSTICS_PATH` 导出的 JSON 不是为了替代 UI 断言，而是为了给 UI 自动化提供稳定等待条件和失败证据。

writer contract 约束：

- diagnostics exporter 通过单通道 writer 提交快照，磁盘上的 JSON 以最新接受的 revision 为准，不允许旧快照晚到后覆盖新状态。
- diagnostics disabled 时提交必须是安全 no-op。
- 临时写盘失败只影响该次提交；后续合法提交仍然必须可恢复。

预期至少覆盖这些语义：

- `overlay`
  `phase`、`want_expanded`、`is_expanded`、`is_animating` 之类的 overlay 摘要，用于等待 expanded/collapsed 收敛。
- `pending_interaction`
  当前 request 是否存在、`id`/`kind`/`tool_name` 是什么，用于验证 permission/elicitation 是否清理。
- `counts`
  `sessions`、`history_entries` 数量，用于快速确认 seed 是否生效。
- `selected_session_id`
  用于确认 session tree 高亮或默认选择没有漂移。
- `onboarding`
  建议直接导出 `OnboardingStatePayload` 语义：
  `type`、`status_text`、`tray_status`、`needs_attention`、`is_complete`、`can_retry`。
- `recent_decision`
  permission allow/deny/passthrough 等最近一次交互结果摘要。
- `scenario`
  建议记录 fixture 名称、schema version、加载是否成功和错误信息。
- `hook`
  最近一次 hook 处理摘要，必要时关联 `HookDebugLogger` 的 JSONL 记录。

diagnostics JSON 的推荐用途：

- UI test 在点击后轮询 diagnostics，而不是写裸 `sleep`。
- 失败时把 diagnostics 作为截图旁边的第二证据，解释“为什么 UI 是现在这样”。
- 交叉验证 UI 和内部状态，避免“UI 看起来像成功，但内部 pending 还没清掉”的假绿。
- 诊断 flake 时快速分辨是场景未注入、overlay 未收敛，还是交互回调没落地。

## 三层验证策略

### Smoke

目标是最快确认 launch、fixture 注入和主要根节点没有坏掉。每次本地改动优先跑这一层。

- `idle.json`
  只确认 pill-only 首帧和 diagnostics 可读。
- `pending-permission.json`
  只确认 permission UI 出现、主要按钮存在。
- `onboarding-drift.json`
  只确认 onboarding drift 卡片和 retry 按钮存在。
- `active-and-history.json`
  只确认 active/recent 两块都渲染，history 数量与 fixture 一致。

Smoke 只做高价值存在性断言，不展开复杂交互。

### Regression

目标是验证主要用户路径的状态转移。建议在较大 UI 改动、提 PR 前或准备合并前跑。

- permission 场景点击 `Allow` / `Deny` / `Continue in terminal` 后：
  UI 收起或切换到预期状态，diagnostics 中 `pending_interaction` 被清空，并记录最近 decision。
- onboarding drift 场景点击 `Retry` 后：
  diagnostics 至少能反映 retry 已触发；是否真正修复由测试 responder 或后续逻辑决定。
- active-and-history 场景：
  校验 selected session 呈现，history 超过默认页大小时通过共享 accessibility ID 定位 `load more` 按钮和 row，展开后数量增加。

Regression 仍然应该避免固定时间等待，优先依赖 `waitForExistence` 和 diagnostics 轮询。

### Diagnostics

目标不是“多跑一遍 UI test”，而是为 flaky、CI 失败或本地疑难问题保留更完整证据。

- 强制写出 diagnostics JSON。
- 保留截图附件。
- 保留 `ORBIT_HOOK_DEBUG_LOG_PATH` 对应的 JSONL。
- 结合统一日志和 signpost 时间线查看 `launch`、`scenario`、`overlay`、`hook`、`ui-test` 等 category。

Diagnostics 层适合在这些情况使用：

- 同一个 fixture 偶发失败，怀疑是 overlay 收敛、动画时序或 responder 生命周期问题。
- UI 和内部状态不一致，需要判断是视图渲染问题还是状态机问题。
- CI 失败时需要最少二类以上证据来复盘。

## 失败取证步骤

推荐按下面顺序排查，同一轮排查尽量保留同一个 fixture 的所有证据。

1. 确认测试实际使用的 fixture 名称和 `ORBIT_TEST_SCENARIO_PATH`。
2. 打开失败截图，先判断根视图类型是 pill、permission、onboarding 还是 expanded active/history。
3. 检查 diagnostics JSON：
   `scenario` 是否加载成功、`overlay` 是否收敛、`pending_interaction` 是否清空、`counts` 是否与 fixture 一致。
4. 检查 `ORBIT_HOOK_DEBUG_LOG_PATH` 对应 JSONL：
   看有没有 request/decision 对不上、request id 漂移、hook response 缺失。
5. 查看统一日志 / signpost：
   重点关注 `launch`、`scenario`、`overlay`、`hook`、`ui-test` 这几类事件是否有明显断点。
6. 如果 diagnostics 与截图矛盾：
   优先怀疑 UI contract 或 render 时序，再回看交互后的等待条件是不是只等了按钮消失、却没等 overlay 真正收敛。

建议把同一次失败的以下文件归档到同一个工件目录：

- 截图
- diagnostics JSON
- hook JSONL
- 对应 fixture 副本或 fixture 名称

## 仍需人工复核的点

自动化能证明状态是否对、控件是否存在、交互后 diagnostics 是否收敛，但以下内容仍要人工看：

- hover、pressed、focus ring 等细节状态是否符合预期
- animation 的平滑度、节奏、闪烁和过渡是否自然
- overlay 的窗口位置、notch 对齐、跨屏和 Spaces 切换行为
- 模糊材质、颜色层次、阴影和文字截断是否退化
- VoiceOver/键盘导航体验是否仍然合理

这些点不能只靠 diagnostics JSON 下结论，必须结合真实 UI 观察。

## 推荐运行入口

仓库现在提供共享 `Orbit.xcscheme` 和三套 test plan：

- `Orbit`
  默认日常回归。包含 `OrbitTests` 全量逻辑测试，以及 `OrbitUITests` 的 smoke 子集。
- `OrbitUIRegression`
  只跑 UI 自动化，覆盖 smoke + regression 两层，适合提 PR 前验证交互状态流转。
- `OrbitUIDiagnostics`
  跑 `OrbitTests` + `OrbitUITests` 全量，并开启 `OS_ACTIVITY_DT_MODE=1` 与 code coverage，适合 flaky 和失败复盘。

推荐命令：

```bash
xcodebuild test -project Orbit.xcodeproj -scheme Orbit -testPlan Orbit -derivedDataPath /tmp/orbit-dd
xcodebuild test -project Orbit.xcodeproj -scheme Orbit -testPlan OrbitUIRegression -derivedDataPath /tmp/orbit-dd
xcodebuild test -project Orbit.xcodeproj -scheme Orbit -testPlan OrbitUIDiagnostics -derivedDataPath /tmp/orbit-dd
```

说明：

- 本地快速看反馈，先跑 `Orbit`。
- 要验证 overlay / permission / onboarding / history 的可见交互，跑 `OrbitUIRegression`。
- 要拿完整证据链，跑 `OrbitUIDiagnostics` 并保留 `.xcresult`、diagnostics JSON 与 hook JSONL。
- 只要 test plan 里包含 `OrbitUITests`，就不要再配 `CODE_SIGNING_ALLOWED=NO`。macOS UI test runner 需要可签名、可通过 Gatekeeper 启动的产物。
- 项目位于 Dropbox / CloudStorage 下时，不要把 `DerivedData` 放回仓库目录。`.build/DerivedData` 这类路径可能带上 Finder / FileProvider 扩展属性，导致 codesign 失败；`/tmp/orbit-dd` 这类非同步目录更稳定。
- 如果只跑 `OrbitTests` 的纯逻辑子集，仍然可以单独使用 repo-local `DerivedData` 和 `CODE_SIGNING_ALLOWED=NO` 提高反馈速度。

## 维护约束

- 新增 fixture 时先复用本文 schema，不要重新发明顶层结构。
- 只有在 loader/exporter 需要变化时才升级 `schema_version`。
- 如果 model 编码发生变化，优先更新 fixture 与文档，再扩展 UI harness。
- fixture 资产和 diagnostics contract 的演进要保持一一对应，避免文档、fixture、UI harness 三方漂移。
- `OrbitAccessibilityID.swift` 与 `OrbitRuntimeDiagnostics.swift` 是 app-owned shared contract；`OrbitUITests` 直接编译这些源文件，不在 test target 内重写镜像定义。
- UI tests 里一律通过 `ScenarioFixture.resourceURL()` 解析 fixture，不要假设 bundle 内一定保留 `Fixtures/` 子目录。Xcode 可能把 JSON 直接扁平复制到 test bundle root。
