// Orbit — Dynamic Island Frontend
// Tauri IPC bridge

import { SessionTree } from "./components/SessionTree/index.js";
import {
  buildSessionTree,
  formatCompactTokenCount,
  formatCompactTokenRate,
  formatTokenCount,
  formatTokenRate,
  getSessionCounts,
  getSessionTokenStats,
} from "./utils/sessionTransform.js";
import { t, getLocale } from "./utils/i18n.js";
import { invokeCommand } from "./utils/tauriInvoke.js";

const { listen } = window.__TAURI__.event;

// State
let sessions = {}; // All sessions keyed by session_id
let activeSessionId = null;
let isExpanded = false;
let isAnimating = false; // IMPL-06: animation lock
const pendingInteractions = new Map(); // Map<requestId, interactionRequest>
let sessionTree = null;
let onboardingState = null;
let onboardingRetryPending = false;
let collapseDebounceTimer = null;
let wantExpanded = false; // 鼠标期望状态，动画结束后据此对账
let hoverInside = false;
const COLLAPSE_DELAY = 200; // ms, hover 离开后延迟收起防抖
let cachedHistory = null; // 预取的 history，expand 时直接渲染避免 IPC 延迟
let lastExpandedFrame = { width: null, height: null };

const DEFAULT_EXPANDED_HEIGHT = 320;
const FOCUS_EXPANDED_HEIGHT = 560;
const FOCUS_WIDTH_BASE = 640;
const FOCUS_WIDTH_WIDE = 720;
const WINDOW_EDGE_MARGIN = 24;
const QUESTION_OPTION_MAX_WIDTH = 260;
const QUESTION_OPTION_MIN_WIDTH = 168;
const QUESTION_OPTION_LONG_MIN_WIDTH = 220;
const QUESTION_OPTION_GAP = 6;
const QUESTION_OPTION_LAYOUT_LEFT_INSET = 16;
const QUESTION_OPTION_LAYOUT_RIGHT_INSET = 16;

listen("screen-changed", (event) => {
  const info = event.payload;
  if (!info || typeof info.notch_height !== "number") {
    console.error("[Orbit] Invalid screen-changed payload", info);
    return;
  }
  const root = document.documentElement;
  root.style.setProperty("--notch-height", info.notch_height + "px");
  root.style.setProperty("--pill-width", info.pill_width + "px");
  root.style.setProperty("--notch-width", info.notch_width + "px");
  root.style.setProperty("--zone-left-width", info.left_zone_width + "px");
  root.style.setProperty("--zone-right-width", info.right_zone_width + "px");
  root.style.setProperty("--mascot-left-inset", info.mascot_left_inset + "px");
  notchInfo = info;
  if (isExpanded) {
    scheduleExpandedHeightUpdate();
  }
  console.log("[Orbit] Screen configuration updated", info);
});

// Notch geometry (set during init)
let notchInfo = {
  notch_height: 37,
  screen_width: 1440,
  notch_left: 620,
  notch_right: 820,
  notch_width: 200,
  left_safe_width: 620,
  right_safe_width: 620,
  has_notch: true,
  pill_width: 480,
  left_zone_width: 120,
  right_zone_width: 160,
  mascot_left_inset: 8,
};

// DOM elements
const island = document.getElementById("island");
const statusDot = document.querySelector(".status-dot");
const statusText = document.querySelector(".status-text");
const sessionCwd = document.querySelector(".session-cwd");
const detailStatus = document.querySelector(".detail-status");
const detailTools = document.querySelector(".detail-tools");
const detailTokens = document.querySelector(".detail-tokens");
const detailModel = document.querySelector(".detail-model");
const onboardingSection = document.querySelector(".onboarding-section");
const onboardingStatusDot = document.querySelector(".onboarding-status-dot");
const onboardingStatusText = document.querySelector(".onboarding-status-text");
const onboardingRetryButton = document.querySelector(".btn-retry");
const detail = document.querySelector(".detail");
const activeList = document.querySelector(".active-list");
const permissionSection = document.querySelector(".permission-section");
const permissionTool = document.querySelector(".permission-tool");
const permissionMessage = document.querySelector(".permission-message");
const permissionActions = document.querySelector(".permission-actions");
const historyList = document.querySelector(".history-list");
const mascot = document.querySelector(".mascot");
const DEFAULT_PROVIDER = "claude-code";
let currentStatusText = "";

const ONBOARDING_STATUS_MAP = {
  Welcome: {
    dotClass: "processing",
    mascotStatusType: "Processing",
    fallbackTextKey: "onboarding.welcome",
  },
  Checking: {
    dotClass: "processing",
    mascotStatusType: "Processing",
    fallbackTextKey: "onboarding.checking",
  },
  Installing: {
    dotClass: "running-tool",
    mascotStatusType: "RunningTool",
    fallbackTextKey: "onboarding.installing",
  },
  Connected: {
    dotClass: "idle",
    mascotStatusType: "WaitingForInput",
    fallbackTextKey: "onboarding.connected",
  },
  ConflictDetected: {
    dotClass: "anomaly",
    mascotStatusType: "Anomaly",
    fallbackTextKey: "onboarding.conflict",
  },
  PermissionDenied: {
    dotClass: "waiting-approval",
    mascotStatusType: "WaitingForApproval",
    fallbackTextKey: "onboarding.permissionDenied",
  },
  DriftDetected: {
    dotClass: "anomaly",
    mascotStatusType: "Anomaly",
    fallbackTextKey: "onboarding.drift",
  },
  Error: {
    dotClass: "error",
    mascotStatusType: "Anomaly",
    fallbackTextKey: "onboarding.error",
  },
};

// Status priority for selecting which session to display
const STATUS_PRIORITY = {
  WaitingForApproval: 6,
  Anomaly: 5,
  RunningTool: 4,
  Processing: 3,
  Compacting: 2,
  WaitingForInput: 1,
  Ended: 0,
};

// IMPL-06 + IMPL-08: transitionend handles animation lock + collapse window resize
let collapseAfterTransition = false;
let collapseFallbackTimer = null;

function clearAnimationFallback() {
  if (collapseFallbackTimer) {
    clearTimeout(collapseFallbackTimer);
    collapseFallbackTimer = null;
  }
}

function scheduleAnimationFallback(handler) {
  clearAnimationFallback();
  collapseFallbackTimer = setTimeout(() => {
    collapseFallbackTimer = null;
    handler();
  }, 350);
}

// 统一的展开请求入口：即便当前正处于收起/展开动画，也保留这次展开意图
// 交给 transition 结束后的 reconcileExpandState 继续完成。
function requestExpand() {
  if (collapseDebounceTimer) {
    clearTimeout(collapseDebounceTimer);
    collapseDebounceTimer = null;
  }
  wantExpanded = true;
  if (!isExpanded && !isAnimating) {
    expandIsland();
  }
}

function settleAfterInteractionsComplete() {
  wantExpanded = hoverInside;
  if (!hoverInside && isExpanded && !isAnimating) {
    collapseIsland();
  }
}

function clampInteractionWidth(width) {
  const baseWidth = notchInfo.pill_width || 480;
  const screenWidth = notchInfo.screen_width || baseWidth;
  const maxWidth = Math.max(baseWidth, screenWidth - WINDOW_EDGE_MARGIN * 2);
  return Math.round(Math.min(maxWidth, Math.max(baseWidth, width)));
}

