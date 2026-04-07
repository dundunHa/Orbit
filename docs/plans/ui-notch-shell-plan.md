# UI Notch Shell — Implementation Plan

## Overview
为 Orbit 顶部 UI bar 引入与 Mac 刘海一致的轮廓模型。

目标不是在现有 `.island` 上继续调 `border-radius`，也不是给 bar 两侧外挂“耳朵”。
目标是让顶部黑色轮廓先与屏幕顶部融为一体，再在下方用圆角自然收回到 bar 内容区域。

---

## Problem Statement

当前 UI 只有一个 `#island` 节点，它同时承担：

1. 内容容器
2. 最终黑色外轮廓

这会导致两个问题：

### 1. `border-radius` 只能切出内凹圆角
在 `.island` 上直接设置顶部圆角，本质是在当前矩形内部削角。
视觉结果会更像“一个浮在空中的圆角矩形”，而不是“贴住屏幕顶部的刘海轮廓”。

### 2. 伪元素 / 圆形补丁不是单一轮廓
使用 `::before` / `::after` 补两个圆或两块额外形状，只会形成拼接感。
在 Tauri 透明窗口中，这种拼接非常容易暴露，特别是在不同壁纸和抗锯齿边缘下。

---

## Architecture Decision

**采用 shell + content 两层结构。**

### 外层 `.island-shell`
只负责：

- 顶部贴住屏幕边缘的整体 silhouette
- 顶部外凸过渡
- 底部圆角回收

### 内层 `#island`
只负责：

- mascot / status dot / text
- expanded detail 内容
- hover / expand / collapse 交互

这会把“轮廓问题”和“内容布局问题”分离，避免继续在单个节点上混合处理两类职责。

---

## Recommended Shape Strategy

### Primary: SVG clipPath / mask

首选在 `.island-shell` 上使用单一路径定义整体轮廓。

原因：

1. 可以描述连续外轮廓，而不是多个补丁拼出来的曲线
2. 对 Tauri 透明窗口最可控
3. 便于后续根据 notch / pill width 做参数化
4. 更接近 Mac notch / Dynamic Island 的真实视觉逻辑

### Secondary: CSS `clip-path: path(...)`

作为备选。

原因：

1. 结构更轻
2. 不需要额外 SVG 资源

风险：

1. WebKit / WKWebView 边缘抗锯齿细节需要实测
2. 复杂路径在不同缩放下可能比 SVG 更脆弱

### Explicitly Rejected

#### A. 继续调 `.island` 的 `border-radius`
拒绝原因：只能产生内切角。

#### B. 两侧伪元素“耳朵”
拒绝原因：几何上不是单一轮廓，在透明窗口下拼接感明显。

#### C. 两个圆形伪元素制造外凸
拒绝原因：视觉上会变成两个独立 blob，而不是连续 top silhouette。

---

## Files to Modify

### 1. `src/index.html`

#### Introduce shell wrapper
当前：

```html
<div id="island" class="island collapsed">...</div>
```

目标：

```html
<div class="island-shell" aria-hidden="true">
  <svg class="island-shell-shape">...</svg>
</div>

<div id="island" class="island collapsed">...</div>
```

或使用一个共同的 wrapper：

```html
<div class="island-frame">
  <div class="island-shell" aria-hidden="true">...</div>
  <div id="island" class="island collapsed">...</div>
</div>
```

推荐使用共同 wrapper，这样 shell 与 content 可共享定位坐标系。

---

### 2. `src/styles.css`

#### Add frame / shell / content layering

新增：

- `.island-frame`
- `.island-shell`
- `.island-shell-shape`

保留 `#island` 的内容布局样式，但把“最终黑色轮廓”从 `.island` 移走。

#### Layout expectations

`.island-frame`：

- `position: fixed`
- `top: 0`
- `left: 50%`
- `transform: translateX(-50%)`
- 宽度由 shell 控制

