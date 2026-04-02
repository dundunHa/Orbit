# Orbit — TODOS

## P1 — 本轮实施 (eng review 决议)

### IMPL-01: notch.rs 坐标修复
- y=0, 统一 Logical 坐标 (移除 backingScaleFactor 乘法)
- safeAreaInsets.top=0 时回退 28pt
- get_notch_position() 返回 (x, y, notch_height, screen_width)
- 文件: notch.rs, lib.rs, commands.rs

### IMPL-02: commands.rs 动态尺寸
- 窗口宽 320px, 每次 expand/collapse 重新查询屏幕尺寸
- 文件: commands.rs, tauri.conf.json

### IMPL-03: styles.css 刘海融合
- 背景 #000000 (非 rgba), 仅底部圆角
- 动态宽度 180-260px (CSS transition)
- 文件: styles.css

### IMPL-04: main.js 弹性展开 + 完成闪烁
- 宽度先变 0.2s, 高度 0.35s spring 动画
- Stop 事件触发绿色闪烁
- 文件: main.js, styles.css

### IMPL-05: 权限 Map 修复
- currentPermId → Map<sessionId, permId>
- 权限 UI 显示所有待审批 session
- 文件: main.js

### IMPL-06: 动画锁
- isAnimating flag, transitionend 解锁
- 防止快速连续点击导致窗口卡住
- 文件: main.js

### IMPL-07: 连接状态追踪
- 后端: socket 连接计数 / heartbeat
- 前端: 断连状态 UI (灰色脉冲)
- 文件: socket_server.rs, state.rs, main.js, styles.css

## P1 — QA Deferred Bugs

### ~~BUG-05: camelCase→snake_case implicit mapping~~ ✅ Fixed
JS 端 `permId` → `perm_id`，不再依赖 Tauri 隐式转换。

### ~~BUG-13: history.json 并发写入无文件锁~~ ✅ Fixed
history.rs 加 `static HISTORY_LOCK: Mutex<()>` 保护 read-modify-write。

## P1 — Review Bugs (对抗性审查发现)

### ~~REVIEW-01: "ask" 权限路径无 JSON 响应~~ ✅ Fixed
socket_server.rs "ask" 分支现在写入合法 `{"behavior":"ask"}` JSON。

### ~~REVIEW-03: 权限超时前端无通知~~ ✅ Fixed
超时时 emit `permission-timeout` 事件，前端清理 stale UI。

### ~~REVIEW-04: save_entry 在 async 锁内执行同步 IO~~ ✅ Fixed
history entry 在锁内准备，锁外写入。

### ~~REVIEW-08: connection count u32 下溢~~ ✅ Fixed
fetch_sub 前检查 prev > 0，防止 wrapping subtract。

## P2 — Phase 2（开源前）

### anomaly.rs 改为直接传参
anomaly::start 应接收 `SessionMap` 参数而非 `try_state` 动态查找（静默失效风险）。

### orbit_cli 注册检测改为精确匹配
`contains("orbit")` 模糊匹配可能误判，改为完整路径比较。

### permission UI 清理逻辑优化
分离当前 session perm 清理和全局隐藏逻辑。

### anomaly 高频更新抑制
Anomaly 状态每 5s emit 一次是无意义的，改为粒度变化时才 emit。

### settings.json 原子写入
写入 `.tmp` 再 rename，防止半写入损坏。

### 多显示器支持
外接显示器时灵动岛出现在错误的屏幕上。需要检测当前活跃屏幕。
- 工作量：S（CC: ~20min）

### launchd 开机自启
- 方案：`orbit install --autostart` 写入 `~/Library/LaunchAgents/app.orbit.plist`
- 工作量：S（CC: ~10min）

## 待调查

### Token / 费用追踪
Claude Code hooks 是否返回 token 消耗数据？需要调查 PostToolUse / Stop payload 的完整 schema。

### Claude Code hooks 完整 schema
`session_id`、`tool_name` 等字段是否是准确的字段名？`parent_id` 是否存在？
