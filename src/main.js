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

// DOM elements
const island = document.getElementById('island');
const statusDot = document.querySelector('.status-dot');
const statusText = document.querySelector('.status-text');
const toolCount = document.querySelector('.tool-count');
const sessionCwd = document.querySelector('.session-cwd');
const detailStatus = document.querySelector('.detail-status');
const detailTools = document.querySelector('.detail-tools');
const permissionSection = document.querySelector('.permission-section');
const permissionTool = document.querySelector('.permission-tool');
const historyList = document.querySelector('.history-list');

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

// Dynamic pill widths per status
const STATUS_WIDTH = {
  'WaitingForApproval': 260,
  'Anomaly': 240,
  'RunningTool': 220,
  'Processing': 200,
  'Compacting': 200,
  'WaitingForInput': 180,
  'Ended': 180,
};

// IMPL-06: unlock animation on transitionend (only for island itself, not children)
island.addEventListener('transitionend', (e) => {
  if (e.target === island) {
    isAnimating = false;
  }
});

// Initialize: load existing sessions
async function init() {
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

function selectActiveSession() {
  let best = null;
  let bestPriority = -1;

  for (const s of Object.values(sessions)) {
    const prio = STATUS_PRIORITY[s.status.type] || 0;
    if (prio > bestPriority || (prio === bestPriority && (!best || s.last_event_at > best.last_event_at))) {
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
listen('session-update', (event) => {
  const session = event.payload;
  const prev = sessions[session.id];
  sessions[session.id] = session;

  // IMPL-04: Stop event → completion flash
  if (prev && prev.status.type !== 'WaitingForInput' && prev.status.type !== 'Ended'
      && (session.status.type === 'WaitingForInput' || session.status.type === 'Ended')) {
    island.classList.add('flash-complete');
    setTimeout(() => island.classList.remove('flash-complete'), 600);
  }

  selectActiveSession();
});

// Listen for permission requests
listen('permission-request', (event) => {
  const { perm_id, session_id, tool_name, tool_input } = event.payload;
  pendingPerms.set(perm_id, { sessionId: session_id, toolName: tool_name, toolInput: tool_input });
  showPermission(tool_name, tool_input, perm_id);
  if (!isExpanded) {
    expandIsland();
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
    }
  }
});

function updateUI(session) {
  if (!session) return;

  const status = session.status;
  const statusType = status.type;

  // IMPL-04: dynamic pill width based on status
  if (!isExpanded) {
    const width = STATUS_WIDTH[statusType] || 200;
    island.style.setProperty('--pill-width', width + 'px');
  }

  // Update dot color
  statusDot.className = 'status-dot';
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
      statusText.textContent = 'Needs approval: ' + (status.tool_name || '');
      break;
    case 'Anomaly':
      statusDot.classList.add('anomaly');
      statusText.textContent = 'Stuck? (' + status.idle_seconds + 's idle)';
      break;
    case 'Compacting':
      statusDot.classList.add('processing');
      statusText.textContent = 'Compacting context...';
      break;
    case 'Ended':
      statusDot.classList.add('ended');
      statusText.textContent = 'Session ended';
      break;
    case 'WaitingForInput':
    default:
      statusDot.classList.add('idle');
      statusText.textContent = 'Idle';
      break;
  }

  // Tool count
  toolCount.textContent = session.tool_count > 0 ? session.tool_count + ' tools' : '';

  // Detail view
  if (isExpanded) {
    const cwdShort = session.cwd.split('/').slice(-2).join('/');
    sessionCwd.textContent = cwdShort;
    detailStatus.textContent = statusText.textContent;
    detailTools.textContent = session.tool_count + ' tool calls this session';
  }

  // Hide permission section if no pending perms for active session
  if (statusType !== 'WaitingForApproval') {
    // Clean up resolved perms for this session
    for (const [pid, p] of pendingPerms) {
      if (p.sessionId === session.id) {
        pendingPerms.delete(pid);
      }
    }
    if (pendingPerms.size === 0) {
      permissionSection.style.display = 'none';
    }
  }
}

function formatTool(toolName, description) {
  if (description) return description;
  switch (toolName) {
    case 'Bash': return '$ Running command...';
    case 'Read': return 'Reading file...';
    case 'Edit': return 'Editing file...';
    case 'Write': return 'Writing file...';
    case 'Grep': return 'Searching code...';
    case 'Glob': return 'Finding files...';
    case 'Agent': return 'Running agent...';
    default: return 'Running ' + (toolName || '') + '...';
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

  // Show next pending perm if any
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
  island.classList.remove('collapsed');
  island.classList.add('expanded');
  await invoke('expand_window');

  try {
    const history = await invoke('get_history');
    renderHistory(history);
  } catch (e) {
    console.error('Failed to load history:', e);
  }

  if (activeSessionId && sessions[activeSessionId]) {
    const s = sessions[activeSessionId];
    sessionCwd.textContent = s.cwd.split('/').slice(-2).join('/');
    detailStatus.textContent = statusText.textContent;
    detailTools.textContent = s.tool_count + ' tool calls this session';
  }
}

async function collapseIsland() {
  if (isAnimating) return;
  isAnimating = true;
  isExpanded = false;
  island.classList.remove('expanded');
  island.classList.add('collapsed');
  await invoke('collapse_window');
}

function renderHistory(entries) {
  historyList.innerHTML = '';
  if (!entries || entries.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'history-item';
    empty.style.color = 'rgba(255,255,255,0.3)';
    empty.textContent = 'No history yet';
    historyList.appendChild(empty);
    return;
  }

  entries.reverse().forEach(entry => {
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
}

function formatDuration(secs) {
  if (!secs || secs < 0) return '0s';
  if (secs < 60) return secs + 's';
  if (secs < 3600) return Math.floor(secs / 60) + 'm';
  return Math.floor(secs / 3600) + 'h ' + Math.floor((secs % 3600) / 60) + 'm';
}

// Connection state tracking (IMPL-07)
let isConnected = false;

listen('connection-count', (event) => {
  const count = event.payload;
  isConnected = count > 0;
  // Only show disconnected state if no active (non-ended) sessions exist
  if (!isConnected && !isExpanded) {
    const hasActiveSessions = Object.values(sessions).some(
      s => s.status.type !== 'Ended'
    );
    if (!hasActiveSessions) {
      statusDot.className = 'status-dot disconnected';
      statusText.textContent = 'No active connections';
      island.style.setProperty('--pill-width', '200px');
    }
  }
});

// Boot
init();