function getExpandedWidth() {
  if (island.classList.contains("interaction-focus")) {
    const cssWidth = parseFloat(
      document.documentElement.style.getPropertyValue("--interaction-width"),
    );
    if (Number.isFinite(cssWidth) && cssWidth > 0) {
      return cssWidth;
    }
  }
  return notchInfo.pill_width || 480;
}

function getExpandedMaxHeight() {
  return island.classList.contains("interaction-focus")
    ? FOCUS_EXPANDED_HEIGHT
    : DEFAULT_EXPANDED_HEIGHT;
}

async function applyExpandedFrame(width, height) {
  if (!Number.isFinite(width) || !Number.isFinite(height)) return;
  if (
    Math.abs((lastExpandedFrame.width || 0) - width) < 0.5 &&
    Math.abs((lastExpandedFrame.height || 0) - height) < 0.5
  ) {
    return;
  }

  lastExpandedFrame = { width, height };
  try {
    await invokeCommand("set_expanded_frame", { width, height });
  } catch (e) {
    console.error("[Orbit] Failed to resize expanded frame:", e);
  }
}

function estimateInteractionWidth(request) {
  const textLength =
    (request.message || "").length +
    (request.questionGroups || []).reduce((total, question) => {
      const optionText = question.options
        .map((option) => `${option.label} ${option.description || ""}`)
        .join(" ");
      return total + question.prompt.length + optionText.length;
    }, 0);
  const questionCount = request.questionGroups?.length || 0;
  const optionCount = (request.questionGroups || []).reduce(
    (total, question) => total + question.options.length,
    request.options?.length || 0,
  );

  const target =
    textLength > 520 || questionCount > 1 || optionCount > 4
      ? FOCUS_WIDTH_WIDE
      : FOCUS_WIDTH_BASE;
  return clampInteractionWidth(target);
}

function getQuestionOptionLayout(question) {
  const optionCount = question.options.length;
  const availableWidth = Math.max(
    QUESTION_OPTION_MIN_WIDTH,
    getExpandedWidth() -
      QUESTION_OPTION_LAYOUT_LEFT_INSET -
      QUESTION_OPTION_LAYOUT_RIGHT_INSET,
  );
  const longestOptionText = question.options.reduce((longest, option) => {
    const textLength =
      (option.label || "").length + (option.description || "").length;
    return Math.max(longest, textLength);
  }, 0);
  const hasDescriptions = question.options.some((option) =>
    Boolean(option.description),
  );
  const minOptionWidth =
    hasDescriptions || longestOptionText > 34
      ? QUESTION_OPTION_LONG_MIN_WIDTH
      : QUESTION_OPTION_MIN_WIDTH;
  const maxColumnsByWidth = Math.max(
    1,
    Math.floor(
      (availableWidth + QUESTION_OPTION_GAP) /
        (minOptionWidth + QUESTION_OPTION_GAP),
    ),
  );
  const preferredColumns = optionCount <= 1 ? 1 : optionCount <= 4 ? 2 : 3;
  const columns = Math.max(
    1,
    Math.min(optionCount, preferredColumns, maxColumnsByWidth),
  );
  const optionWidth = Math.min(
    QUESTION_OPTION_MAX_WIDTH,
    Math.floor(
      (availableWidth - QUESTION_OPTION_GAP * (columns - 1)) / columns,
    ),
  );

  return {
    columns,
    optionWidth,
    maxWidth: optionWidth * columns + QUESTION_OPTION_GAP * (columns - 1),
  };
}

function applyInteractionFocus(request) {
  if (!request.requiresFocus) {
    clearInteractionFocus();
    return;
  }

  const width = estimateInteractionWidth(request);
  document.documentElement.style.setProperty(
    "--interaction-width",
    `${width}px`,
  );
  island.classList.add("interaction-focus");

  if (isExpanded) {
    scheduleExpandedHeightUpdate();
  }
}

function clearInteractionFocus() {
  island.classList.remove("interaction-focus");
  document.documentElement.style.removeProperty("--interaction-width");
  lastExpandedFrame = { width: null, height: null };

  if (isExpanded) {
    scheduleExpandedHeightUpdate();
  }
}

// 动画结束后根据 wantExpanded 期望状态对账，确保不丢事件
function reconcileExpandState() {
  isAnimating = false;
  if (!wantExpanded && isExpanded) {
    collapseIsland();
  } else if (wantExpanded && !isExpanded) {
    expandIsland();
  }
}

island.addEventListener("transitionend", async (e) => {
  if (e.target === island && e.propertyName === "height") {
    clearAnimationFallback();
    if (collapseAfterTransition) {
      await finishCollapse();
    }
    reconcileExpandState();
  }
});

island.addEventListener("transitioncancel", async (e) => {
  if (e.target === island && e.propertyName === "height") {
    clearAnimationFallback();
    if (collapseAfterTransition) {
      await finishCollapse();
    }
    reconcileExpandState();
  }
});

// Initialize: load notch info, set layout, load sessions
async function init() {
  // Apply i18n to static HTML elements
  document.documentElement.lang = getLocale();
  document.querySelectorAll("[data-i18n]").forEach((el) => {
    el.textContent = t(el.dataset.i18n);
  });

  try {
    notchInfo = await invokeCommand("get_notch_info");
  } catch (e) {
    console.error("Failed to get notch info:", e);
  }

  // Set CSS custom properties for three-zone layout
  const root = document.documentElement;
  root.style.setProperty("--notch-height", notchInfo.notch_height + "px");
  root.style.setProperty("--pill-width", notchInfo.pill_width + "px");
  root.style.setProperty("--notch-width", notchInfo.notch_width + "px");
  root.style.setProperty("--zone-left-width", notchInfo.left_zone_width + "px");
  root.style.setProperty(
    "--zone-right-width",
    notchInfo.right_zone_width + "px",
  );
  root.style.setProperty(
    "--mascot-left-inset",
    notchInfo.mascot_left_inset + "px",
  );

  // Keep the first-run bounce, but let backend onboarding own the status text.
  if (!localStorage.getItem("orbit-onboarded")) {
    localStorage.setItem("orbit-onboarded", "1");
    mascot.classList.add("onboarding");
    setTimeout(() => {
      mascot.classList.remove("onboarding");
    }, 2000);
  }

  try {
    const currentOnboarding = await invokeCommand("get_onboarding_state");
    setOnboardingState(currentOnboarding);
  } catch (e) {
    console.error("Failed to load onboarding state:", e);
  }

  try {
    const existing = await invokeCommand("get_sessions");
    for (const s of existing) {
      sessions[s.id] = s;
    }
    selectActiveSession();
  } catch (e) {
    console.error("Failed to load sessions:", e);
  }

  refreshHistoryCache();
}

function refreshHistoryCache() {
  invokeCommand("get_history")
    .then((history) => {
      cachedHistory = history;
      if (isExpanded) {
        renderHistory(cachedHistory);
      }
    })
    .catch((e) => {
      console.error("Failed to prefetch history:", e);
    });
}

