// i18n — lightweight localization
// Detects system language; falls back to English for non-Chinese locales.

const zh = {
  // Pill status
  "status.thinking": "思考中...",
  "status.approve": "待批准",
  "status.respond": "待选择",
  "status.stuck": "卡住了？({seconds}秒)",
  "status.compacting": "压缩中...",
  "status.ended": "已结束",
  "status.idle": "空闲",
  "status.noConnections": "无连接",
  "status.waiting": "等待中...",

  // Tool descriptions
  "tool.bash": "$ 运行中...",
  "tool.read": "读取中...",
  "tool.edit": "编辑中...",
  "tool.write": "写入中...",
  "tool.grep": "搜索中...",
  "tool.glob": "查找中...",
  "tool.agent": "代理中...",
  "tool.fallback": "{name}...",

  // Onboarding
  "onboarding.welcome": "欢迎使用 Orbit",
  "onboarding.checking": "正在检查 Claude Code 配置...",
  "onboarding.installing": "正在将 Orbit 连接到 Claude Code...",
  "onboarding.connected": "已连接到 Claude Code",
  "onboarding.conflict": "检测到配置冲突",
  "onboarding.permissionDenied": "需要权限",
  "onboarding.drift": "检测到配置漂移",
  "onboarding.error": "Orbit 设置失败",
  "onboarding.requiresAttention": "Orbit 设置需要处理",
  "onboarding.retrying": "重试中...",
  "onboarding.retry": "重试",

  // Sections
  "section.setup": "设置",
  "section.active": "活跃会话",
  "section.recent": "最近",

  // Sessions
  "session.noActive": "无活跃会话",
  "session.noHistory": "暂无历史记录",
  "session.noRecent": "无最近会话 (3小时内)",
  "session.untitled": "无标题",

  // Session status labels
  "sessionStatus.thinking": "思考中",
  "sessionStatus.running": "运行中",
  "sessionStatus.approve": "待批准",
  "sessionStatus.respond": "待选择",
  "sessionStatus.stuck": "卡住了",
  "sessionStatus.compacting": "压缩中",
  "sessionStatus.idle": "空闲",

  // Permission
  "permission.allow": "允许",
  "permission.deny": "拒绝",
  "permission.allowAria": "允许执行一次",
  "permission.denyAria": "拒绝本次请求",
  "permission.scopeOnce": "允许一次 · 当前会话",
  "interaction.question": "问题",
  "interaction.submit": "提交选择",
  "interaction.passThrough": "回到终端处理",
  "interaction.passThroughAria": "回到终端处理",
  "interaction.cancel": "取消",
  "interaction.unsupported":
    "这个请求需要更复杂的输入，Orbit 先让 Claude/Codex 在终端继续处理。",
};

const en = {
  "status.thinking": "Thinking...",
  "status.approve": "Approve?",
  "status.respond": "Respond?",
  "status.stuck": "Stuck? ({seconds}s)",
  "status.compacting": "Compacting...",
  "status.ended": "Ended",
  "status.idle": "Idle",
  "status.noConnections": "No connections",
  "status.waiting": "Waiting...",

  "tool.bash": "$ Running...",
  "tool.read": "Reading...",
  "tool.edit": "Editing...",
  "tool.write": "Writing...",
  "tool.grep": "Searching...",
  "tool.glob": "Finding...",
  "tool.agent": "Agent...",
  "tool.fallback": "{name}...",

  "onboarding.welcome": "Welcome to Orbit",
  "onboarding.checking": "Checking Claude Code configuration...",
  "onboarding.installing": "Connecting Orbit to Claude Code...",
  "onboarding.connected": "Connected to Claude Code",
  "onboarding.conflict": "Configuration conflict detected",
  "onboarding.permissionDenied": "Permission required",
  "onboarding.drift": "Configuration drift detected",
  "onboarding.error": "Orbit setup failed",
  "onboarding.requiresAttention": "Orbit setup requires attention",
  "onboarding.retrying": "Retrying...",
  "onboarding.retry": "Retry",

  "section.setup": "Setup",
  "section.active": "Active",
  "section.recent": "Recent",

  "session.noActive": "No active sessions",
  "session.noHistory": "No history yet",
  "session.noRecent": "No recent sessions (last 3h)",
  "session.untitled": "Untitled",

  "sessionStatus.thinking": "thinking",
  "sessionStatus.running": "running",
  "sessionStatus.approve": "approve?",
  "sessionStatus.respond": "respond?",
  "sessionStatus.stuck": "stuck",
  "sessionStatus.compacting": "compacting",
  "sessionStatus.idle": "idle",

  "permission.allow": "Allow",
  "permission.deny": "Deny",
  "permission.allowAria": "Allow once",
  "permission.denyAria": "Deny this request",
  "permission.scopeOnce": "Allow once · current session",
  "interaction.question": "Question",
  "interaction.submit": "Submit",
  "interaction.passThrough": "Continue in terminal",
  "interaction.passThroughAria": "Continue in terminal",
  "interaction.cancel": "Cancel",
  "interaction.unsupported":
    "This request needs a richer form, so Orbit will hand it back to Claude/Codex in the terminal.",
};

const locales = { zh, en };

function detectLocale() {
  const lang = navigator.language || navigator.languages?.[0] || "en";
  return lang.startsWith("zh") ? "zh" : "en";
}

const currentLocale = detectLocale();
const messages = locales[currentLocale] || en;

/**
 * Translate a key, with optional interpolation.
 * t("status.stuck", { seconds: 30 }) → "Stuck? (30s)"
 */
export function t(key, params) {
  let text = messages[key];
  if (text === undefined) {
    // fallback to English
    text = en[key];
  }
  if (text === undefined) {
    return key;
  }
  if (params) {
    for (const [k, v] of Object.entries(params)) {
      text = text.replace(`{${k}}`, v);
    }
  }
  return text;
}

export function getLocale() {
  return currentLocale;
}
