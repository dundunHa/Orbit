import Foundation

public enum TokenFormatting {
    public static func formatTokens(_ n: UInt64) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000.0)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000.0)
        } else {
            return "\(n)"
        }
    }
    
    public static func tokenStatsText(tokensIn: UInt64, tokensOut: UInt64, outRate: Double) -> String {
        let rateStr = (tokensOut > 0 && outRate > 0.1)
            ? String(format: " (%.1f tok/s)", outRate)
            : ""
        return "today: ↓\(formatTokens(tokensIn)) ↑\(formatTokens(tokensOut))\(rateStr)"
    }
}