function selectActiveSession() {
  let best = null;
  let bestPriority = -1;

  for (const s of Object.values(sessions)) {
    const prio = STATUS_PRIORITY[s.status.type] || 0;
    if (
      prio > bestPriority ||
      (prio === bestPriority && (!best || s.last_event_at > best.last_event_at))
    ) {
      best = s;
      bestPriority = prio;
    }
  }

  activeSessionId = best ? best.id : null;
  refreshUI();
}

// Listen for session updates from Rust backend
listen("session-update", (event) => {
  const session = event.payload;
  const prev = sessions[session.id];
  sessions[session.id] = session;

  // IMPL-04: Stop event -> completion flash
  if (
    prev &&
    prev.status.type !== "WaitingForInput" &&
    prev.status.type !== "Ended" &&
    (session.status.type === "WaitingForInput" ||
      session.status.type === "Ended")
  ) {
    island.classList.add("flash-complete");
    setTimeout(() => island.classList.remove("flash-complete"), 600);
  }

  if (
    session.status.type === "WaitingForApproval" &&
    getPendingInteractionForSession(session.id)
  ) {
    requestExpand();
  }

  if (session.status.type === "Ended") {
    refreshHistoryCache();
  }

  selectActiveSession();

  if (isExpanded) {
    renderActiveSessions();
  }
});

listen("onboarding-state-changed", (event) => {
  setOnboardingState(event.payload);
});

// Listen for user interaction requests
listen("interaction-request", (event) => {
  const request = normalizeInteractionRequest(event.payload);
  pendingInteractions.set(request.requestId, request);
  if (!isShowingPendingInteraction()) {
    showNextPendingInteraction();
  }
  requestExpand();
});

listen("permission-prompt", () => {
  if (pendingInteractions.size > 0) {
    requestExpand();
  }
});

// Listen for interaction timeout — clean up stale UI
listen("interaction-timeout", (event) => {
  const requestId = event.payload;
  pendingInteractions.delete(requestId);
  if (permissionSection.dataset.requestId === requestId) {
    if (!showNextPendingInteraction()) {
      hideInteractionSection();
      settleAfterInteractionsComplete();
    }
  }
});

listen("interaction-resolved", (event) => {
  const requestId = event.payload;
  pendingInteractions.delete(requestId);
  if (permissionSection.dataset.requestId === requestId) {
    if (!showNextPendingInteraction()) {
      hideInteractionSection();
      settleAfterInteractionsComplete();
    }
  }
});

function getActiveSession() {
  return activeSessionId ? sessions[activeSessionId] || null : null;
}

function hasLiveSessions() {
  return Object.values(sessions).some(
    (session) => session.status.type !== "Ended",
  );
}

function getOnboardingView(state) {
  if (!state || !state.type) {
    return null;
  }

  const config =
    ONBOARDING_STATUS_MAP[state.type] || ONBOARDING_STATUS_MAP.Error;
  return {
    dotClass: config.dotClass,
    mascotStatusType: config.mascotStatusType,
    text: state.status_text || t(config.fallbackTextKey),
    canRetry: Boolean(state.can_retry),
  };
}

function applyPillStatus({ dotClass, mascotStatusType, text }) {
  statusDot.className = "status-dot";
  if (dotClass) {
    statusDot.classList.add(dotClass);
  }
  setMascotVariant(null, mascotStatusType || "WaitingForInput");
  setStatusText(text);
}

function setStatusText(text) {
  currentStatusText = text;
  if (statusText) {
    statusText.textContent = text;
  }
}

function shouldShowOnboardingPill() {
  if (!onboardingState || !onboardingState.type) {
    return false;
  }

  if (onboardingState.type === "Connected") {
    return !hasLiveSessions();
  }

  return true;
}

function renderOnboardingPill() {
  const view = getOnboardingView(onboardingState);
  if (!view) {
    return;
  }

  applyPillStatus(view);
}

function renderFallbackPill() {
  if (!isConnected) {
    applyPillStatus({
      dotClass: "disconnected",
      mascotStatusType: "WaitingForInput",
      text: t("status.noConnections"),
    });
    return;
  }

  applyPillStatus({
    dotClass: "idle",
    mascotStatusType: "WaitingForInput",
    text: t("status.waiting"),
  });
}

function clearSessionDetail() {
  if (!isExpanded) {
    return;
  }

  sessionCwd.textContent = "";
  detailStatus.textContent = shouldShowOnboardingPill()
    ? getOnboardingView(onboardingState)?.text || t("status.waiting")
    : t("status.waiting");
  detailTools.textContent = "";
  detailTokens.textContent = "";
  detailModel.textContent = "";
}

function renderOnboardingSection() {
  if (!onboardingSection || !onboardingStatusDot || !onboardingStatusText) {
    return;
  }

  if (!onboardingState || onboardingState.type === "Connected") {
    onboardingSection.style.display = "none";
    return;
  }

  const view = getOnboardingView(onboardingState);
  onboardingSection.style.display = "block";
  onboardingStatusDot.className = "onboarding-status-dot status-dot";
  if (view?.dotClass) {
    onboardingStatusDot.classList.add(view.dotClass);
  }
  onboardingStatusText.textContent =
    view?.text || t("onboarding.requiresAttention");

  if (onboardingRetryButton) {
    const showRetry = Boolean(view?.canRetry);
    onboardingRetryButton.style.display = showRetry ? "block" : "none";
    onboardingRetryButton.disabled = onboardingRetryPending;
    onboardingRetryButton.textContent = onboardingRetryPending
      ? t("onboarding.retrying")
      : t("onboarding.retry");
  }

  if (isExpanded) {
    scheduleExpandedHeightUpdate();
  }
}

function refreshUI() {
  const activeSession = getActiveSession();

  if (activeSession) {
    updateUI(activeSession);
  } else {
    clearSessionDetail();
    renderFallbackPill();
  }

  if (shouldShowOnboardingPill()) {
    renderOnboardingPill();
  }

  renderOnboardingSection();
}

function setOnboardingState(nextState) {
  onboardingState = nextState;
  onboardingRetryPending = false;
  refreshUI();
}

function updateUI(session) {
  if (!session) return;

  const status = session.status;
  const statusType = status.type;
  const activeToolName = statusType === "RunningTool" ? status.tool_name : null;
  const pendingInteraction =
    statusType === "WaitingForApproval"
      ? getPendingInteractionForSession(session.id)
      : null;

  // Update dot color
  statusDot.className = "status-dot";
  setMascotVariant(activeToolName, statusType);

  switch (statusType) {
    case "Processing":
      statusDot.classList.add("processing");
      setStatusText(t("status.thinking"));
      break;
    case "RunningTool":
      statusDot.classList.add("running-tool");
      setStatusText(formatTool(status.tool_name, status.description));
      break;
    case "WaitingForApproval":
      statusDot.classList.add("waiting-approval");
      setStatusText(
        pendingInteraction?.kind === "elicitation"
          ? t("status.respond")
          : t("status.approve"),
      );
      break;
    case "Anomaly":
      statusDot.classList.add("anomaly");
      setStatusText(t("status.stuck", { seconds: status.idle_seconds }));
      break;
    case "Compacting":
      statusDot.classList.add("processing");
      setStatusText(t("status.compacting"));
      break;
    case "Ended":
      statusDot.classList.add("ended");
      setStatusText(t("status.ended"));
      break;
    case "WaitingForInput":
    default:
      statusDot.classList.add("idle");
      setStatusText(t("status.idle"));
      break;
  }

  // Detail view
  if (isExpanded) {
    const cwdShort = session.cwd.split("/").slice(-2).join("/");
    // sessionCwd.textContent = cwdShort;
    detailStatus.textContent = currentStatusText;
    // detailTools.textContent = session.tool_count + ' tool calls this session';

    const tokenStats = getSessionTokenStats(session);
    detailTokens.textContent =
      `${formatTokenCount(tokenStats.input)} in · ` +
      `${formatTokenCount(tokenStats.output)} out · ` +
      `${formatTokenCount(tokenStats.total)} total`;

    const rateLabel =
      tokenStats.durationSecs > 0
        ? `${formatTokenRate(tokenStats.averageOutputTps)} avg`
        : "—";
    detailModel.textContent = `${rateLabel} · ${session.model || "—"}`;
  }

  // Pending interactions are resolved only by explicit lifecycle events.
  if (statusType !== "WaitingForApproval" && pendingInteractions.size === 0) {
    hideInteractionSection();
  }
}