`.island-shell`：

- 占据整个可见 silhouette 区域
- 只负责黑色背景轮廓
- 不承载交互内容

`#island`：

- 放在 shell 内部或其上层
- 保持现有三段 pill 布局和 expanded detail 逻辑
- 顶部不再尝试用 `border-radius` 模拟外凸

#### Remove previous anti-patterns

必须删除或避免：

- `.island::before`
- `.island::after`
- 顶部 `border-radius`
- 任何 “ear” / “blob” 补丁逻辑

---

### 3. `src/main.js`

#### Keep geometry variables, but target frame/shell

当前已有：

- `--notch-height`
- `--pill-width`
- `--notch-width`
- `--zone-left-width`
- `--zone-right-width`

这些变量可以继续保留。

需要新增/调整：

- `--shell-width`
- `--shell-height`
- 如 SVG path 需要额外参数，可增加 `--shell-shoulder-radius`

目的：使 shell 轮廓与当前屏幕 notch geometry 同步，而不是写死一套尺寸。

---

### 4. `src-tauri/src/commands.rs`

#### Revisit native window frame only after shell geometry is settled

当前建议：

1. 先保持现有窗口 frame 逻辑不动
2. 实现 shell 后再决定是否需要为外轮廓额外增加窗口宽度/高度

原因：

- 之前的 width 扩展是在错误轮廓模型上做的补救
- 正确 shell 方案确定后，窗口几何才能准确匹配 silhouette 边界

只有当 shell 的外轮廓超出当前 window frame 时，才需要再调整：

- `x`
- `width`
- `height`

---

## Shape Implementation Guidance

### Option A — SVG shell path

最推荐。

思路：

1. shell 顶部与窗口顶部齐平
2. 左右上角做连续外凸过渡
3. 左右下角做圆角收回
4. 整个黑色 silhouette 由一条 path 决定

优势：

- 几何表达最清晰
- 透明窗口中边界最稳定
- 后续便于根据屏幕参数生成 path

### Option B — CSS `clip-path: path(...)`

思路与 SVG 一致，但路径直接写在 CSS 中。

适合：

- 形状固定
- 不需要太复杂的 path 维护

不建议作为首选。

---

## Implementation Steps

### Step 1
新增 `island-frame` / `island-shell` 结构，不改变现有内容布局。

### Step 2
把黑色轮廓从 `.island` 移到 `.island-shell`。

### Step 3
先用 SVG path 实现一个最小可用 silhouette。

### Step 4
让 `#island` 仅负责内部内容和动画。

### Step 5
验证 collapsed / expanded 两种状态下 shell 轮廓是否稳定。

### Step 6
如 shell 超出 window frame，再精确调整 `commands.rs` 的窗口几何。

---

## Verification Checklist

- [ ] collapsed 状态下，顶部轮廓看起来贴住屏幕顶边，而不是浮空 pill
- [ ] expanded 状态下，顶部轮廓保持稳定，不出现拼接感
- [ ] 不再存在 `::before` / `::after` 伪元素补丁
- [ ] 不再依赖顶部 `border-radius` 模拟外凸
- [ ] 在不同深浅壁纸下，边缘没有明显 seam / blob / detached curvature
- [ ] `cargo check` 通过
- [ ] 前端无新增 diagnostics error

---

## Not in Scope

本方案只解决“顶部 notch shell 轮廓”问题，不包括：

1. mascot / status 的视觉重设计
2. expanded detail 的内容排版优化
3. 整体主题色调整
4. 阴影 / blur / 材质系统重做

---

## Summary

这次不应继续在 `.island` 上做圆角实验。

正确方向是：

1. 拆出 `shell + content` 两层模型
2. 用单一路径描述顶部 silhouette
3. 让 `#island` 回归纯内容容器

这是与 Mac notch 视觉逻辑最一致、也最适合 Orbit 当前透明 Tauri 窗口架构的方案。
