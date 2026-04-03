# Team Agent Session Tree

## Overview
A visual representation for hierarchical agent sessions.

## Usage

```tsx
import { SessionTree } from './components/SessionTree';
import type { SessionNode } from './types/session';

const sessions: SessionNode[] = [
  {
    id: "Session-001",
    status: "running",
    description: "Implementing auth system refactoring",
    agent: "@main-agent",
    metadata: {
      duration: "12m 34s",
      tokens: "8.2k tokens",
    },
    level: 0,
    children: [],
  }
];

function App() {
  return (
    <SessionTree
      sessions={sessions}
      activeSessionId="Session-001"
      onSessionClick={(session) => console.log(session.id)}
      compact={false}
    />
  );
}
```

## Keyboard Shortcuts
- ⌘+T: Toggle compact mode
- ⌘+1-9: Switch to session by index