function setMascotVariant(toolName, statusType) {
  const provider = detectProvider(toolName);
  mascot.setAttribute("class", `mascot mascot-${provider}`);

  if (
    statusType === "Processing" ||
    statusType === "RunningTool" ||
    statusType === "Compacting"
  ) {
    mascot.classList.add("processing");
  }

  if (statusType === "WaitingForApproval" || statusType === "Anomaly") {
    mascot.classList.add("approval");
  }
}

function detectProvider(_toolName) {
  // Current event stream is from Claude Code only. Keep this as the expansion point
  // when Orbit supports more providers later.
  return DEFAULT_PROVIDER;
}

function formatTool(toolName, description) {
  if (description) return description;
  switch (toolName) {
    case "Bash":
      return t("tool.bash");
    case "Read":
      return t("tool.read");
    case "Edit":
      return t("tool.edit");
    case "Write":
      return t("tool.write");
    case "Grep":
      return t("tool.grep");
    case "Glob":
      return t("tool.glob");
    case "Agent":
      return t("tool.agent");
    default:
      return t("tool.fallback", { name: toolName || "" });
  }
}

function describeTool(toolName, toolInput) {
  let desc = toolName || "Unknown";
  if (toolInput && typeof toolInput === "object") {
    if (toolInput.command) {
      desc = toolName + ": " + toolInput.command.substring(0, 80);
    } else if (toolInput.file_path) {
      const file = toolInput.file_path.split("/").pop();
      desc = toolName + ": " + file;
    }
  }
  return desc;
}

