# GUI 启动时自动安装 Orbit Hooks 计划

## 问题陈述

目前 Orbit 需要通过 CLI (`orbit-cli install`) 手动安装到 Claude Code。未来发行版将只发布 GUI 程序，需要设计一个丝滑的启动体验，让 GUI 在启动时自动检查并完成安装。

### 当前流程
```
用户打开终端 → 运行 orbit-cli install → 配置写入 ~/.claude/settings.json
```

### 目标流程
```
用户打开 Orbit.app → GUI 自动检测 → 引导安装 → 完成连接
```

## 设计方案

### 核心原则: "Silent & Seamless" (静默无感)
DMG 分发的 macOS App 应该做到：
- **零点击安装**: 首次启动自动检测并尝试安装
- **后台静默**: 所有检查在后台线程完成，不阻塞 UI
- **最小打扰**: 只有真正需要用户决策时才显示界面
- **无弹窗授权**: 不使用文件选择器等打断体验的弹窗

### 用户旅程

#### 场景 1: 全新用户 (理想路径)
```
打开 Orbit.app → 托盘图标显示 🟡"正在连接..." → 2秒后 🟢"已连接"
                                       ↓
                            后台自动安装 hooks
```
**用户感知**: 只是看到图标从黄变绿，全程无弹窗。

#### 场景 2: 全新用户 (需要授权)
```
打开 Orbit.app → 托盘图标 🟡"正在连接..." → 检测到权限限制
                                       ↓
                            显示轻量提示: "需要访问 Claude Code 配置"
                                       ↓
                            用户点击"授权" → 打开系统设置指引
```
**仅在必要时询问**。

#### 场景 3: Orbit 已安装
```
打开 Orbit.app → 托盘图标直接 🟢 → 后台静默验证 → 一切正常，无提示
```
**已安装用户零打扰**。

#### 场景 4: 配置冲突
```
打开 Orbit.app → 检测到其他工具占用 → 托盘图标 🔴 → 点击后显示冲突解决
```
**非阻塞式警告**，用户主动点击才处理。

#### 场景 2: Orbit 已安装
1. 打开 Orbit.app
2. 直接显示主界面
3. 后台静默验证 hooks 完整性
4. 如有问题，托盘图标提示修复

#### 场景 3: 配置冲突
1. 检测到 statusline 被其他工具占用
2. 显示冲突解决对话框
3. 提供备份和恢复选项

### 技术实现

#### 状态机设计
```rust
enum OnboardingState {
    Welcome,           // 首次使用
    Checking,          // 检测中
    Installing,        // 安装中
    Connected,         // 已连接
    ConflictDetected,  // 配置冲突
    PermissionDenied,  // 权限不足
    DriftDetected,     // 配置漂移
}
```

#### 启动检查流程 (静默无感版)
```rust
fn main() {
    // 1. 极速启动 (<50ms), 立即显示托盘图标
    let app = create_tray_icon_with_state(Status::Connecting);
    
    // 2. 后台线程静默处理
    spawn(|| {
        match auto_install() {
            Ok(()) => {
                // 静默成功，图标变绿，用户无感知
                update_tray_icon(Status::Connected);
            }
            Err(InstallError::PermissionDenied) => {
                // 权限问题，显示轻量提示
                update_tray_icon(Status::NeedsPermission);
                show_permission_hint();
            }
            Err(InstallError::Conflict(other_tool)) => {
                // 配置冲突，非阻塞警告
                update_tray_icon(Status::Conflict);
            }
            Err(_) => {
                // 其他错误，记录日志，不打扰用户
                log::error!("Auto-install failed");
            }
        }
    });
    
    run_event_loop(app);
}

// 自动安装逻辑: 先尝试静默安装，失败再降级
fn auto_install() -> Result<(), InstallError> {
    // 1. 检查当前状态
    let state = check_install_state()?;
    
    match state {
        State::OrbitInstalled => {
            // 已安装，静默验证
            verify_hooks()?;
            Ok(())
        }
        State::NotInstalled => {
            // 尝试静默安装
            silent_install().map_err(|e| {
                // 区分权限错误和其他错误
                if e.is_permission_denied() {
                    InstallError::PermissionDenied
                } else {
                    e
                }
            })
        }
        State::DriftDetected => {
            // 配置漂移，尝试自动修复
            auto_repair().or_else(|_| {
                // 修复失败，标记冲突
                Err(InstallError::Drift)
            })
        }
        State::OtherTool(tool) => {
            Err(InstallError::Conflict(tool))
        }
    }
}
```

#### 安装逻辑复用
将 `orbit_cli.rs` 中的安装逻辑提取为共享模块：

```
src-tauri/
├── src/
│   ├── bin/orbit_cli.rs      # CLI 入口（保持向后兼容）
│   ├── lib.rs                
│   ├── installer.rs          # 提取的共享安装逻辑（新增）
│   └── app/
│       ├── onboarding.rs     # 启动引导流程（新增）
│       └── main.rs           # GUI 入口
```

### UI 设计 (状态驱动)

#### 托盘图标状态 (静默指示)
| 状态 | 图标 | 悬停提示 | 点击行为 |
|------|------|---------|---------|
| 🟡 连接中 | 黄色圆点 | "正在连接 Claude Code..." | 显示进度详情 |
| 🟢 已连接 | 绿色圆点 | "已连接到 Claude Code" | 打开主窗口 |
| 🔴 需授权 | 红色圆点 | "需要授权访问配置" | 显示授权指引 |
| ⚠️ 冲突 | 橙色感叹号 | "检测到配置冲突" | 显示冲突解决 |

