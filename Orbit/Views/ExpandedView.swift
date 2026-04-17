import SwiftUI

/// Active 区域距面板顶部的总间距（直接控制，不叠加 notchHeight）
private let kActiveSectionTopInset: CGFloat = 24

public struct ExpandedView: View {
    public let sessions: [Session]
    public let historyEntries: [HistoryEntry]
    public let selectedSessionId: String?
    public let geometry: NotchGeometry

    public init(
        sessions: [Session],
        historyEntries: [HistoryEntry],
        selectedSessionId: String?,
        geometry: NotchGeometry
    ) {
        self.sessions = sessions
        self.historyEntries = historyEntries
        self.selectedSessionId = selectedSessionId
        self.geometry = geometry
    }

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeaderView(title: "Active")
                        SessionTreeView(sessions: sessions, selectedSessionId: selectedSessionId)
                    }
                    .padding(.top, kActiveSectionTopInset)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)

                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeaderView(title: "Recent")
                        if historyEntries.isEmpty {
                            Text("No history yet")
                                .italic()
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.3))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(historyEntries, id: \.sessionId) { entry in
                                HistoryRowView(entry: entry)
                                    .overlay(
                                        Rectangle()
                                            .fill(Color.white.opacity(0.05))
                                            .frame(height: 0.5),
                                        alignment: .bottom
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.notchHeight + 152)
            }
        }
    }
}