function isPlainObject(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function compactText(value, maxLength = 120) {
  if (value === null || value === undefined) {
    return "";
  }

  const text =
    typeof value === "string" ? value : JSON.stringify(value, null, 0);
  const normalized = text.replace(/\s+/g, " ").trim();
  return normalized.length > maxLength
    ? `${normalized.slice(0, maxLength - 3)}...`
    : normalized;
}

function multilineText(value, maxLength = 320) {
  if (value === null || value === undefined) {
    return "";
  }

  const text =
    typeof value === "string" ? value : JSON.stringify(value, null, 2);
  const trimmed = text.trim();
  return trimmed.length > maxLength
    ? `${trimmed.slice(0, maxLength - 3)}...`
    : trimmed;
}

function basename(path) {
  if (!path || typeof path !== "string") {
    return "";
  }
  return path.split(/[\\/]/).filter(Boolean).pop() || path;
}

function inferPermissionFamily(toolName, toolInput, payload = {}) {
  const name = (toolName || "").toLowerCase();
  if (name === "bash") return "bash";
  if (["edit", "multiedit", "write", "notebookedit"].includes(name)) {
    return "edit";
  }
  if (["read", "grep", "glob", "ls"].includes(name)) {
    return "read";
  }
  if (["webfetch", "websearch"].includes(name) || toolInput?.url) {
    return "network";
  }
  if (["task", "agent"].includes(name)) {
    return "agent";
  }
  if (["todowrite", "exitplanmode"].includes(name)) {
    return "plan";
  }
  if (name.startsWith("mcp__") || payload.mcp_server_name) {
    return "mcp";
  }
  return "unknown";
}

function getRiskReasons(toolName, toolInput) {
  if ((toolName || "").toLowerCase() !== "bash" || !toolInput?.command) {
    return [];
  }

  const command = String(toolInput.command);
  const checks = [
    [
      /(\brm\s+[^;&|]*-[a-zA-Z]*r[a-zA-Z]*f|\brm\s+[^;&|]*-[a-zA-Z]*f[a-zA-Z]*r)/,
      "recursive delete",
    ],
    [/\bsudo\b/, "elevated permission"],
    [/\bchmod\s+(-R\s+)?(777|a[+=]w)\b/, "broad permission change"],
    [/\bchown\s+-R\b/, "recursive owner change"],
    [/\bgit\s+reset\s+--hard\b/, "hard reset"],
    [/\bgit\s+clean\s+-[a-zA-Z]*f/, "force clean"],
    [/\bgit\s+push\b[^;&|]*--force/, "force push"],
    [/\b(drop|truncate)\s+(table|database)\b/i, "destructive database command"],
  ];

  return checks
    .filter(([pattern]) => pattern.test(command))
    .map(([, reason]) => reason);
}

function summarizeStructuredArgs(toolInput, omittedKeys = []) {
  if (!isPlainObject(toolInput)) {
    return multilineText(toolInput);
  }

  const omitted = new Set(omittedKeys);
  return Object.entries(toolInput)
    .filter(([key]) => !omitted.has(key))
    .slice(0, 5)
    .map(([key, value]) => `${key}: ${compactText(value, 96)}`)
    .join("\n");
}

function addDisplayBox(boxes, title, text, options = {}) {
  const body = multilineText(text, options.maxLength || 320);
  if (!body) {
    return;
  }
  boxes.push({
    title,
    text: body,
    tone: options.tone || "",
    mono: Boolean(options.mono),
  });
}

function buildEditPreview(toolName, toolInput) {
  const edits = Array.isArray(toolInput?.edits) ? toolInput.edits : [];
  if (edits.length > 0) {
    return edits
      .slice(0, 3)
      .map((edit, index) => {
        const oldText = compactText(edit.old_string, 44);
        const newText = compactText(edit.new_string, 44);
        return `${index + 1}. - ${oldText}\n   + ${newText}`;
      })
      .join("\n");
  }

  if (toolInput?.old_string || toolInput?.new_string) {
    return `- ${compactText(toolInput.old_string, 80)}\n+ ${compactText(toolInput.new_string, 80)}`;
  }

  if ((toolName || "").toLowerCase() === "write" && toolInput?.content) {
    return `${compactText(toolInput.content, 140)}`;
  }

  return "";
}

function buildPermissionDisplay(request, payload = {}) {
  const toolInput = request.toolInput;
  const family = inferPermissionFamily(request.toolName, toolInput, payload);
  const riskReasons = getRiskReasons(request.toolName, toolInput);
  const boxes = [];
  const meta = [];
  let headline = request.title;
  let headlineMono = false;
  const labelKey = `permission.toolLabel.${family}`;
  const label =
    t(labelKey) === labelKey ? request.toolName || "Permission" : t(labelKey);

  if (riskReasons.length > 0) {
    addDisplayBox(boxes, t("permission.detail.risk"), riskReasons.join(", "), {
      tone: "risk",
    });
  }

  switch (family) {
    case "bash": {
      const command = toolInput?.command || request.title;
      headline = command;
      headlineMono = true;
      addDisplayBox(boxes, t("permission.detail.prompt"), request.message);
      addDisplayBox(boxes, t("permission.detail.cwd"), request.cwd, {
        mono: true,
        maxLength: 180,
      });
      meta.push("Bash");
      if (request.cwd) meta.push(`cwd ${basename(request.cwd)}`);
      break;
    }
    case "edit": {
      const filePath = toolInput?.file_path || toolInput?.path || "";
      const editCount = Array.isArray(toolInput?.edits)
        ? toolInput.edits.length
        : null;
      headline = filePath
        ? `${basename(filePath)}${editCount ? ` · ${editCount} edits` : ""}`
        : request.toolName || "Edit";
      addDisplayBox(boxes, t("permission.detail.file"), filePath, {
        mono: true,
        maxLength: 180,
      });
      addDisplayBox(
        boxes,
        t("permission.detail.preview"),
        buildEditPreview(request.toolName, toolInput),
        {
          tone: "edit",
          mono: true,
        },
      );
      addDisplayBox(boxes, t("permission.detail.prompt"), request.message);
      meta.push(request.toolName || "Edit");
      if (filePath) meta.push(basename(filePath));
      break;
    }
    case "read": {
      const filePath = toolInput?.file_path || toolInput?.path || "";
      const pattern = toolInput?.pattern || toolInput?.glob || "";
      headline = filePath || pattern || request.title;
      headlineMono = true;
      addDisplayBox(
        boxes,
        t("permission.detail.scope"),
        filePath || toolInput?.path || request.cwd,
        {
          mono: true,
        },
      );
      addDisplayBox(
        boxes,
        t("permission.detail.arguments"),
        summarizeStructuredArgs(toolInput, ["file_path", "path"]),
        {
          mono: true,
        },
      );
      meta.push(request.toolName || "Read", "read-only");
      break;
    }
    case "network": {
      const url = toolInput?.url || request.url || "";
      headline = url || toolInput?.query || request.title;
      addDisplayBox(
        boxes,
        t("permission.detail.destination"),
        url || toolInput?.query,
        {
          tone: "network",
          mono: true,
        },
      );
      addDisplayBox(
        boxes,
        t("permission.detail.prompt"),
        toolInput?.prompt || request.message,
      );
      meta.push(request.toolName || "Network", "external");
      break;
    }
    case "agent": {
      headline = toolInput?.description || request.title;
      addDisplayBox(
        boxes,
        t("permission.detail.prompt"),
        toolInput?.prompt || request.message,
      );
      addDisplayBox(
        boxes,
        t("permission.detail.arguments"),
        summarizeStructuredArgs(toolInput, ["prompt"]),
        {
          mono: true,
        },
      );
      meta.push(toolInput?.subagent_type || request.toolName || "Agent");
      break;
    }
    case "plan": {
      const todos = Array.isArray(toolInput?.todos) ? toolInput.todos : [];
      headline = todos.length
        ? `${todos.length} plan items will change`
        : request.toolName || "Plan";
      addDisplayBox(
        boxes,
        t("permission.detail.preview"),
        todos
          .slice(0, 4)
          .map(
            (todo) =>
              `${todo.status || "todo"}: ${todo.content || todo.text || ""}`,
          )
          .join("\n"),
      );
      meta.push(request.toolName || "Plan", "state");
      break;
    }
    case "mcp":
    case "unknown":
    default: {
      headline = request.toolName || "Custom tool";
      addDisplayBox(
        boxes,
        t("permission.detail.arguments"),
        summarizeStructuredArgs(toolInput),
        {
          mono: true,
        },
      );
      addDisplayBox(boxes, t("permission.detail.prompt"), request.message);
      meta.push(family === "mcp" ? "MCP" : "unknown");
      break;
    }
  }

  if (boxes.length === 0 && request.message) {
    addDisplayBox(boxes, t("permission.detail.prompt"), request.message);
  }

  return {
    family,
    riskLevel: riskReasons.length > 0 ? "high" : "normal",
    label,
    headline: compactText(headline, 170),
    headlineMono,
    boxes,
    meta,
    requiresFocus:
      riskReasons.length > 0 ||
      (request.message || "").length > 180 ||
      boxes.some((box) => box.text.length > 220),
  };
}

function extractElicitationOptions(schema) {
  if (!schema || typeof schema !== "object" || schema.type !== "object") {
    return null;
  }

  const properties = schema.properties;
  if (!properties || typeof properties !== "object") {
    return null;
  }

  const entries = Object.entries(properties);
  if (entries.length !== 1) {
    return null;
  }

  const [fieldKey, fieldSchema] = entries[0];
  if (!fieldSchema || typeof fieldSchema !== "object") {
    return null;
  }

  const variants = fieldSchema.oneOf || fieldSchema.anyOf;
  if (Array.isArray(variants) && variants.length > 0) {
    const options = variants
      .map((variant) => {
        if (!variant || typeof variant !== "object") return null;
        const value =
          variant.const ??
          variant.enum?.[0] ??
          variant.value ??
          variant.default;
        if (value === undefined) return null;
        return {
          label: variant.title || String(value),
          value,
        };
      })
      .filter(Boolean);

    if (options.length > 0) {
      return { fieldKey, options };
    }
  }

  if (Array.isArray(fieldSchema.enum) && fieldSchema.enum.length > 0) {
    return {
      fieldKey,
      options: fieldSchema.enum.map((value) => ({
        label: String(value),
        value,
      })),
    };
  }

  if (fieldSchema.type === "boolean") {
    return {
      fieldKey,
      options: [
        { label: "Yes", value: true },
        { label: "No", value: false },
      ],
    };
  }

  return null;
}

function extractAskUserQuestions(toolInput) {
  if (!toolInput || typeof toolInput !== "object") {
    return null;
  }

  const questions = toolInput.questions;
  if (!Array.isArray(questions) || questions.length === 0) {
    return null;
  }

  const parsedQuestions = questions
    .map((question, index) => {
      if (!question || typeof question !== "object") {
        return null;
      }

      if (!Array.isArray(question.options) || question.options.length === 0) {
        return null;
      }

      if (typeof question.question !== "string" || !question.question.trim()) {
        return null;
      }

      const options = question.options
        .map((option) => {
          if (!option || typeof option !== "object" || !option.label) {
            return null;
          }
          return {
            label: String(option.label),
            value: String(option.label),
            description:
              typeof option.description === "string" ? option.description : "",
          };
        })
        .filter(Boolean);

      if (options.length === 0) {
        return null;
      }

      return {
        key: question.question,
        header: question.header || `${t("interaction.question")} ${index + 1}`,
        prompt: question.question,
        multiSelect: Boolean(question.multiSelect),
        options,
      };
    })
    .filter(Boolean);

  if (
    parsedQuestions.length !== questions.length ||
    parsedQuestions.length === 0
  ) {
    return null;
  }

  const firstQuestion = parsedQuestions[0];
  return {
    title: firstQuestion.header || payloadSafeToolTitle(toolInput),
    questions: parsedQuestions,
  };
}

function payloadSafeToolTitle(toolInput) {
  if (!toolInput || typeof toolInput !== "object") {
    return "Question";
  }
  const firstQuestion = Array.isArray(toolInput.questions)
    ? toolInput.questions[0]
    : null;
  return firstQuestion?.header || "Question";
}

function normalizeInteractionRequest(payload) {
  const requestId = payload.request_id;
  const kind = payload.kind || "permission";
  const toolInput = payload.tool_input || null;
  const request = {
    requestId,
    kind,
    sessionId: payload.session_id,
    toolName: payload.tool_name || "",
    toolInput,
    title: describeTool(payload.tool_name, toolInput),
    message: payload.message || "",
    cwd: payload.cwd || "",
    mode: payload.mode || null,
    url: payload.url || null,
    requestedSchema: payload.requested_schema || null,
    display: null,
    fieldKey: null,
    questionGroups: [],
    options: [],
    supported: kind === "permission",
    answerMode: kind === "permission" ? "permission" : "elicitation",
    requiresFocus: false,
  };

  if (kind === "permission" && payload.tool_name === "AskUserQuestion") {
    const parsedQuestion = extractAskUserQuestions(toolInput);
    request.supported = Boolean(parsedQuestion);
    request.answerMode = parsedQuestion ? "ask_user_question" : "unsupported";
    request.requiresFocus = true;
    if (parsedQuestion) {
      request.title = parsedQuestion.title;
      request.message = "";
      request.questionGroups = parsedQuestion.questions;
    }
    return request;
  }

  if (kind === "permission") {
    request.display = buildPermissionDisplay(request, payload);
    request.title = request.display.label;
    request.requiresFocus = request.display.requiresFocus;
  }

  if (kind === "elicitation") {
    request.title = payload.mcp_server_name || payload.tool_name || "Question";
    const parsed = extractElicitationOptions(payload.requested_schema);
    request.supported = Boolean(parsed);
    if (parsed) {
      request.fieldKey = parsed.fieldKey;
      request.options = parsed.options;
      request.requiresFocus = parsed.options.length > 3;
    }
  }

  if (kind === "permission" && (request.message || "").length > 180) {
    request.requiresFocus = true;
  }

  return request;
}

function hideInteractionSection() {
  permissionSection.style.display = "none";
  permissionActions.innerHTML = "";
  permissionMessage.textContent = "";
  permissionSection.classList.remove("is-submitting");
  permissionSection.setAttribute("aria-busy", "false");
  delete permissionSection.dataset.requestId;
  delete permissionSection.dataset.kind;
  delete permissionSection.dataset.mode;
  delete permissionSection.dataset.density;
  delete permissionSection.dataset.family;
  delete permissionSection.dataset.risk;
  clearInteractionFocus();
  scheduleExpandedHeightUpdate();
}

function isShowingPendingInteraction() {
  const requestId = permissionSection.dataset.requestId;
  return Boolean(
    permissionSection.style.display !== "none" &&
      requestId &&
      pendingInteractions.has(requestId),
  );
}

function showNextPendingInteraction() {
  const next = pendingInteractions.entries().next().value;
  if (!next) {
    return false;
  }

  const [nextId, nextRequest] = next;
  showInteraction(nextId, nextRequest);
  return true;
}

function setInteractionSubmitting(isSubmitting) {
  permissionSection.classList.toggle("is-submitting", isSubmitting);
  permissionSection.setAttribute("aria-busy", String(isSubmitting));
  permissionActions.querySelectorAll("button").forEach((button) => {
    if (isSubmitting) {
      button.dataset.disabledBeforeSubmit = String(button.disabled);
      button.disabled = true;
    } else if (button.dataset.disabledBeforeSubmit !== undefined) {
      button.disabled = button.dataset.disabledBeforeSubmit === "true";
      delete button.dataset.disabledBeforeSubmit;
    }
  });
}

function renderActionButton({
  label,
  description,
  className,
  onClick,
  parent = permissionActions,
  disabled = false,
  ariaLabel,
  title,
}) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = className;
  button.disabled = disabled;
  if (ariaLabel) {
    button.setAttribute("aria-label", ariaLabel);
  }
  if (title) {
    button.title = title;
  }

  if (description) {
    button.classList.add("has-desc");
    const titleSpan = document.createElement("div");
    titleSpan.className = "btn-title";
    titleSpan.textContent = label;

    const descSpan = document.createElement("div");
    descSpan.className = "btn-desc";
    descSpan.textContent = description;

    button.appendChild(titleSpan);
    button.appendChild(descSpan);
  } else {
    button.textContent = label;
  }

  button.addEventListener("click", (event) => {
    event.stopPropagation();
    if (button.disabled) {
      return;
    }
    button.classList.add("btn-clicked");
    setTimeout(() => {
      button.classList.remove("btn-clicked");
      onClick();
    }, 100);
  });
  parent.appendChild(button);
  return button;
}

