// Orbit — Dynamic Island Frontend
// Tauri IPC bridge

import { SessionTree } from "./components/SessionTree/index.js";
import {
  buildSessionTree,
  formatTokenCount,
  formatTokenRate,
  getSessionCounts,
  getSessionTokenStats,
} from "./utils/sessionTransform.js";
import { t, getLocale } from "./utils/i18n.js";

const { listen } = window.__TAURI__.event;
const { invoke } = window.__TAURI__.core;

// State
let sessions = {}; // All sessions keyed by session_id
let activeSessionId = null;
let isExpanded = false;
let isAnimating = false; // IMPL-06: animation lock
const pendingPerms = new Map(); // IMPL-05: Map<permId, {sessionId, toolName, toolInput}>
let sessionTree = null;
let onboardingState = null;
let onboardingRetryPending = false;
let collapseDebounceTimer = null;
let wantExpanded = false; // 鼠标期望状态，动画结束后据此对账
const COLLAPSE_DELAY = 300; // ms, hover 离开后延迟收起防抖

listen("screen-changed", (event) => {
  const info = event.payload;
  if (!info || typeof info.notch_height !== 'number') {
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
const historyList = document.querySelector(".history-list");
const mascot = document.querySelector(".mascot");
const DEFAULT_PROVIDER = "claude-code";

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
  }, 450);
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
    notchInfo = await invoke("get_notch_info");
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
    const currentOnboarding = await invoke("get_onboarding_state");
    setOnboardingState(currentOnboarding);
  } catch (e) {
    console.error("Failed to load onboarding state:", e);
  }

  try {
    const existing = await invoke("get_sessions");
    for (const s of existing) {
      sessions[s.id] = s;
    }
    selectActiveSession();
  } catch (e) {
    console.error("Failed to load sessions:", e);
  }
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

  selectActiveSession();

  if (isExpanded) {
    renderActiveSessions();
  }
});

listen("onboarding-state-changed", (event) => {
  setOnboardingState(event.payload);
});

// Listen for permission requests
listen("permission-request", (event) => {
  const { perm_id, session_id, tool_name, tool_input } = event.payload;
  pendingPerms.set(perm_id, {
    sessionId: session_id,
    toolName: tool_name,
    toolInput: tool_input,
  });
  showPermission(tool_name, tool_input, perm_id);
  if (!isExpanded) {
    expandIsland();
  }
});

// Listen for permission timeout — clean up stale UI
listen("permission-timeout", (event) => {
  const permId = event.payload;
  pendingPerms.delete(permId);
  if (permissionSection.dataset.permId === permId) {
    if (pendingPerms.size > 0) {
      const [nextId, next] = pendingPerms.entries().next().value;
      showPermission(next.toolName, next.toolInput, nextId);
    } else {
      permissionSection.style.display = "none";
      delete permissionSection.dataset.permId;
    }
  }
});

listen("permission-resolved", (event) => {
  const permId = event.payload;
  pendingPerms.delete(permId);
  if (permissionSection.dataset.permId === permId) {
    if (pendingPerms.size > 0) {
      const [nextId, next] = pendingPerms.entries().next().value;
      showPermission(next.toolName, next.toolInput, nextId);
    } else {
      permissionSection.style.display = "none";
      delete permissionSection.dataset.permId;
      if (isExpanded) {
        collapseIsland();
      }
    }
  }
});

function getActiveSession() {
  return activeSessionId ? sessions[activeSessionId] || null : null;
}

function hasLiveSessions() {
  return Object.values(sessions).some((session) => session.status.type !== "Ended");
}

