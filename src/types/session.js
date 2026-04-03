/**
 * Session execution state for the session tree.
 * @typedef {'running' | 'pending' | 'blocked' | 'completed' | 'error'} SessionStatus
 */

/**
 * Metadata displayed for a session node.
 * @typedef {Object} SessionMetadata
 * @property {string} duration - Human-readable elapsed duration, e.g. "12m 34s"
 * @property {string} tokens - Human-readable token count, e.g. "8.2k tokens"
 * @property {Date} [startTime] - Optional start timestamp for the session
 * @property {Date} [endTime] - Optional end timestamp for the session
 */

/**
 * Tree node representing a single session and its nested children.
 * @typedef {Object} SessionNode
 * @property {string} id - Unique session identifier, e.g. "Session-001"
 * @property {string} [parentId] - Parent session identifier; omitted for root nodes
 * @property {SessionStatus} status - Current execution state of the session
 * @property {string} description - Short description shown in the tree
 * @property {string} [agent] - Optional agent label, e.g. "@main-agent"
 * @property {string[]} [dependencies] - Optional list of session IDs that this session depends on
 * @property {SessionMetadata} metadata - Display metadata for the session
 * @property {SessionNode[]} children - Nested child sessions
 * @property {number} level - Tree depth, where 0 is root level
 */

/**
 * Configuration for a session status.
 * @typedef {Object} SessionStatusConfig
 * @property {'◼' | '◻'} icon - Status icon
 * @property {string} color - Status color (hex)
 * @property {string} bgColor - Background color (rgba)
 * @property {string} label - Status label in Chinese
 */

// Export types for JSDoc usage
export const Types = {};