function renderIconCornerPermissionActions() {
  const meta = document.createElement("div");
  meta.className = "permission-action-meta";
  meta.textContent = t("permission.scopeOnce");
  permissionActions.appendChild(meta);

  const group = document.createElement("div");
  group.className = "permission-icon-actions";
  permissionActions.appendChild(group);

  renderActionButton({
    label: "✓",
    className: "btn-icon btn-allow",
    parent: group,
    ariaLabel: t("permission.allowAria"),
    title: t("permission.allow"),
    onClick: () => handleInteraction("allow"),
  });
  renderActionButton({
    label: "×",
    className: "btn-icon btn-deny",
    parent: group,
    ariaLabel: t("permission.denyAria"),
    title: t("permission.deny"),
    onClick: () => handleInteraction("deny"),
  });
  renderActionButton({
    label: "↗",
    className: "btn-icon btn-pass",
    parent: group,
    ariaLabel: t("interaction.passThroughAria"),
    title: t("interaction.passThrough"),
    onClick: () => handleInteraction("passthrough"),
  });
}

function renderPermissionDetails(request) {
  const display = request.display;
  permissionMessage.textContent = "";
  permissionMessage.classList.add("permission-detail-stack");

  if (!display) {
    permissionMessage.textContent =
      request.message ||
      (request.supported ? "" : t("interaction.unsupported"));
    return;
  }

  if (display.headline) {
    const headline = document.createElement("div");
    headline.className = "permission-headline";
    if (display.headlineMono) {
      headline.classList.add("mono");
    }
    headline.textContent = display.headline;
    permissionMessage.appendChild(headline);
  }

  display.boxes.forEach((box) => {
    const wrapper = document.createElement("div");
    wrapper.className = "permission-detail-box";
    if (box.tone) {
      wrapper.dataset.tone = box.tone;
    }

    const title = document.createElement("div");
    title.className = "permission-detail-title";
    title.textContent = box.title;
    wrapper.appendChild(title);

    const text = document.createElement("div");
    text.className = "permission-detail-text";
    if (box.mono) {
      text.classList.add("mono");
    }
    text.textContent = box.text;
    wrapper.appendChild(text);

    permissionMessage.appendChild(wrapper);
  });

  if (display.meta.length > 0) {
    const meta = document.createElement("div");
    meta.className = "permission-meta-row";
    display.meta.forEach((item) => {
      const chip = document.createElement("span");
      chip.className = "permission-chip";
      chip.textContent = item;
      meta.appendChild(chip);
    });
    permissionMessage.appendChild(meta);
  }
}

