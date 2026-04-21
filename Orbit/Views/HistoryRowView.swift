import SwiftUI

public struct HistoryRowView: View {
    public let entry: HistoryEntry
    
    public init(entry: HistoryEntry) {
        self.entry = entry
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? URL(fileURLWithPath: entry.cwd).lastPathComponent)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                HStack(spacing: 6) {
                    Text(relativeDate(from: entry.startedAt))
                    Text("•")
                        .foregroundColor(Color.white.opacity(0.1))
                    Text("\(TokenFormatting.formatTokens(entry.tokensIn))↓ \(TokenFormatting.formatTokens(entry.tokensOut))↑")
                    Text("•")
                        .foregroundColor(Color.white.opacity(0.1))
                    Text(formatDuration(entry.durationSecs))
                }
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(Color.white.opacity(0.3))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(OrbitAccessibilityID.History.row(sessionID: entry.sessionId))
    }
    
    private func relativeDate(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private func formatDuration(_ durationSecs: Int64) -> String {
        if durationSecs < 60 {
            return "\(durationSecs)s"
        }
        let minutes = durationSecs / 60
        let seconds = durationSecs % 60
        if minutes < 60 {
            return "\(minutes)m \(seconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }
}
