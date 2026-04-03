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

const STATUS_PRIORITY = {
  WaitingForApproval: 6,
  Anomaly: 5,
  RunningTool: 4,
  Processing: 3,
  Compacting: 2,
  WaitingForInput: 1,
  Ended: 0,
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

export function formatTokenRate(tokensPerSecond) {
  const value = Math.max(0, Number(tokensPerSecond) || 0);

  if (value >= 100) return `${Math.round(value)} tok/s`;
  if (value >= 10) return `${value.toFixed(1)} tok/s`;

  return `${value.toFixed(2)} tok/s`;
}

export function getSessionTokenStats(session) {
  const input = Math.max(0, Number(session.tokens_in) || 0);
  const output = Math.max(0, Number(session.tokens_out) || 0);
  const total = input + output;
  const durationSecs = getSessionDurationSeconds(session);
  const averageTotalTps = durationSecs > 0 ? total / durationSecs : 0;

  return {
    input,
    output,
    total,
    durationSecs,
    averageTotalTps,
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
      averageTps: formatTokenRate(tokenStats.averageTotalTps),
    },
    level,
    children: [],
  };
}

export function buildSessionTree(sessions, activeSessionId) {
  const sessionArray = Object.values(sessions);
  const activeSessions = sessionArray.filter((s) => s.status?.type !== "Ended");

  if (activeSessions.length === 0) {
    return [];
  }

  activeSessions.sort((a, b) => {
    const prioA = STATUS_PRIORITY[a.status?.type] || 0;
    const prioB = STATUS_PRIORITY[b.status?.type] || 0;
    if (prioA !== prioB) return prioB - prioA;
    return new Date(b.last_event_at || 0) - new Date(a.last_event_at || 0);
  });

  const rootSessions = [];
  const mainSession =
    activeSessions.find((s) => s.id === activeSessionId) || activeSessions[0];
  const mainNode = transformSession(mainSession, 0);

  const otherSessions = activeSessions.filter((s) => s.id !== mainSession.id);
  if (otherSessions.length > 0) {
    mainNode.children = otherSessions.map((s) => transformSession(s, 1));
  }

  rootSessions.push(mainNode);

  return rootSessions;
}

export function getSessionCounts(sessions) {
  const all = Object.values(sessions);
  return {
    total: all.length,
    active: all.filter((s) => s.status?.type !== "Ended").length,
    ended: all.filter((s) => s.status?.type === "Ended").length,
  };
}
