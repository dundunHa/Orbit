import { getStatusConfig } from '../constants/session.js';

/**
 * @typedef {import('../types/session.js').SessionNode} SessionNode
 */

/**
 * Example sessions for demonstration
 * @type {SessionNode[]}
 */
export const exampleSessions = [
  {
    id: "Session-001",
    status: "running",
    description: "Implementing auth system refactoring",
    agent: "@main-agent",
    metadata: {
      duration: "12m 34s",
      tokens: "8.2k tokens",
      startTime: new Date("2026-04-03T10:00:00"),
    },
    level: 0,
    children: [
      {
        id: "Session-002",
        parentId: "Session-001",
        status: "completed",
        description: "Update user model schema",
        dependencies: [],
        metadata: { duration: "2m 10s", tokens: "1.5k tokens" },
        level: 1,
        children: [],
      },
      {
        id: "Session-003",
        parentId: "Session-001",
        status: "running",
        description: "Migrate existing user data",
        agent: "@data-agent",
        metadata: {
          duration: "5m 12s",
          tokens: "3.1k tokens",
        },
        level: 1,
        children: [
          {
            id: "Session-003-1",
            parentId: "Session-003",
            status: "error",
            description: "Connect to legacy database",
            metadata: { duration: "1m 02s", tokens: "500 tokens" },
            level: 2,
            children: [],
          }
        ],
      },
      {
        id: "Session-004",
        parentId: "Session-001",
        status: "blocked",
        description: "Update API documentation",
        dependencies: ["Session-003"],
        metadata: { duration: "-", tokens: "-" },
        level: 1,
        children: [],
      },
      {
        id: "Session-005",
        parentId: "Session-001",
        status: "pending",
        description: "Deploy auth service",
        dependencies: ["Session-002", "Session-004"],
        metadata: { duration: "-", tokens: "-" },
        level: 1,
        children: [],
      }
    ],
  },
  {
    id: "Session-010",
    status: "completed",
    description: "Initial project setup",
    agent: "@setup-agent",
    metadata: {
      duration: "45s",
      tokens: "2.1k tokens",
      startTime: new Date("2026-04-03T09:00:00"),
      endTime: new Date("2026-04-03T09:00:45"),
    },
    level: 0,
    children: [],
  }
];
