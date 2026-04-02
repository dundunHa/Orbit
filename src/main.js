// Orbit — Dynamic Island Frontend
// Tauri IPC bridge

const { listen } = window.__TAURI__.event;
const { invoke } = window.__TAURI__.core;

// State
let sessions = {};   // All sessions keyed by session_id
let activeSessionId = null;
let isExpanded = false;
let isAnimating = false; // IMPL-06: animation lock
const pendingPerms = new Map(); // IMPL-05: Map<permId, {sessionId, toolName, toolInput}>
let recentHistoryEntries = [];
let expandedHeightFrame = null;

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
};

// DOM elements
const island = document.getElementById('island');
const statusDot = document.querySelector('.status-dot');
const statusText = document.querySelector('.status-text');
const sessionCwd = document.querySelector('.session-cwd');
const detailStatus = document.querySelector('.detail-status');
const detailTools = document.querySelector('.detail-tools');
const activeSummary = document.querySelector('.active-summary');
const permissionSection = document.querySelector('.permission-section');
const permissionTool = document.querySelector('.permission-tool');
const historyList = document.querySelector('.history-list');
const mascot = document.querySelector('.mascot');
const DEFAULT_PROVIDER = 'claude-code';
const MIN_EXPANDED_HEIGHT = 168;
const MAX_EXPANDED_HEIGHT = 320;

// Status priority for selecting which session to display
const STATUS_PRIORITY = {
  'WaitingForApproval': 6,
  'Anomaly': 5,
  'RunningTool': 4,
  'Processing': 3,
  'Compacting': 2,
  'WaitingForInput': 1,
  'Ended': 0,
};

// IMPL-06 + IMPL-08: transitionend handles animation lock + collapse window resize
let collapseAfterTransition = false;
let collapseFallbackTimer = null;

island.addEventListener('transitionend', (e) => {
  if (e.target === island && e.propertyName === 'height') {
    if (collapseAfterTransition) {
      finishCollapse();
    }
    isAnimating = false;
  }
});

// Initialize: load notch info, set layout, load sessions
async function init() {
  try {
    notchInfo = await invoke('get_notch_info');
  } catch (e) {
    console.error('Failed to get notch info:', e);
  }

  // Set CSS custom properties for three-zone layout
  const root = document.documentElement;
  root.style.setProperty('--notch-height', notchInfo.notch_height + 'px');
  root.style.setProperty('--pill-width', notchInfo.pill_width + 'px');
  root.style.setProperty('--expanded-height', MAX_EXPANDED_HEIGHT + 'px');

  const layout = computePillLayout(notchInfo);
  root.style.setProperty('--notch-width', layout.centerWidth + 'px');
  root.style.setProperty('--zone-left-width', layout.leftWidth + 'px');
  root.style.setProperty('--zone-right-width', layout.rightWidth + 'px');

  // First-run onboarding
  if (!localStorage.getItem('orbit-onboarded')) {
    localStorage.setItem('orbit-onboarded', '1');
    mascot.classList.add('onboarding');
    statusText.textContent = 'Hi! I\'m Orbit';
    setTimeout(() => {
      mascot.classList.remove('onboarding');
      statusText.textContent = 'Waiting...';
    }, 2000);
  }

  try {
    const existing = await invoke('get_sessions');
    for (const s of existing) {
      sessions[s.id] = s;
    }
    selectActiveSession();
  } catch (e) {
    console.error('Failed to load sessions:', e);
  }
}

