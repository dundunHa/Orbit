import Foundation

public let bareSlashCommands: [String] = [
    "/clear",
    "/help",
    "/model",
    "/compact",
    "/cost",
    "/status",
    "/permissions",
    "/review",
    "/bug",
    "/init",
    "/doctor",
    "/logout",
    "/login",
]

public func isBareSlashCommand(_ s: String) -> Bool {
    bareSlashCommands.contains(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

public func normalizeTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !isBareSlashCommand(trimmed) else { return nil }
    return String(trimmed.prefix(40))
}