function renderAskUserQuestion(request) {
  const selections = new Map();

  request.questionGroups.forEach((question, questionIndex) => {
    const group = document.createElement("div");
    group.className = "interaction-question";

    const meta = document.createElement("div");
    meta.className = "interaction-question-meta";
    if (request.questionGroups.length > 1) {
      meta.textContent = `${questionIndex + 1}/${request.questionGroups.length}`;
      group.appendChild(meta);
    }

    const prompt = document.createElement("div");
    prompt.className = "interaction-question-text";
    prompt.textContent = question.prompt;
    group.appendChild(prompt);

    const options = document.createElement("div");
    options.className = "interaction-options";
    options.dataset.multiSelect = String(question.multiSelect);
    const layout = getQuestionOptionLayout(question);
    options.dataset.columns = String(layout.columns);
    options.style.gridTemplateColumns = `repeat(${layout.columns}, minmax(0, ${layout.optionWidth}px))`;
    options.style.maxWidth = `${layout.maxWidth}px`;
    options.style.setProperty(
      "--question-option-gap",
      `${QUESTION_OPTION_GAP}px`,
    );
    group.appendChild(options);

    const selectedValues = new Set();

    question.options.forEach((option) => {
      const button = renderActionButton({
        label: option.label,
        description: option.description,
        className: "btn-option",
        parent: options,
        onClick: () => {
          if (question.multiSelect) {
            if (selectedValues.has(option.value)) {
              selectedValues.delete(option.value);
              button.classList.remove("is-selected");
            } else {
              selectedValues.add(option.value);
              button.classList.add("is-selected");
            }
          } else {
            selectedValues.clear();
            selectedValues.add(option.value);
            options
              .querySelectorAll(".btn-option")
              .forEach((optionButton) =>
                optionButton.classList.remove("is-selected"),
              );
            button.classList.add("is-selected");
          }

          selections.set(question.key, {
            multiSelect: question.multiSelect,
            values: Array.from(selectedValues),
          });
          updateSubmitState();
        },
      });
    });

    permissionActions.appendChild(group);
  });

  const footer = document.createElement("div");
  footer.className = "interaction-footer";
  permissionActions.appendChild(footer);

  const submitButton = renderActionButton({
    label: t("interaction.submit"),
    className: "btn-submit",
    parent: footer,
    disabled: true,
    onClick: () => {
      const answers = {};
      request.questionGroups.forEach((question) => {
        const selection = selections.get(question.key);
        answers[question.key] = question.multiSelect
          ? selection.values
          : selection.values[0];
      });
      handleInteraction("allow", { answers });
    },
  });

  renderActionButton({
    label: t("interaction.passThrough"),
    className: "btn-pass",
    parent: footer,
    onClick: () => handleInteraction("passthrough"),
  });

  function updateSubmitState() {
    submitButton.disabled = !request.questionGroups.every((question) => {
      const selection = selections.get(question.key);
      return Boolean(selection && selection.values.length > 0);
    });
  }
}

function showInteraction(requestId, request) {
  applyInteractionFocus(request);
  setInteractionSubmitting(false);
  permissionSection.style.display = "block";
  permissionSection.dataset.requestId = requestId;
  permissionSection.dataset.kind = request.kind;
  permissionSection.dataset.mode = request.answerMode;
  permissionSection.dataset.density = request.requiresFocus
    ? "focus"
    : "default";
  permissionSection.dataset.family = request.display?.family || "";
  permissionSection.dataset.risk = request.display?.riskLevel || "";
  permissionTool.textContent = request.title;
  permissionMessage.className = "permission-message";
  permissionMessage.textContent = "";
  permissionActions.innerHTML = "";

  let renderDefaultPass = true;

  if (request.answerMode === "ask_user_question" && request.supported) {
    renderAskUserQuestion(request);
    renderDefaultPass = false;
  } else if (
    request.kind === "permission" &&
    request.answerMode === "permission"
  ) {
    renderPermissionDetails(request);
    renderIconCornerPermissionActions();
    renderDefaultPass = false;
  } else if (request.supported && request.fieldKey) {
    permissionMessage.textContent =
      request.message ||
      (request.supported ? "" : t("interaction.unsupported"));
    request.options.forEach((option) => {
      renderActionButton({
        label: option.label,
        className: "btn-option",
        onClick: () =>
          handleInteraction("accept", {
            [request.fieldKey]: option.value,
          }),
      });
    });
    renderActionButton({
      label: t("interaction.cancel"),
      className: "btn-deny",
      onClick: () => handleInteraction("cancel"),
    });
  }

  if (renderDefaultPass) {
    permissionMessage.textContent =
      request.message ||
      (request.supported ? "" : t("interaction.unsupported"));
    renderActionButton({
      label: t("interaction.passThrough"),
      className: "btn-pass",
      onClick: () => handleInteraction("passthrough"),
    });
  }

  scheduleExpandedHeightUpdate();
}

function getPendingInteractionForSession(sessionId) {
  for (const request of pendingInteractions.values()) {
    if (request.sessionId === sessionId) {
      return request;
    }
  }
  return null;
}

async function handleInteraction(decision, content = null) {
  const requestId = permissionSection.dataset.requestId;
  if (!requestId) return;

  setInteractionSubmitting(true);
  try {
    await invokeCommand("permission_decision", {
      permId: requestId,
      decision: decision,
      reason: null,
      content,
    });
    pendingInteractions.delete(requestId);

    if (!showNextPendingInteraction()) {
      hideInteractionSection();
      settleAfterInteractionsComplete();
    }
  } catch (e) {
    console.error("[Orbit] Failed to submit interaction decision:", e);
    setInteractionSubmitting(false);
  }
}

async function handleOnboardingRetry() {
  onboardingRetryPending = true;
  renderOnboardingSection();

  try {
    await invokeCommand("retry_onboarding_install");
  } catch (e) {
    onboardingRetryPending = false;
    renderOnboardingSection();
    console.error("Failed to retry onboarding:", e);
  }
}

// Hover interaction: mouseenter to expand, mouseleave to collapse with debounce
function handleHoverEnter() {
  hoverInside = true;
  requestExpand();
}

function handleHoverLeave() {
  hoverInside = false;
  if (collapseDebounceTimer) {
    clearTimeout(collapseDebounceTimer);
  }
  collapseDebounceTimer = setTimeout(() => {
    collapseDebounceTimer = null;

    if (hoverInside) {
      return;
    }

    if (pendingInteractions.size > 0) {
      return;
    }

    wantExpanded = false;
    if (isExpanded && !isAnimating) {
      collapseIsland();
    }
  }, COLLAPSE_DELAY);
}

island.addEventListener("mouseenter", handleHoverEnter);
island.addEventListener("mouseleave", handleHoverLeave);
listen("island-hover-enter", handleHoverEnter);
listen("island-hover-leave", handleHoverLeave);

