import SwiftUI

/// Active 区域距面板顶部的总间距（直接控制，不叠加 notchHeight）
private let kActiveSectionTopInset: CGFloat = 24
private let kDefaultRecentSessionLimit = 10
private let kRecentSessionPageStep = 10

public struct ExpandedView: View {
    public let sessions: [Session]
    public let historyEntries: [HistoryEntry]
    public let selectedSessionId: String?
    public let geometry: NotchGeometry
    @State private var visibleRecentCount: Int = kDefaultRecentSessionLimit

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
                            ForEach(Array(historyEntries.prefix(visibleRecentCount)), id: \.sessionId) { entry in
                                HistoryRowView(entry: entry)
                                    .overlay(
                                        Rectangle()
                                            .fill(Color.white.opacity(0.05))
                                            .frame(height: 0.5),
                                        alignment: .bottom
                                    )
                            }

                            if historyEntries.count > visibleRecentCount {
                                Button(action: {
                                    visibleRecentCount = min(
                                        visibleRecentCount + kRecentSessionPageStep,
                                        historyEntries.count
                                    )
                                }) {
                                    Text("more")
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundColor(Color.white.opacity(0.45))
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.notchHeight + 152)
            }
            .onAppear {
                visibleRecentCount = min(kDefaultRecentSessionLimit, historyEntries.count)
            }
            .onChange(of: historyEntries.count) {
                if historyEntries.count <= kDefaultRecentSessionLimit {
                    visibleRecentCount = historyEntries.count
                } else if visibleRecentCount > historyEntries.count {
                    visibleRecentCount = kDefaultRecentSessionLimit
                }
            }
        }
    }
}
