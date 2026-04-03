/**
 * @typedef {import('../types/session.js').SessionStatus} SessionStatus
 * @typedef {import('../types/session.js').SessionStatusConfig} SessionStatusConfig
 */

/** @type {Record<SessionStatus, SessionStatusConfig>} */
export const STATUS_CONFIG = {
  running: {
    icon: "◼",
    color: "#3fb950",
    bgColor: "rgba(63, 185, 80, 0.1)",
    label: "运行中",
  },
  pending: {
    icon: "◻",
    color: "#8b949e",
    bgColor: "rgba(139, 148, 158, 0.1)",
    label: "等待中",
  },
  blocked: {
    icon: "◻",
    color: "#d29922",
    bgColor: "rgba(210, 153, 34, 0.1)",
    label: "已阻塞",
  },
  completed: {
    icon: "◼",
    color: "#58a6ff",
    bgColor: "rgba(88, 166, 255, 0.1)",
    label: "已完成",
  },
  error: {
    icon: "◼",
    color: "#f85149",
    bgColor: "rgba(248, 81, 73, 0.1)",
    label: "错误",
  },
};

/** @type {{ child: string, sibling: string, empty: string }} */
export const TREE_CONNECTORS = {
  child: "⎿ ",
  sibling: "│ ",
  empty: "  ",
};

/**
 * Get status configuration
 * @param {SessionStatus} status
 * @returns {SessionStatusConfig}
 */
export function getStatusConfig(status) {
  return STATUS_CONFIG[status];
}
