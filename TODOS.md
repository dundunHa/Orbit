# Orbit — TODOS

## P2 — Phase 2（开源前）

### 多显示器支持
外接显示器时灵动岛出现在错误的屏幕上。需要检测当前活跃屏幕（鼠标所在屏幕或最近使用屏幕），将窗口定位到正确的刘海位置。
- 工作量：S（CC: ~20min）
- 依赖：Spike 1 notch 定位完成后再做

### launchd 开机自启
重启后需要手动启动 Orbit，开源用户期望它像其他工具一样"就在那里"。
- 方案：`orbit install --autostart` 写入 `~/Library/LaunchAgents/app.orbit.plist`
- 工作量：S（CC: ~10min）

## 待调查

### Token / 费用追踪（已加入当前 scope）
Claude Code hooks 是否返回 token 消耗数据？需要调查 PostToolUse / Stop payload 的完整 schema。
- 如果 hooks 不返回 token 数据，可能需要解析 CLI 的 stderr 或读取 usage 日志
- 目标：历史记录视图中显示每个 session 的 token 消耗和估算费用

### Claude Code hooks 完整 schema
`session_id`、`tool_name` 等字段是否是准确的字段名？`parent_id` 是否存在？
- 建议：在终端运行一个 Claude Code 任务，用临时脚本打印所有 hook payload
