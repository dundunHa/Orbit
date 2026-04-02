// Orbit — Dynamic Island Frontend
// Tauri IPC bridge

const { listen } = window.__TAURI__.event;
const { invoke } = window.__TAURI__.core;

// State
let currentSession = null;
let isExpanded = false;
let currentPermId = null;

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

// Listen for session updates from Rust backend
listen('session-update', (event) => {
  const session = event.payload;
  currentSession = session;
  updateUI(session);
});

// Listen for permission requests
listen('permission-request', (event) => {
  currentPermId = event.payload.perm_id;
  // Auto-expand on permission request
  if (!isExpanded) {
    expandIsland();
  }
});

function updateUI(session) {
  if (!session) return;

  const status = session.status;
  const statusType = status.type;

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
      statusText.textContent = `Needs approval: ${status.tool_name}`;
      showPermission(status.tool_name, status.tool_input);
      break;
    case 'Anomaly':
      statusDot.classList.add('anomaly');
      statusText.textContent = `Stuck? (${status.idle_seconds}s idle)`;
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
  if (session.tool_count > 0) {
    toolCount.textContent = `${session.tool_count} tools`;
  } else {
    toolCount.textContent = '';
  }

  // Detail view
  if (isExpanded) {
    const cwdShort = session.cwd.split('/').slice(-2).join('/');
    sessionCwd.textContent = cwdShort;
    detailStatus.textContent = statusText.textContent;
    detailTools.textContent = `${session.tool_count} tool calls this session`;
  }

  // Hide permission section if no longer waiting
  if (statusType !== 'WaitingForApproval') {
    permissionSection.style.display = 'none';
    currentPermId = null;
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
    default: return `Running ${toolName}...`;
  }
}

function showPermission(toolName, toolInput) {
  permissionSection.style.display = 'block';
  let desc = toolName;
  if (toolInput && typeof toolInput === 'object') {
    if (toolInput.command) {
      desc = `${toolName}: ${toolInput.command.substring(0, 80)}`;
    } else if (toolInput.file_path) {
      const file = toolInput.file_path.split('/').pop();
      desc = `${toolName}: ${file}`;
    }
  }
  permissionTool.textContent = desc;
}

async function handlePermission(decision) {
  if (!currentPermId) return;
  await invoke('permission_decision', {
    permId: currentPermId,
    decision: decision,
    reason: null,
  });
  permissionSection.style.display = 'none';
  currentPermId = null;
}

function toggleExpand() {
  if (isExpanded) {
    collapseIsland();
  } else {
    expandIsland();
  }
}

async function expandIsland() {
  isExpanded = true;
  island.classList.remove('collapsed');
  island.classList.add('expanded');
  await invoke('expand_window');

  // Load history
  try {
    const history = await invoke('get_history');
    renderHistory(history);
  } catch (e) {
    console.error('Failed to load history:', e);
  }

  // Update detail if we have a session
  if (currentSession) {
    const cwdShort = currentSession.cwd.split('/').slice(-2).join('/');
    sessionCwd.textContent = cwdShort;
    detailStatus.textContent = statusText.textContent;
    detailTools.textContent = `${currentSession.tool_count} tool calls this session`;
  }
}

async function collapseIsland() {
  isExpanded = false;
  island.classList.remove('expanded');
  island.classList.add('collapsed');
  await invoke('collapse_window');
}

function renderHistory(entries) {
  historyList.innerHTML = '';
  if (!entries || entries.length === 0) {
    historyList.innerHTML = '<div class="history-item"><span style="color: rgba(255,255,255,0.3)">No history yet</span></div>';
    return;
  }

  entries.reverse().forEach(entry => {
    const div = document.createElement('div');
    div.className = 'history-item';

    const cwdShort = entry.cwd.split('/').slice(-2).join('/');
    const duration = formatDuration(entry.duration_secs);

    div.innerHTML = `
      <span class="history-cwd">${cwdShort}</span>
      <span class="history-meta">${entry.tool_count}t · ${duration}</span>
    `;
    historyList.appendChild(div);
  });
}

function formatDuration(secs) {
  if (secs < 60) return `${secs}s`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m`;
  return `${Math.floor(secs / 3600)}h ${Math.floor((secs % 3600) / 60)}m`;
}