async function expandIsland() {
  if (isAnimating) return;
  isAnimating = true;
  isExpanded = true;
  collapseAfterTransition = false;
  clearAnimationFallback();

  // Elevator: expand native window FIRST, then CSS animation fills it.
  await applyExpandedFrame(getExpandedWidth(), getExpandedMaxHeight());

  // Wait one frame so the window resize is applied before CSS transition starts
  requestAnimationFrame(() => {
    island.classList.remove("collapsed");
    island.classList.add("expanded");
    island.setAttribute("aria-expanded", "true");
    scheduleExpandedHeightUpdate();
    scheduleAnimationFallback(() => {
      reconcileExpandState();
    });
  });

  renderActiveSessions();
  renderHistory(cachedHistory);
  refreshHistoryCache();
}

async function collapseIsland() {
  if (isAnimating) return;
  isAnimating = true;
  isExpanded = false;
  collapseAfterTransition = true;
  island.setAttribute("aria-expanded", "false");

  const currentHeight = island.getBoundingClientRect().height;
  island.style.height = `${currentHeight}px`;

  requestAnimationFrame(() => {
    island.style.height = `${notchInfo.notch_height || 37}px`;
  });

  scheduleAnimationFallback(async () => {
    if (collapseAfterTransition) {
      await finishCollapse();
    }
    reconcileExpandState();
  });
}

async function finishCollapse() {
  collapseAfterTransition = false;
  clearAnimationFallback();

  // Now swap class and clean up inline style
  island.classList.remove("expanded");
  island.classList.add("collapsed");
  island.style.height = "";
  island.style.removeProperty("--expanded-height");
  lastExpandedFrame = { width: null, height: null };

  // THEN shrink native window (elevator: door closes after you're inside)
  try {
    await invokeCommand("collapse_window");
  } catch (e) {
    console.error("Failed to collapse window:", e);
  }
}

function scheduleExpandedHeightUpdate() {
  requestAnimationFrame(() => {
    if (!isExpanded || !detail) return;

    const notchHeight = notchInfo.notch_height || 37;
    const minExpandedHeight = notchHeight + 152;
    const maxExpandedHeight = getExpandedMaxHeight();
    const contentHeight = notchHeight + detail.scrollHeight;
    const nextHeight = Math.min(
      maxExpandedHeight,
      Math.max(minExpandedHeight, contentHeight),
    );

    island.style.setProperty("--expanded-height", `${nextHeight}px`);
    applyExpandedFrame(getExpandedWidth(), nextHeight);
  });
}

function renderActiveSessions() {
  if (!activeList) return;
  activeList.innerHTML = "";

  const treeData = buildSessionTree(sessions, activeSessionId);
  const counts = getSessionCounts(sessions);

  if (treeData.length === 0) {
    const empty = document.createElement("div");
    empty.className = "active-item empty";
    empty.textContent = t("session.noActive");
    activeList.appendChild(empty);
    scheduleExpandedHeightUpdate();
    return;
  }

  if (sessionTree) {
    sessionTree.destroy();
  }

  const treeContainer = document.createElement("div");
  treeContainer.id = "session-tree-container";
  treeContainer.className = "session-tree-container";
  activeList.appendChild(treeContainer);

  sessionTree = new SessionTree({
    container: treeContainer,
    sessions: treeData,
    activeSessionId: activeSessionId?.slice(-4),
    onSessionClick: (session) => {
      console.log("Session clicked:", session.id);
    },
    compact: false,
  });

  scheduleExpandedHeightUpdate();
}

function getStatusLabel(status) {
  switch (status.type) {
    case "Processing":
      return t("sessionStatus.thinking");
    case "RunningTool":
      return t("sessionStatus.running");
    case "WaitingForApproval":
      return t("sessionStatus.approve");
    case "Anomaly":
      return t("sessionStatus.stuck");
    case "Compacting":
      return t("sessionStatus.compacting");
    case "WaitingForInput":
      return t("sessionStatus.idle");
    default:
      return status.type.toLowerCase();
  }
}

function renderHistory(entries) {
  historyList.innerHTML = "";
  if (!entries || entries.length === 0) {
    const empty = document.createElement("div");
    empty.className = "history-item empty";
    empty.textContent = t("session.noHistory");
    historyList.appendChild(empty);
    scheduleExpandedHeightUpdate();
    return;
  }

  // Filter entries from last 3 hours only (recent sessions more likely to be resumed)
  const THREE_HOURS_MS = 3 * 60 * 60 * 1000;
  const now = Date.now();
  const recentEntries = entries.filter((entry) => {
    const endedTime = new Date(entry.ended_at).getTime();
    return now - endedTime <= THREE_HOURS_MS;
  });

  if (recentEntries.length === 0) {
    const empty = document.createElement("div");
    empty.className = "history-item empty";
    empty.textContent = t("session.noRecent");
    historyList.appendChild(empty);
    scheduleExpandedHeightUpdate();
    return;
  }

  recentEntries.reverse().forEach((entry) => {
    const div = document.createElement("div");
    div.className = "history-item";
    div.style.cursor = "pointer";

    const cwdSpan = document.createElement("span");
    cwdSpan.className = "history-cwd";
    const projectName = entry.cwd.split("/").pop() || entry.cwd;
    cwdSpan.textContent = projectName;

    const titleSpan = document.createElement("span");
    titleSpan.className = "history-title";
    titleSpan.textContent = entry.title || t("session.untitled");

    const metricsSpan = createHistoryTokenMetrics(entry);

    div.appendChild(cwdSpan);
    div.appendChild(titleSpan);
    div.appendChild(metricsSpan);

    // Click to resume session in terminal
    div.addEventListener("click", () =>
      resumeSession(entry.session_id, entry.cwd),
    );

    historyList.appendChild(div);
  });

  scheduleExpandedHeightUpdate();
}

function createHistoryTokenMetrics(entry) {
  const input = Math.max(0, Number(entry.tokens_in) || 0);
  const output = Math.max(0, Number(entry.tokens_out) || 0);
  const durationSecs = Math.max(0, Number(entry.duration_secs) || 0);
  const outputRate = durationSecs > 0 ? output / durationSecs : 0;
  const metrics = [
    ["token-metric-in", `↑${formatCompactTokenCount(input)}`],
    ["token-metric-out", `↓${formatCompactTokenCount(output)}`],
    ["token-metric-rate", `↓${formatCompactTokenRate(outputRate)}`],
  ];

  const metricsSpan = document.createElement("span");
  metricsSpan.className = "history-metrics token-metrics";
  metricsSpan.setAttribute("aria-label", "Token metrics");

  metrics.forEach(([className, text]) => {
    const metric = document.createElement("span");
    metric.className = `token-metric ${className}`;
    metric.textContent = text;
    metricsSpan.appendChild(metric);
  });

  return metricsSpan;
}

async function resumeSession(sessionId, cwd) {
  try {
    await invokeCommand("resume_session", { sessionId, cwd });
    // Close the expanded island after triggering resume
    if (isExpanded) {
      collapseIsland();
    }
  } catch (e) {
    console.error("Failed to resume session:", e);
    alert(`Failed to resume session: ${e.message || e}`);
  }
}

// Connection state tracking (IMPL-07)
let isConnected = false;

listen("connection-count", (event) => {
  const count = event.payload;
  isConnected = count > 0;
  refreshUI();
});

// Boot
init();

// Export functions for HTML inline event handlers (ES6 module scope isolation)
window.collapseIsland = collapseIsland;
window.handleOnboardingRetry = handleOnboardingRetry;
