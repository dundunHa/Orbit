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

const { listen } = window.__TAURI__.event;
const { invoke } = window.__TAURI__.core;

// State
let sessions = {}; // All sessions keyed by session_id
let activeSessionId = null;
let isExpanded = false;
let isAnimating = false; // IMPL-06: animation lock
const pendingPerms = new Map(); // IMPL-05: Map<permId, {sessionId, toolName, toolInput}>
let sessionTree = null;

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
const detail = document.querySelector(".detail");
const activeList = document.querySelector(".active-list");
const permissionSection = document.querySelector(".permission-section");
const permissionTool = document.querySelector(".permission-tool");
const historyList = document.querySelector(".history-list");
const mascot = document.querySelector(".mascot");
const DEFAULT_PROVIDER = "claude-code";

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

island.addEventListener("transitionend", async (e) => {
  if (e.target === island && e.propertyName === "height") {
    if (collapseAfterTransition) {
      await finishCollapse();
    }
    isAnimating = false;
  }
});

// Initialize: load notch info, set layout, load sessions
async function init() {
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

  // First-run onboarding
  if (!localStorage.getItem("orbit-onboarded")) {
    localStorage.setItem("orbit-onboarded", "1");
    mascot.classList.add("onboarding");
    statusText.textContent = "Hi! I'm Orbit";
    setTimeout(() => {
      mascot.classList.remove("onboarding");
      statusText.textContent = "Waiting...";
    }, 2000);
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

  if (best) {
    activeSessionId = best.id;
    updateUI(best);
  }
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
      statusText.textContent = "Thinking...";
      break;
    case "RunningTool":
      statusDot.classList.add("running-tool");
      statusText.textContent = formatTool(status.tool_name, status.description);
      break;
    case "WaitingForApproval":
      statusDot.classList.add("waiting-approval");
      statusText.textContent = "Approve?";
      break;
    case "Anomaly":
      statusDot.classList.add("anomaly");
      statusText.textContent = "Stuck? (" + status.idle_seconds + "s)";
      break;
    case "Compacting":
      statusDot.classList.add("processing");
      statusText.textContent = "Compacting...";
      break;
    case "Ended":
      statusDot.classList.add("ended");
      statusText.textContent = "Ended";
      break;
    case "WaitingForInput":
    default:
      statusDot.classList.add("idle");
      statusText.textContent = "Idle";
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
      return "$ Running...";
    case "Read":
      return "Reading...";
    case "Edit":
      return "Editing...";
    case "Write":
      return "Writing...";
    case "Grep":
      return "Searching...";
    case "Glob":
      return "Finding...";
    case "Agent":
      return "Agent...";
    default:
      return (toolName || "") + "...";
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

function toggleExpand() {
  if (isAnimating) return; // IMPL-06: prevent rapid clicks
  if (isExpanded) {
    collapseIsland();
  } else {
    expandIsland();
  }
}

async function expandIsland() {
  if (isAnimating) return;
  isAnimating = true;
  isExpanded = true;
  collapseAfterTransition = false;
  if (collapseFallbackTimer) {
    clearTimeout(collapseFallbackTimer);
    collapseFallbackTimer = null;
  }

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

  // Elevator: CSS animation FIRST (keep expanded class for transition + detail visible)
  // Set target height via inline style; CSS transition on .expanded handles the animation
  island.style.height = "var(--notch-height, 37px)";

  // Fallback: if transitionend doesn't fire within 400ms, force completion
  collapseFallbackTimer = setTimeout(() => {
    if (collapseAfterTransition) {
      finishCollapse();
      isAnimating = false;
    }
  }, 400);
}

async function finishCollapse() {
  collapseAfterTransition = false;
  if (collapseFallbackTimer) {
    clearTimeout(collapseFallbackTimer);
    collapseFallbackTimer = null;
  }

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
    empty.textContent = "No active sessions";
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
      return "thinking";
    case "RunningTool":
      return "running";
    case "WaitingForApproval":
      return "approve?";
    case "Anomaly":
      return "stuck";
    case "Compacting":
      return "compacting";
    case "WaitingForInput":
      return "idle";
    default:
      return status.type.toLowerCase();
  }
}

function renderHistory(entries) {
  historyList.innerHTML = "";
  if (!entries || entries.length === 0) {
    const empty = document.createElement("div");
    empty.className = "history-item empty";
    empty.textContent = "No history yet";
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
    empty.textContent = "No recent sessions (last 3h)";
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
    titleSpan.textContent = entry.title || "Untitled";

    const timeSpan = document.createElement("span");
    timeSpan.className = "history-time";
    timeSpan.textContent = formatDuration(entry.duration_secs);

    div.appendChild(cwdSpan);
    div.appendChild(titleSpan);
    div.appendChild(timeSpan);

    // Click to resume session in terminal
    div.addEventListener("click", () => resumeSession(entry.session_id, entry.cwd));

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
  if (!isConnected && !isExpanded) {
    const hasActiveSessions = Object.values(sessions).some(
      (s) => s.status.type !== "Ended",
    );
    if (!hasActiveSessions) {
      statusDot.className = "status-dot disconnected";
      setMascotVariant(null, "WaitingForInput");
      statusText.textContent = "No connections";
    }
  }
});

// Boot
init();

// Export functions for HTML inline event handlers (ES6 module scope isolation)
window.toggleExpand = toggleExpand;
window.collapseIsland = collapseIsland;
window.handlePermission = handlePermission;
