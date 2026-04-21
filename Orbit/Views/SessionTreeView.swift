import SwiftUI

public struct SessionTreeView: View {
    public let sessions: [Session]
    public let selectedSessionId: String?
    
    public init(sessions: [Session], selectedSessionId: String? = nil) {
        self.sessions = sessions
        self.selectedSessionId = selectedSessionId
    }
    
    public var body: some View {
        if sessions.isEmpty {
            Text("No active sessions")
                .italic()
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.3))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .accessibilityIdentifier(OrbitAccessibilityID.SessionTree.emptyState)
        } else {
            VStack(spacing: 0) {
                let rootSessions = sessions.filter { $0.parentSessionId == nil }
                ForEach(rootSessions, id: \.id) { session in
                    SessionTreeNodeView(session: session, allSessions: sessions, selectedSessionId: selectedSessionId, depth: 0)
                }
            }
        }
    }
}

public struct SessionTreeNodeView: View {
    public let session: Session
    public let allSessions: [Session]
    public let selectedSessionId: String?
    public let depth: Int
    
    public init(session: Session, allSessions: [Session], selectedSessionId: String?, depth: Int) {
        self.session = session
        self.allSessions = allSessions
        self.selectedSessionId = selectedSessionId
        self.depth = depth
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            SessionTreeRowView(session: session, isSelected: session.id == selectedSessionId)
                .padding(.leading, CGFloat(depth * 20))
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 0.5),
                    alignment: .bottom
                )
            
            let children = allSessions.filter { $0.parentSessionId == session.id }
            ForEach(children, id: \.id) { child in
                SessionTreeNodeView(session: child, allSessions: allSessions, selectedSessionId: selectedSessionId, depth: depth + 1)
            }
        }
    }
}

public struct SessionTreeRowView: View {
    public let session: Session
    public let isSelected: Bool
    
    public init(session: Session, isSelected: Bool) {
        self.session = session
        self.isSelected = isSelected
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            StatusDotView(status: session.status)
            
            Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Text(statusString(session.status))
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(Color.white.opacity(0.4))
                .lineLimit(1)
                .truncationMode(.tail)
                .textCase(.lowercase)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.white.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(OrbitAccessibilityID.SessionTree.row(sessionID: session.id))
    }
    
    private func statusString(_ status: SessionStatus) -> String {
        switch status {
        case .waitingForInput: return "waiting"
        case .processing: return "thinking"
        case .runningTool: return "running"
        case .waitingForApproval: return "approve?"
        case .anomaly: return "anomaly"
        case .ended: return "ended"
        case .compacting: return "compacting"
        }
    }
}