#### 首次启动 (后台自动)
```
[用户打开 Orbit.app]
        ↓
[托盘图标显示 🟡 2-3秒]
        ↓
[自动完成安装 → 🟢]
        ↓
[用户点击 🟢 打开主窗口，看到会话列表]
```
**用户全程无弹窗，只看到图标从黄变绿。**

#### 需要授权时 (轻量提示)
```
┌──────────────────────────────────────────────┐
│  🔴 需要访问 Claude Code 配置                 │
│                                              │
│  Orbit 需要写入 ~/.claude/settings.json      │
│                                              │
│  [ 打开系统设置 ]  或  [ 使用终端安装 ]        │
│                                              │
│  复制命令: orbit-cli install                 │
└──────────────────────────────────────────────┘
```
**仅在托盘点击后显示，不主动弹窗。**

#### 冲突解决对话框
```
┌─────────────────────────────────────┐
│  ⚠️ 检测到现有配置                   │
│                                     │
│  你的 Claude Code 已配置其他工具：   │
│  "my-custom-statusline.sh"          │
│                                     │
│  [ 保留现有配置 ]                    │
│  [ 切换到 Orbit ] ← 推荐            │
│                                     │
│  切换将备份当前配置，可随时恢复      │
└─────────────────────────────────────┘
```

### 错误处理策略 (静默优先)

| 错误类型 | 处理方式 | 用户感知 |
|---------|---------|---------|
| wrapper 已存在 | 跳过，静默继续 | 无 |
| hooks 已注册 | 检查是否指向自己，是则跳过 | 无 |
| Claude Code 未安装 | 记录日志，托盘显示"未检测到" | 轻量提示 |
| 权限不足 | 托盘变 🔴，点击后显示授权指引 | 非阻塞提示 |
| 配置漂移 | 尝试自动修复，失败则托盘警告 | 仅失败时提示 |
| 其他工具占用 | 托盘变 ⚠️，等待用户处理 | 非阻塞警告 |

**原则**: 能静默处理的错误，绝不弹窗。

## 实施步骤

### Phase 1: 提取共享安装模块
- [ ] 创建 `src/installer.rs`
- [ ] 将 `prepare_install()` 等逻辑从 `orbit_cli.rs` 迁移
- [ ] 保持 CLI 向后兼容

### Phase 2: 实现 GUI 启动检查
- [ ] 创建 `src/app/onboarding.rs`
- [ ] 实现状态机和状态检测
- [ ] 添加后台静默检查

### Phase 3: UI 实现
- [ ] 欢迎页面
- [ ] 进度/加载状态
- [ ] 冲突解决对话框
- [ ] 错误提示界面

### Phase 4: 测试
- [ ] 单元测试：状态机转换
- [ ] 集成测试：完整安装流程
- [ ] 边界测试：权限拒绝、配置冲突

## 技术挑战

### 1. macOS Sandbox 权限 (静默处理)
GUI App 可能受限于 Sandbox，无法直接写入 `~/.claude/`。

**解决方案** (无弹窗):
1. **首次尝试**: 直接写入，大多数用户未启用严格 Sandbox
2. **失败降级**: 检测权限错误后，显示托盘提示而非弹窗
3. **用户授权**: 点击托盘菜单 → "授权访问" → 打开系统设置中的文件权限页面
4. **CLI fallback**: 提供一键复制命令，用户手动粘贴到终端

**避免使用**: 文件选择器弹窗（打断体验）

### 2. 向后兼容性
保持 `orbit-cli` 命令可用，CLI 和 GUI 共享同一套安装逻辑。

### 3. 配置漂移检测
GUI 启动时需要检测用户是否手动修改了配置。

**实现**: 比较 `statusline-state.json` 中的 managed_command 与当前 settings.json

## NOT in Scope

- Windows/Linux 支持（当前仅 macOS）
- 自动更新机制（独立 PR）
- 多用户/多 Claude Code 实例支持

## 依赖关系

| 任务 | 依赖 |
|------|------|
| GUI 启动检查 | 共享安装模块提取 |
| UI 实现 | Tauri 前端框架 |
| 测试 | 完整的 Phase 1+2 |

## 成功标准 (静默无感)

1. **新用户首次打开 Orbit.app 后，全程无弹窗，只看到托盘图标从 🟡 变 🟢**
2. **已安装用户重新打开时，零弹窗、零点击、直接进入就绪状态**
3. **80% 的用户在首次启动时无需任何交互即可完成安装**
4. **仅在权限限制或配置冲突时才显示界面，且为非阻塞式提示**
5. **随时可以回滚到原始配置 (通过设置菜单)**

## 设计决策记录

### 决策 1: 自动尝试 vs 显式确认
- **选择**: 自动尝试安装
- **原因**: DMG 分发的 macOS App 用户期望"开箱即用"
- **风险**: 用户可能不知道 Orbit 修改了 Claude Code 配置
- **缓解**: 首次成功后在主窗口显示"已连接到 Claude Code"的确认信息

### 决策 2: 无文件选择器弹窗
- **选择**: 静默失败 + 托盘提示
- **原因**: 文件选择器会严重打断用户 workflow
- **备选**: 提供终端命令作为 fallback

### 决策 3: 状态机而非向导
- **选择**: 状态驱动的托盘图标
- **原因**: 向导需要用户一步步点击，不符合"无感"目标
- **实现**: 后台自动推进状态，UI 仅反映当前状态