function computePillLayout(info) {
  if (!info.has_notch) {
    const centerWidth = 20;
    const sideWidth = Math.floor((info.pill_width - centerWidth) / 2);
    return {
      leftWidth: sideWidth,
      centerWidth,
      rightWidth: info.pill_width - centerWidth - sideWidth,
    };
  }

  const windowLeft = (info.screen_width - info.pill_width) / 2;
  const centerLeft = clamp(info.notch_left - windowLeft, 0, info.pill_width);
  const centerRight = clamp(info.notch_right - windowLeft, centerLeft, info.pill_width);

  return {
    leftWidth: Math.floor(centerLeft),
    centerWidth: Math.floor(centerRight - centerLeft),
    rightWidth: Math.floor(info.pill_width - centerRight),
  };
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function getSessionPriority(session) {
  return STATUS_PRIORITY[session.status.type] ?? -1;
}

function getSessionTimestamp(session) {
  const timestamp = Date.parse(session.last_event_at || '');
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

function compareSessions(a, b) {
  const priorityDiff = getSessionPriority(b) - getSessionPriority(a);
  if (priorityDiff !== 0) return priorityDiff;
  return getSessionTimestamp(b) - getSessionTimestamp(a);
}

function getActiveSessions() {
  return Object.values(sessions)
    .filter((session) => session.status.type !== 'Ended')
    .sort(compareSessions);
}

function formatOtherActiveSummary(count) {
  return count === 1 ? '另外 1 个活动会话' : `另外 ${count} 个活动会话`;
}

function getVisibleRecentCount() {
  return recentHistoryEntries.length;
}

function computeExpandedHeight() {
  const activeCount = getActiveSessions().length;
  const recentCount = getVisibleRecentCount();
  const hasPermission = permissionSection.style.display !== 'none';

  let height = notchInfo.notch_height;
  height += 92; // detail padding + header
  height += activeCount > 0 ? 62 : 46; // active block
  height += recentCount > 0 ? 26 + recentCount * 24 : 44; // recent block or empty state

  if (hasPermission) {
    height += 82;
  }

  return Math.max(MIN_EXPANDED_HEIGHT, Math.min(MAX_EXPANDED_HEIGHT, Math.ceil(height)));
}

function scheduleExpandedHeightSync() {
  if (!isExpanded) return;

  if (expandedHeightFrame) {
    cancelAnimationFrame(expandedHeightFrame);
  }

  expandedHeightFrame = requestAnimationFrame(async () => {
    expandedHeightFrame = null;
    const height = computeExpandedHeight();
    document.documentElement.style.setProperty('--expanded-height', `${height}px`);

    try {
      await invoke('set_expanded_height', { height });
    } catch (e) {
      console.error('Failed to sync expanded height:', e);
    }
  });
}

function selectActiveSession() {
  const activeSessions = getActiveSessions();
  const best = activeSessions[0] || null;

  if (best) {
    activeSessionId = best.id;
    updateUI(best);
    return;
  }

  activeSessionId = null;
  updateUI(null);
}

// Listen for session updates from Rust backend
listen('session-update', (event) => {
  const session = event.payload;
  const prev = sessions[session.id];
  sessions[session.id] = session;

  // IMPL-04: Stop event -> completion flash
  if (prev && prev.status.type !== 'WaitingForInput' && prev.status.type !== 'Ended'
      && (session.status.type === 'WaitingForInput' || session.status.type === 'Ended')) {
    island.classList.add('flash-complete');
    setTimeout(() => island.classList.remove('flash-complete'), 600);
  }

  selectActiveSession();

  if (isExpanded && prev?.status.type !== 'Ended' && session.status.type === 'Ended') {
    refreshRecentHistory();
  }
});

// Listen for permission requests
listen('permission-request', (event) => {
  const { perm_id, session_id, tool_name, tool_input } = event.payload;
  pendingPerms.set(perm_id, { sessionId: session_id, toolName: tool_name, toolInput: tool_input });
  showPermission(tool_name, tool_input, perm_id);
  if (!isExpanded) {
    expandIsland();
  } else {
    scheduleExpandedHeightSync();
  }
});

// Listen for permission timeout — clean up stale UI
listen('permission-timeout', (event) => {
  const permId = event.payload;
  pendingPerms.delete(permId);
  if (permissionSection.dataset.permId === permId) {
    if (pendingPerms.size > 0) {
      const [nextId, next] = pendingPerms.entries().next().value;
      showPermission(next.toolName, next.toolInput, nextId);
    } else {
      permissionSection.style.display = 'none';
      delete permissionSection.dataset.permId;
      scheduleExpandedHeightSync();
    }
  }
});

function updateUI(session) {
  if (!session) {
    statusDot.className = 'status-dot';
    setMascotVariant(null, 'WaitingForInput');
    sessionCwd.textContent = 'No active session';
    detailStatus.textContent = 'No active sessions';
    detailTools.textContent = '';
    activeSummary.textContent = '';

    if (isConnected) {
      statusDot.classList.add('ended');
      statusText.textContent = 'No active';
    } else {
      statusDot.classList.add('disconnected');
      statusText.textContent = 'No connections';
    }
    scheduleExpandedHeightSync();
    return;
  }

  const status = session.status;
  const statusType = status.type;
  const activeToolName = statusType === 'RunningTool' ? status.tool_name : null;

  // Update dot color
  statusDot.className = 'status-dot';
  setMascotVariant(activeToolName, statusType);

  switch (statusType) {
    case 'Processing':
      statusDot.classList.add('processing');
      statusText.textContent = 'Thinking...';
      break;
    case 'RunningTool':
      statusDot.classList.add('running-tool');
      statusText.textContent = formatTool(status.tool_name, status.description);
      break;
    case 'WaitingForApproval':
      statusDot.classList.add('waiting-approval');
      statusText.textContent = 'Approve?';
      break;
    case 'Anomaly':
      statusDot.classList.add('anomaly');
      statusText.textContent = 'Stuck? (' + status.idle_seconds + 's)';
      break;
    case 'Compacting':
      statusDot.classList.add('processing');
      statusText.textContent = 'Compacting...';
      break;
    case 'Ended':
      statusDot.classList.add('ended');
      statusText.textContent = 'Ended';
      break;
    case 'WaitingForInput':
    default:
      statusDot.classList.add('idle');
      statusText.textContent = 'Idle';
      break;
  }

  // Detail view
  if (isExpanded) {
    const activeSessions = getActiveSessions();
    const otherActiveCount = Math.max(0, activeSessions.length - 1);
    const cwdShort = session.cwd.split('/').slice(-2).join('/');
    sessionCwd.textContent = cwdShort;
    detailStatus.textContent = statusText.textContent;
    detailTools.textContent = session.tool_count + ' tool calls this session';
    activeSummary.textContent = otherActiveCount > 0 ? formatOtherActiveSummary(otherActiveCount) : '';
  }

  // Hide permission section if no pending perms for active session
  if (statusType !== 'WaitingForApproval') {
    for (const [pid, p] of pendingPerms) {
      if (p.sessionId === session.id) {
        pendingPerms.delete(pid);
      }
    }
    if (pendingPerms.size === 0) {
      permissionSection.style.display = 'none';
    }
  }

  scheduleExpandedHeightSync();
}

function setMascotVariant(toolName, statusType) {
  const provider = detectProvider(toolName);
  mascot.className = `mascot mascot-${provider}`;

  if (statusType === 'Processing' || statusType === 'RunningTool' || statusType === 'Compacting') {
    mascot.classList.add('processing');
  }

  if (statusType === 'WaitingForApproval' || statusType === 'Anomaly') {
    mascot.classList.add('approval');
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
    case 'Bash': return '$ Running...';
    case 'Read': return 'Reading...';
    case 'Edit': return 'Editing...';
    case 'Write': return 'Writing...';
    case 'Grep': return 'Searching...';
    case 'Glob': return 'Finding...';
    case 'Agent': return 'Agent...';
    default: return (toolName || '') + '...';
  }
}

function showPermission(toolName, toolInput, permId) {
  permissionSection.style.display = 'block';
  permissionSection.dataset.permId = permId;
  let desc = toolName || 'Unknown';
  if (toolInput && typeof toolInput === 'object') {
    if (toolInput.command) {
      desc = toolName + ': ' + toolInput.command.substring(0, 80);
    } else if (toolInput.file_path) {
      const file = toolInput.file_path.split('/').pop();
      desc = toolName + ': ' + file;
    }
  }
  permissionTool.textContent = desc;
  scheduleExpandedHeightSync();
}

async function handlePermission(decision) {
  const permId = permissionSection.dataset.permId;
  if (!permId) return;
  await invoke('permission_decision', {
    perm_id: permId,
    decision: decision,
    reason: null,
  });
  pendingPerms.delete(permId);
  permissionSection.style.display = 'none';
  delete permissionSection.dataset.permId;

  if (pendingPerms.size > 0) {
    const [nextId, next] = pendingPerms.entries().next().value;
    showPermission(next.toolName, next.toolInput, nextId);
  } else {
    scheduleExpandedHeightSync();
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
  if (collapseFallbackTimer) { clearTimeout(collapseFallbackTimer); collapseFallbackTimer = null; }

  // Elevator: expand native window FIRST, then CSS animation fills it
  await invoke('expand_window');
  scheduleExpandedHeightSync();

  // Wait one frame so the window resize is applied before CSS transition starts
  requestAnimationFrame(() => {
    island.classList.remove('collapsed');
    island.classList.add('expanded');
    island.setAttribute('aria-expanded', 'true');
  });

  await refreshRecentHistory();

  updateUI(activeSessionId ? sessions[activeSessionId] : null);
}

async function collapseIsland() {
  if (isAnimating) return;
  isAnimating = true;
  isExpanded = false;
  collapseAfterTransition = true;
  island.setAttribute('aria-expanded', 'false');

  // Elevator: CSS animation FIRST (keep expanded class for transition + detail visible)
  // Set target height via inline style; CSS transition on .expanded handles the animation
  island.style.height = 'var(--notch-height, 37px)';

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
  if (collapseFallbackTimer) { clearTimeout(collapseFallbackTimer); collapseFallbackTimer = null; }

  // Now swap class and clean up inline style
  island.classList.remove('expanded');
  island.classList.add('collapsed');
  island.style.height = '';

  // THEN shrink native window (elevator: door closes after you're inside)
  await invoke('collapse_window');
}

async function refreshRecentHistory() {
  try {
    const history = await invoke('get_history');
    renderHistory(history);
  } catch (e) {
    console.error('Failed to load history:', e);
  }
}

function renderHistory(entries) {
  historyList.innerHTML = '';
  recentHistoryEntries = (entries || [])
    .slice()
    .sort((a, b) => getEntryTimestamp(b) - getEntryTimestamp(a))
    .slice(0, 3);

  if (recentHistoryEntries.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'history-item';
    empty.style.color = 'rgba(255,255,255,0.3)';
    empty.textContent = 'No recent sessions';
    historyList.appendChild(empty);
    scheduleExpandedHeightSync();
    return;
  }

  recentHistoryEntries.forEach(entry => {
    const div = document.createElement('div');
    div.className = 'history-item';

    const cwdSpan = document.createElement('span');
    cwdSpan.className = 'history-cwd';
    cwdSpan.textContent = entry.cwd.split('/').slice(-2).join('/');

    const metaSpan = document.createElement('span');
    metaSpan.className = 'history-meta';
    metaSpan.textContent = (entry.tool_count || 0) + 't · ' + formatDuration(entry.duration_secs);

    div.appendChild(cwdSpan);
    div.appendChild(metaSpan);
    historyList.appendChild(div);
  });

  scheduleExpandedHeightSync();
}

function formatDuration(secs) {
  if (!secs || secs < 0) return '0s';
  if (secs < 60) return secs + 's';
  if (secs < 3600) return Math.floor(secs / 60) + 'm';
  return Math.floor(secs / 3600) + 'h ' + Math.floor((secs % 3600) / 60) + 'm';
}

function getEntryTimestamp(entry) {
  const timestamp = Date.parse(entry.ended_at || entry.last_event_at || entry.started_at || '');
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

// Connection state tracking (IMPL-07)
let isConnected = false;

listen('connection-count', (event) => {
  const count = event.payload;
  isConnected = count > 0;
  if (!isConnected && !isExpanded) {
    const hasActiveSessions = getActiveSessions().length > 0;
    if (!hasActiveSessions) {
      statusDot.className = 'status-dot disconnected';
      setMascotVariant(null, 'WaitingForInput');
      statusText.textContent = 'No connections';
    }
  }
});

// Boot
init();
