struct PendingInteraction: Identifiable {
    let id: String
    let kind: String
    let sessionId: String
    let toolName: String
    let toolInput: AnyCodable
    let message: String
    let requestedSchema: AnyCodable?
}