function getOnboardingView(state) {
  if (!state || !state.type) {
    return null;
  }

  const config = ONBOARDING_STATUS_MAP[state.type] || ONBOARDING_STATUS_MAP.Error;
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
  statusText.textContent = text;
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
  onboardingStatusText.textContent = view?.text || t("onboarding.requiresAttention");

  if (onboardingRetryButton) {
    const showRetry = Boolean(view?.canRetry);
    onboardingRetryButton.style.display = showRetry ? "block" : "none";
    onboardingRetryButton.disabled = onboardingRetryPending;
    onboardingRetryButton.textContent = onboardingRetryPending ? t("onboarding.retrying") : t("onboarding.retry");
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

  // Update dot color
  statusDot.className = "status-dot";
  setMascotVariant(activeToolName, statusType);

  switch (statusType) {
    case "Processing":
      statusDot.classList.add("processing");
      statusText.textContent = t("status.thinking");
      break;
    case "RunningTool":
      statusDot.classList.add("running-tool");
      statusText.textContent = formatTool(status.tool_name, status.description);
      break;
    case "WaitingForApproval":
      statusDot.classList.add("waiting-approval");
      statusText.textContent = t("status.approve");
      break;
    case "Anomaly":
      statusDot.classList.add("anomaly");
      statusText.textContent = t("status.stuck", { seconds: status.idle_seconds });
      break;
    case "Compacting":
      statusDot.classList.add("processing");
      statusText.textContent = t("status.compacting");
      break;
    case "Ended":
      statusDot.classList.add("ended");
      statusText.textContent = t("status.ended");
      break;
    case "WaitingForInput":
    default:
      statusDot.classList.add("idle");
      statusText.textContent = t("status.idle");
      break;
  }

  // Detail view
  if (isExpanded) {
    const cwdShort = session.cwd.split("/").slice(-2).join("/");
    // sessionCwd.textContent = cwdShort;
    detailStatus.textContent = statusText.textContent;
    // detailTools.textContent = session.tool_count + ' tool calls this session';

    const tokenStats = getSessionTokenStats(session);
    detailTokens.textContent =
      `${formatTokenCount(tokenStats.input)} in · ` +
      `${formatTokenCount(tokenStats.output)} out · ` +
      `${formatTokenCount(tokenStats.total)} total`;

    const rateLabel =
      tokenStats.durationSecs > 0
        ? `${formatTokenRate(tokenStats.averageTotalTps)} avg`
        : "—";
    detailModel.textContent = `${rateLabel} · ${session.model || "—"}`;
  }

  // Hide permission section if no pending perms for active session
  if (statusType !== "WaitingForApproval") {
    for (const [pid, p] of pendingPerms) {
      if (p.sessionId === session.id) {
        pendingPerms.delete(pid);
      }
    }
    if (pendingPerms.size === 0) {
      permissionSection.style.display = "none";
    }
  }
}

function setMascotVariant(toolName, statusType) {
  const provider = detectProvider(toolName);
  mascot.className = `mascot mascot-${provider}`;

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

function showPermission(toolName, toolInput, permId) {
  permissionSection.style.display = "block";
  permissionSection.dataset.permId = permId;
  let desc = toolName || "Unknown";
  if (toolInput && typeof toolInput === "object") {
    if (toolInput.command) {
      desc = toolName + ": " + toolInput.command.substring(0, 80);
    } else if (toolInput.file_path) {
      const file = toolInput.file_path.split("/").pop();
      desc = toolName + ": " + file;
    }
  }
  permissionTool.textContent = desc;
}

async function handlePermission(decision) {
  const permId = permissionSection.dataset.permId;
  if (!permId) return;
  await invoke("permission_decision", {
    perm_id: permId,
    decision: decision,
    reason: null,
  });
  pendingPerms.delete(permId);
  permissionSection.style.display = "none";
  delete permissionSection.dataset.permId;

  if (pendingPerms.size > 0) {
    const [nextId, next] = pendingPerms.entries().next().value;
    showPermission(next.toolName, next.toolInput, nextId);
  }
}


async function handleOnboardingRetry() {
  onboardingRetryPending = true;
  renderOnboardingSection();

  try {
    await invoke("retry_onboarding_install");
  } catch (e) {
    onboardingRetryPending = false;
    renderOnboardingSection();
    console.error("Failed to retry onboarding:", e);
  }
}

// Hover interaction: mouseenter to expand, mouseleave to collapse with debounce
island.addEventListener("mouseenter", () => {
  if (collapseDebounceTimer) {
    clearTimeout(collapseDebounceTimer);
    collapseDebounceTimer = null;
  }
  wantExpanded = true;
  if (!isExpanded && !isAnimating) {
    expandIsland();
  }
});

island.addEventListener("mouseleave", () => {
  if (collapseDebounceTimer) {
    clearTimeout(collapseDebounceTimer);
  }
  collapseDebounceTimer = setTimeout(() => {
    collapseDebounceTimer = null;
    wantExpanded = false;
    if (isExpanded && !isAnimating) {
      collapseIsland();
    }
  }, COLLAPSE_DELAY);
});

async function expandIsland() {
  if (isAnimating) return;
  isAnimating = true;
  isExpanded = true;
  collapseAfterTransition = false;
  clearAnimationFallback();

  // Elevator: expand native window FIRST, then CSS animation fills it
  try {
    await invoke("expand_window");
  } catch (e) {
    console.error("Failed to expand window:", e);
  }

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

  try {
    const history = await invoke("get_history");
    renderHistory(history);
  } catch (e) {
    console.error("Failed to load history:", e);
  }
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

  // THEN shrink native window (elevator: door closes after you're inside)
  try {
    await invoke("collapse_window");
  } catch (e) {
    console.error("Failed to collapse window:", e);
  }
}

function scheduleExpandedHeightUpdate() {
  requestAnimationFrame(() => {
    if (!isExpanded || !detail) return;

    const notchHeight = notchInfo.notch_height || 37;
    const minExpandedHeight = notchHeight + 152;
    const maxExpandedHeight = 320;
    const contentHeight = notchHeight + detail.scrollHeight;
    const nextHeight = Math.min(
      maxExpandedHeight,
      Math.max(minExpandedHeight, contentHeight),
    );

    island.style.setProperty("--expanded-height", `${nextHeight}px`);
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
    div.title = `Click to resume session in ${entry.cwd}`;

    const cwdSpan = document.createElement("span");
    cwdSpan.className = "history-cwd";
    const projectName = entry.cwd.split("/").pop() || entry.cwd;
    cwdSpan.textContent = projectName;

    const titleSpan = document.createElement("span");
    titleSpan.className = "history-title";
    titleSpan.textContent = entry.title || t("session.untitled");

    const timeSpan = document.createElement("span");
    timeSpan.className = "history-time";
    timeSpan.textContent = formatDuration(entry.duration_secs);

    div.appendChild(cwdSpan);
    div.appendChild(titleSpan);
    div.appendChild(timeSpan);

    // Click to resume session in terminal
    div.addEventListener("click", () =>
      resumeSession(entry.session_id, entry.cwd),
    );

    historyList.appendChild(div);
  });

  scheduleExpandedHeightUpdate();
}

async function resumeSession(sessionId, cwd) {
  try {
    await invoke("resume_session", { session_id: sessionId, cwd });
    // Close the expanded island after triggering resume
    if (isExpanded) {
      collapseIsland();
    }
  } catch (e) {
    console.error("Failed to resume session:", e);
    alert(`Failed to resume session: ${e.message || e}`);
  }
}

function formatDuration(secs) {
  if (!secs || secs < 0) return "0s";
  if (secs < 60) return secs + "s";
  if (secs < 3600) return Math.floor(secs / 60) + "m";
  return Math.floor(secs / 3600) + "h " + Math.floor((secs % 3600) / 60) + "m";
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
window.handlePermission = handlePermission;
window.handleOnboardingRetry = handleOnboardingRetry;
