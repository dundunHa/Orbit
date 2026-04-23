// i18n — lightweight copy registry.
// Orbit's UI bar intentionally renders Claude Code-facing text in English.

const en = {
  "status.thinking": "Thinking...",
  "status.approve": "Claude needs your permission",
  "status.respond": "Choose an option",
  "status.stuck": "Waiting for you ({seconds}s)",
  "status.compacting": "Compacting...",
  "status.ended": "Session ended",
  "status.idle": "Waiting for input",
  "status.noConnections": "No Claude Code sessions",
  "status.waiting": "Waiting...",

  "tool.bash": "Running Bash...",
  "tool.read": "Reading file...",
  "tool.edit": "Editing file...",
  "tool.write": "Writing file...",
  "tool.grep": "Searching...",
  "tool.glob": "Searching files...",
  "tool.agent": "Running Task...",
  "tool.fallback": "Running {name}...",

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

  "sessionStatus.thinking": "Thinking",
  "sessionStatus.running": "Running",
  "sessionStatus.approve": "Needs permission",
  "sessionStatus.respond": "Needs response",
  "sessionStatus.stuck": "Waiting for you",
  "sessionStatus.compacting": "Compacting",
  "sessionStatus.idle": "Waiting for input",

  "live.thinking": "Thinking",
  "live.runningTool": "Running {tool}",
  "live.blocked": "Permission required",
  "live.respond": "Response required",
  "live.stuckSeconds": "Waiting for you {seconds}s",
  "live.compacting": "Compacting",
  "live.idle": "Waiting for input",
  "live.readingContext": "Reading context",
  "live.waitingInput": "Waiting for input",
  "live.waitingForApproval": "Claude needs your permission to use {tool}",
  "live.waitingForChoice": "Choose an option to continue",
  "live.waitingForUser": "Waiting for you",
  "live.compactingDetail": "Compacting conversation",
  "live.endedDetail": "Session ended",
  "live.approvalTitle": "Claude needs your permission",
  "live.tool": "tool",
  "live.noModel": "—",
  "live.unknownCwd": "~/unknown",
  "live.noTokens": "No tokens yet",
  "live.tokenMetrics": "{input} in · {output} out",
  "live.metricsWithModel": "{tokens} · {model}",

  "permission.allow": "Allow",
  "permission.deny": "Deny",
  "permission.allowAria": "Allow once",
  "permission.denyAria": "Deny this request",
  "permission.scopeOnce": "Allow once for this session",
  "permission.toolLabel.bash": "Claude wants to use Bash",
  "permission.toolLabel.edit": "Claude wants to edit files",
  "permission.toolLabel.read": "Claude wants to read files",
  "permission.toolLabel.network": "Claude wants to access the network",
  "permission.toolLabel.mcp": "MCP tool call",
  "permission.toolLabel.agent": "Claude wants to launch a task",
  "permission.toolLabel.plan": "Plan state update",
  "permission.toolLabel.unknown": "Custom tool request",
  "permission.detail.prompt": "Claude's request",
  "permission.detail.command": "Command",
  "permission.detail.cwd": "Working directory",
  "permission.detail.file": "File",
  "permission.detail.preview": "Preview",
  "permission.detail.scope": "Scope",
  "permission.detail.destination": "Destination",
  "permission.detail.arguments": "Arguments",
  "permission.detail.risk": "Risk",
  "interaction.question": "Question",
  "interaction.submit": "Submit",
  "interaction.passThrough": "Continue in Claude Code",
  "interaction.passThroughAria": "Continue in Claude Code",
  "interaction.cancel": "Cancel",
  "interaction.unsupported":
    "Continue in Claude Code to respond to this request.",
};

const locales = { en };

function detectLocale() {
  return "en";
}

const currentLocale = detectLocale();
const messages = locales[currentLocale] || en;

/**
 * Translate a key, with optional interpolation.
 * t("status.stuck", { seconds: 30 }) -> "Waiting for you (30s)"
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
