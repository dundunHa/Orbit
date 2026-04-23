import { getStatusConfig } from "../constants/session.js";

const STATUS_MAP = {
  Processing: "running",
  RunningTool: "running",
  Compacting: "running",
  WaitingForApproval: "blocked",
  Anomaly: "error",
  WaitingForInput: "pending",
  Ended: "completed",
};

function formatDuration(seconds) {
  if (!seconds || seconds < 0) return "0s";
  if (seconds < 60) return seconds + "s";
  if (seconds < 3600) return Math.floor(seconds / 60) + "m";
  return (
    Math.floor(seconds / 3600) + "h " + Math.floor((seconds % 3600) / 60) + "m"
  );
}

function getSessionDurationSeconds(session) {
  if (!session.started_at || !session.last_event_at) return 0;

  return Math.max(
    0,
    Math.floor(
      (new Date(session.last_event_at) - new Date(session.started_at)) / 1000,
    ),
  );
}

export function formatTokenCount(tokens) {
  const value = Math.max(0, Number(tokens) || 0);

  if (value < 1000) return `${value} tok`;
  if (value < 10000) return `${(value / 1000).toFixed(1)}k tok`;
  if (value < 1000000) return `${Math.round(value / 1000)}k tok`;

  return `${(value / 1000000).toFixed(1)}M tok`;
}

export function formatCompactTokenCount(tokens) {
  const value = Math.max(0, Number(tokens) || 0);

  if (value < 1000) return `${Math.round(value)}`;
  if (value < 10000) return `${(value / 1000).toFixed(1)}k`;
  if (value < 1000000) return `${Math.round(value / 1000)}k`;

  return `${(value / 1000000).toFixed(1)}M`;
}

export function formatTokenRate(tokensPerSecond) {
  const value = Math.max(0, Number(tokensPerSecond) || 0);

  if (value >= 100) return `${Math.round(value)} tok/s`;
  if (value >= 10) return `${value.toFixed(1)} tok/s`;

  return `${value.toFixed(2)} tok/s`;
}

export function formatCompactTokenRate(tokensPerSecond) {
  const value = Math.max(0, Number(tokensPerSecond) || 0);

  if (value >= 100) return `${Math.round(value)}/s`;
  if (value >= 10) return `${value.toFixed(1)}/s`;

  return `${value.toFixed(2)}/s`;
}

export function getSessionTokenStats(session) {
  const input = Math.max(0, Number(session.tokens_in) || 0);
  const output = Math.max(0, Number(session.tokens_out) || 0);
  const total = input + output;
  const durationSecs = getSessionDurationSeconds(session);
  const averageOutputTps = durationSecs > 0 ? output / durationSecs : 0;

  return {
    input,
    output,
    total,
    durationSecs,
    averageOutputTps,
    hasTokens: total > 0,
  };
}

function transformSession(session, level = 0) {
  const duration = getSessionDurationSeconds(session);
  const tokenStats = getSessionTokenStats(session);

  return {
    id: session.id?.slice(-4) || session.id || "unknown",
    status: STATUS_MAP[session.status?.type] || "pending",
    description:
      session.title || session.status?.description || "No description",
    agent: session.agent || null,
    metadata: {
      duration: formatDuration(duration),
      tokens: formatTokenCount(tokenStats.total),
      tokensIn: formatTokenCount(tokenStats.input),
      tokensOut: formatTokenCount(tokenStats.output),
      tokensTotal: formatTokenCount(tokenStats.total),
      tokensInCompact: formatCompactTokenCount(tokenStats.input),
      tokensOutCompact: formatCompactTokenCount(tokenStats.output),
      outputRateCompact: formatCompactTokenRate(tokenStats.averageOutputTps),
      averageTps: formatTokenRate(tokenStats.averageOutputTps),
    },
    started_at: session.started_at || null,
    level,
    children: [],
  };
}

function transformSubagent(agent, level) {
  const startedAt = agent.started_at || null;
  const lastEventAt = agent.last_event_at || startedAt;
  const durationSecs = startedAt
    ? Math.max(
        0,
        Math.floor((new Date(lastEventAt) - new Date(startedAt)) / 1000),
      )
    : 0;
  const shortId = agent.agent_id ? agent.agent_id.slice(-4) : "sub";
  const statusKey = agent.ended ? "completed" : "running";
  const description =
    agent.last_tool_description ||
    agent.last_tool_name ||
    agent.agent_type ||
    "subagent";

  return {
    id: shortId,
    status: statusKey,
    description,
    agent: agent.agent_type ? `@${agent.agent_type}` : null,
    metadata: {
      duration: formatDuration(durationSecs),
      tokens: "—",
      tokensIn: "—",
      tokensOut: "—",
      tokensTotal: "—",
      tokensInCompact: "—",
      tokensOutCompact: "—",
      outputRateCompact: "—",
      averageTps: "—",
    },
    started_at: startedAt,
    level,
    children: [],
  };
}

export function buildSessionTree(sessions, activeSessionId) {
  void activeSessionId;

  const sessionArray = Object.values(sessions);
  const activeSessions = sessionArray.filter((s) => s.status?.type !== "Ended");

  if (activeSessions.length === 0) {
    return [];
  }

  const sortByStartedAtAsc = (a, b) => {
    const startedA = new Date(a.started_at || 0).getTime();
    const startedB = new Date(b.started_at || 0).getTime();
    if (startedA !== startedB) return startedA - startedB;

    return new Date(a.last_event_at || 0) - new Date(b.last_event_at || 0);
  };

  // Each session_id represents an independent Claude Code process. Parent/child
  // relationships between sessions are NOT reliably reported by Claude Code
  // hooks, so we never attempt to nest one session under another. Subagents
  // spawned inside a session share that session's session_id and are exposed
  // via session.agents[agent_id]; we render them as children of their parent.
  const roots = activeSessions.slice().sort(sortByStartedAtAsc);

  return roots.map((session) => {
    const node = transformSession(session, 0);
    const agents = session.agents ? Object.values(session.agents) : [];
    if (agents.length > 0) {
      const sortedAgents = agents.slice().sort((a, b) => {
        const endedA = a.ended ? 1 : 0;
        const endedB = b.ended ? 1 : 0;
        if (endedA !== endedB) return endedA - endedB;
        return new Date(b.last_event_at || 0) - new Date(a.last_event_at || 0);
      });
      node.children = sortedAgents.map((agent) => transformSubagent(agent, 1));
    }
    return node;
  });
}

export function getSessionCounts(sessions) {
  const all = Object.values(sessions);
  return {
    total: all.length,
    active: all.filter((s) => s.status?.type !== "Ended").length,
    ended: all.filter((s) => s.status?.type === "Ended").length,
  };
}
