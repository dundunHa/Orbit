struct PendingInteraction: Identifiable, Equatable {
    let id: String
    let kind: String
    let sessionId: String
    let toolName: String
    let toolInput: AnyCodable
    let message: String
    let requestedSchema: AnyCodable?
    let permissionSuggestions: [PermissionUpdateEntry]?

    init(
        id: String,
        kind: String,
        sessionId: String,
        toolName: String,
        toolInput: AnyCodable,
        message: String,
        requestedSchema: AnyCodable?,
        permissionSuggestions: [PermissionUpdateEntry]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sessionId = sessionId
        self.toolName = toolName
        self.toolInput = toolInput
        self.message = message
        self.requestedSchema = requestedSchema
        self.permissionSuggestions = permissionSuggestions
    }
}
