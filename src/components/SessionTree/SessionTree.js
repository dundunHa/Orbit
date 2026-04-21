import { getStatusConfig, TREE_CONNECTORS } from "../../constants/session.js";

/**
 * SessionTree - A visual tree component for displaying hierarchical agent sessions
 */
export class SessionTree {
  /**
   * @param {Object} options
   * @param {import('../../types/session.js').SessionNode[]} options.sessions
   * @param {string} [options.containerId] - Container element ID
   * @param {HTMLElement} [options.container] - Container element (alternative to containerId)
   * @param {Function} [options.onSessionClick] - Click handler
   * @param {boolean} [options.compact=false] - Compact mode
   */
  constructor(options) {
    this.sessions = options.sessions || [];
    this.onSessionClick = options.onSessionClick;
    this.compact = options.compact || false;
    this.activeSessionId = null;

    this.container =
      options.container || document.getElementById(options.containerId);
    if (!this.container) {
      throw new Error("SessionTree: Container not found");
    }

    this._setupKeyboardShortcuts();
    this.render();
  }

  /**
   * Setup keyboard shortcuts
   */
  _setupKeyboardShortcuts() {
    document.addEventListener("keydown", (e) => {
      const isModifier = e.metaKey || e.ctrlKey;
      if (!isModifier) return;

      const key = e.key.toLowerCase();

      if (key === "t") {
        e.preventDefault();
        this.toggleCompact();
        return;
      }

      const keyNum = parseInt(key, 10);
      if (!isNaN(keyNum) && keyNum >= 1 && keyNum <= 9) {
        const index = keyNum - 1;
        if (index < this.sessions.length) {
          e.preventDefault();
          this._activateSession(this.sessions[index]);
        }
      }
    });
  }

  /**
   * Activate a session
   * @param {import('../../types/session.js').SessionNode} session
   */
  _activateSession(session) {
    this.activeSessionId = session.id;
    if (this.onSessionClick) {
      this.onSessionClick(session);
    }
    this.render();
  }

  /**
   * Toggle compact mode
   */
  toggleCompact() {
    this.compact = !this.compact;
    this.render();
  }

  /**
   * Set sessions data
   * @param {import('../../types/session.js').SessionNode[]} sessions
   */
  setSessions(sessions) {
    this.sessions = sessions;
    this.render();
  }

  /**
   * Set active session
   * @param {string} sessionId
   */
  setActiveSession(sessionId) {
    this.activeSessionId = sessionId;
    this.render();
  }

  /**
   * Build tree connector prefix
   * @param {number} level
   * @param {boolean} hasSiblings
   * @returns {string}
   */
  _buildConnector(level, hasSiblings) {
    if (level === 0) return "";

    const prefixChar = hasSiblings
      ? TREE_CONNECTORS.sibling
      : TREE_CONNECTORS.empty;
    const prefix = prefixChar.repeat(level - 1);
    return prefix + TREE_CONNECTORS.child;
  }

  /**
   * Render compact token metrics for a row.
   * @param {import('../../types/session.js').SessionNode['metadata']} metadata
   * @returns {string}
   */
  _renderTokenMetrics(metadata) {
    if (!metadata) return "";

    return `
      <span class="metadata-info token-metrics" aria-label="Token metrics">
        <span class="token-metric token-metric-in">↑${metadata.tokensInCompact}</span>
        <span class="token-metric token-metric-out">↓${metadata.tokensOutCompact}</span>
        <span class="token-metric token-metric-rate">↓${metadata.outputRateCompact}</span>
      </span>
    `;
  }

  /**
   * Render a single session node
   * @param {import('../../types/session.js').SessionNode} session
   * @param {number} level
   * @param {boolean} hasSiblings
   * @returns {HTMLElement}
   */
  _renderNode(session, level, hasSiblings) {
    const isParent = session.children && session.children.length > 0;
    const statusConfig = getStatusConfig(session.status);
    const connector = this._buildConnector(level, hasSiblings);
    const isActive = this.activeSessionId === session.id;

    const item = document.createElement("div");
    item.className = `session-item ${isParent ? "is-parent" : ""} ${isActive ? "is-active" : ""}`;
    item.style.cursor = this.onSessionClick ? "pointer" : "default";

    item.innerHTML = `
      ${level > 0 ? `<span class="tree-prefix">${connector}</span>` : ""}
      <div class="content-wrapper">
        <span class="status-icon" style="color: ${statusConfig.color}">${statusConfig.icon}</span>
        <span class="message-text">
          <strong>${session.id}</strong>
          <span style="color: var(--text-muted)">${session.description}</span>
        </span>
        ${isParent ? '<span class="parent-tag">Parent</span>' : ""}
        ${session.agent ? `<span class="agent-tag">${session.agent}</span>` : ""}
        ${session.dependencies?.length ? `<span class="dependency-tag">Depends: ${session.dependencies.join(", ")}</span>` : ""}
        ${!this.compact ? this._renderTokenMetrics(session.metadata) : ""}
      </div>
    `;

    item.addEventListener("click", () => this._activateSession(session));

    const container = document.createElement("div");
    container.appendChild(item);

    if (isParent) {
      const childrenContainer = document.createElement("div");
      childrenContainer.className = "session-children";
      session.children.forEach((child, index) => {
        const childNode = this._renderNode(
          child,
          level + 1,
          index < session.children.length - 1,
        );
        childrenContainer.appendChild(childNode);
      });
      container.appendChild(childrenContainer);
    }

    return container;
  }

  /**
   * Render the tree
   */
  render() {
    this.container.innerHTML = "";
    this.container.classList.add("session-tree");

    this.sessions.forEach((session, index) => {
      const node = this._renderNode(
        session,
        0,
        index < this.sessions.length - 1,
      );
      this.container.appendChild(node);
    });
  }

  /**
   * Destroy the component and cleanup
   */
  destroy() {}
}

export default SessionTree;
