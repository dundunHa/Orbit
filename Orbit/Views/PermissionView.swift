import SwiftUI

public struct PermissionView: View {
    private static let actionButtonCornerRadius: CGFloat = 14
    private static let actionButtonMinHeight: CGFloat = 56

    public let toolName: String
    public let toolInput: AnyCodable
    public let permissionSuggestions: [PermissionUpdateEntry]?
    public let onDecision: (PermissionDecision) -> Void

    @State private var drafts = AskUserQuestionDrafts()
    @State private var currentQuestionIndex = 0
    @State private var hoveredButton: String?
    @State private var hoveredOption: String?

    public init(
        toolName: String,
        toolInput: AnyCodable,
        permissionSuggestions: [PermissionUpdateEntry]? = nil,
        onDecision: @escaping (PermissionDecision) -> Void
    ) {
        self.toolName = toolName
        self.toolInput = toolInput
        self.permissionSuggestions = permissionSuggestions
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if toolName == "AskUserQuestion" {
                askUserQuestionBody
            } else {
                toolApprovalBody
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Tool Approval (non-AskUserQuestion)

    private var toolApprovalBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(toolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            ScrollView {
                Text(formatJSON(toolInput))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)

            VStack(spacing: 4) {
                primaryButton(title: "Allow", id: "allow") {
                    onDecision(PermissionDecision(decision: "allow"))
                }
                if let suggestions = relevantPermissionSuggestions {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        secondaryButton(
                            title: permissionSuggestionTitle(suggestion, totalCount: suggestions.count),
                            id: "always-allow-\(index)"
                        ) {
                            onDecision(
                                PermissionDecision(
                                    decision: "allow",
                                    updatedPermissions: [suggestion]
                                )
                            )
                        }
                    }
                }
                secondaryButton(title: "Deny", id: "deny") {
                    onDecision(PermissionDecision(decision: "deny"))
                }
                tertiaryButton(title: "Continue in terminal", id: "passthrough") {
                    onDecision(PermissionDecision(decision: "passthrough"))
                }
            }
        }
    }

    // MARK: - AskUserQuestion

    @ViewBuilder
    private var askUserQuestionBody: some View {
        let questions = extractAskUserQuestions(from: toolInput) ?? []
        if let question = activeQuestion(in: questions) {
            VStack(alignment: .leading, spacing: 10) {
                if questions.count > 1 {
                    HStack(spacing: 8) {
                        Text("Question \(currentQuestionIndex + 1) of \(questions.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                        if let header = question.header, !header.isEmpty {
                            Text(header)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.32))
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }

                Text(question.question)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))

                if !question.options.isEmpty {
                    questionOptions(question, submitsImmediately: questions.count == 1)
                }

                if questions.count == 1 {
                    singleQuestionActions(question)
                } else {
                    multiQuestionActions(question, questions: questions)
                }
            }
        } else {
            fallbackQuestionActions
        }
    }

    // MARK: - AskUserQuestion Options

    @ViewBuilder
    private func questionOptions(_ question: AskUserQuestionQuestion, submitsImmediately: Bool) -> some View {
        if question.isMultiSelect {
            multiSelectOptions(question)
        } else {
            singleSelectOptions(question, submitsImmediately: submitsImmediately)
        }
    }

    private func singleSelectOptions(_ question: AskUserQuestionQuestion, submitsImmediately: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(question.options, id: \.label) { opt in
                let isSelected = drafts.answers(for: question).first == opt.label
                Button(action: {
                    drafts.selectSingle(opt.label, for: question)
                    if submitsImmediately {
                        submitQuestionnaire([question])
                    }
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(textColor(isSelected: isSelected, optionLabel: opt.label))
                            if let desc = opt.description {
                                Text(desc)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(backgroundColor(isSelected: isSelected, optionLabel: opt.label))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    hoveredOption = isHovering ? opt.label : (hoveredOption == opt.label ? nil : hoveredOption)
                }
            }
        }
    }

    // MARK: - Multi Select (checkbox + submit)

    private func multiSelectOptions(_ question: AskUserQuestionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(question.options, id: \.label) { opt in
                let isSelected = drafts.contains(opt.label, for: question)
                Button(action: {
                    drafts.toggleMulti(opt.label, for: question)
                }) {
                    HStack(spacing: 8) {
                        checkboxIndicator(checked: isSelected)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(isSelected ? .white : .white.opacity(0.7))
                            if let desc = opt.description {
                                Text(desc)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(isSelected ? Color.white.opacity(0.10) : Color.white.opacity(0.04))
                    .cornerRadius(8)
                    .overlay(
                        isSelected
                            ? RoundedRectangle(cornerRadius: 8)
                                .fill(Color.clear)
                                .overlay(
                                    Rectangle()
                                        .fill(Color.white)
                                        .frame(width: 2),
                                    alignment: .leading
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            : nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - AskUserQuestion Actions

    private func singleQuestionActions(_ question: AskUserQuestionQuestion) -> some View {
        VStack(spacing: 4) {
            if question.isMultiSelect {
                let count = drafts.answers(for: question).count
                primaryButton(
                    title: count > 0 ? "Submit (\(count) selected)" : "Submit",
                    id: "allow",
                    disabled: count == 0
                ) {
                    submitQuestionnaire([question])
                }
            }
            secondaryButton(title: "Deny", id: "deny") {
                onDecision(PermissionDecision(decision: "deny"))
            }
            tertiaryButton(title: "Continue in terminal", id: "passthrough") {
                onDecision(PermissionDecision(decision: "passthrough"))
            }
        }
    }

    private func multiQuestionActions(_ question: AskUserQuestionQuestion, questions: [AskUserQuestionQuestion]) -> some View {
        VStack(spacing: 4) {
            if currentQuestionIndex > 0 {
                secondaryButton(title: "Back", id: "back") {
                    currentQuestionIndex -= 1
                }
            }

            primaryButton(
                title: currentQuestionIndex == questions.count - 1 ? "Submit" : "Next",
                id: "allow",
                disabled: !drafts.hasAnswer(for: question)
            ) {
                if currentQuestionIndex == questions.count - 1 {
                    submitQuestionnaire(questions)
                } else {
                    currentQuestionIndex += 1
                }
            }

            secondaryButton(title: "Deny", id: "deny") {
                onDecision(PermissionDecision(decision: "deny"))
            }
            tertiaryButton(title: "Continue in terminal", id: "passthrough") {
                onDecision(PermissionDecision(decision: "passthrough"))
            }
        }
    }

    private var fallbackQuestionActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Question data unavailable.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))

            VStack(spacing: 4) {
                secondaryButton(title: "Deny", id: "deny") {
                    onDecision(PermissionDecision(decision: "deny"))
                }
                tertiaryButton(title: "Continue in terminal", id: "passthrough") {
                    onDecision(PermissionDecision(decision: "passthrough"))
                }
            }
        }
    }

    private func checkboxIndicator(checked: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .stroke(checked ? Color.white : Color.white.opacity(0.3), lineWidth: 1)
                .frame(width: 14, height: 14)
            if checked {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.black)
            }
        }
    }

    // MARK: - Button Styles

    private func primaryButton(title: String, id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        actionButton(
            title: title,
            id: id,
            disabled: disabled,
            foregroundColor: disabled ? .white.opacity(0.25) : .white,
            fillColor: disabled ? Color.white.opacity(0.04) : (hoveredButton == id ? Color.white.opacity(0.18) : Color.white.opacity(0.12)),
            borderColor: disabled ? Color.white.opacity(0.04) : Color.white.opacity(0.06),
            action: action
        )
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovering in
            if isHovering { hoveredButton = id } else if hoveredButton == id { hoveredButton = nil }
        }
    }

    private func secondaryButton(title: String, id: String, action: @escaping () -> Void) -> some View {
        actionButton(
            title: title,
            id: id,
            foregroundColor: .white.opacity(0.68),
            fillColor: hoveredButton == id ? Color.white.opacity(0.10) : Color.white.opacity(0.06),
            borderColor: hoveredButton == id ? Color.white.opacity(0.10) : Color.white.opacity(0.05),
            action: action
        )
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { hoveredButton = id } else if hoveredButton == id { hoveredButton = nil }
        }
    }

    private func tertiaryButton(title: String, id: String, action: @escaping () -> Void) -> some View {
        actionButton(
            title: title,
            id: id,
            foregroundColor: hoveredButton == id ? .white.opacity(0.58) : .white.opacity(0.42),
            fillColor: hoveredButton == id ? Color.white.opacity(0.06) : Color.white.opacity(0.02),
            borderColor: hoveredButton == id ? Color.white.opacity(0.08) : Color.white.opacity(0.04),
            action: action
        )
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { hoveredButton = id } else if hoveredButton == id { hoveredButton = nil }
        }
    }

    private func actionButton(
        title: String,
        id: String,
        disabled: Bool = false,
        foregroundColor: Color,
        fillColor: Color,
        borderColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(maxWidth: .infinity, minHeight: Self.actionButtonMinHeight)
                .background(
                    RoundedRectangle(cornerRadius: Self.actionButtonCornerRadius, style: .continuous)
                        .fill(fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.actionButtonCornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.5)
                )
        }
        .disabled(disabled)
        .accessibilityIdentifier(id)
    }

    // MARK: - Helpers

    private func formatJSON(_ anyCodable: AnyCodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(anyCodable),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "Unknown Input"
    }

    private func activeQuestion(in questions: [AskUserQuestionQuestion]) -> AskUserQuestionQuestion? {
        guard questions.indices.contains(currentQuestionIndex) else { return questions.first }
        return questions[currentQuestionIndex]
    }

    private func submitQuestionnaire(_ questions: [AskUserQuestionQuestion]) {
        onDecision(
            PermissionDecision(
                decision: "allow",
                content: drafts.content(for: questions)
            )
        )
    }

    private func textColor(isSelected: Bool, optionLabel: String) -> Color {
        if isSelected {
            return .white.opacity(0.9)
        }
        return hoveredOption == optionLabel ? .white.opacity(0.9) : .white.opacity(0.7)
    }

    private func backgroundColor(isSelected: Bool, optionLabel: String) -> Color {
        if isSelected {
            return Color.white.opacity(0.10)
        }
        return hoveredOption == optionLabel ? Color.white.opacity(0.07) : Color.white.opacity(0.04)
    }

    private var relevantPermissionSuggestions: [PermissionUpdateEntry]? {
        guard let permissionSuggestions else {
            return nil
        }
        let filtered = permissionSuggestions.filter { suggestion in
            if suggestion.type == "setMode" {
                return true
            }
            return suggestion.behavior == nil || suggestion.behavior == "allow"
        }
        return filtered.isEmpty ? nil : filtered
    }

    private func permissionSuggestionTitle(_ suggestion: PermissionUpdateEntry, totalCount: Int) -> String {
        let scope = permissionSuggestionScope(suggestion)
        if suggestion.type == "setMode", let mode = suggestion.mode {
            let base = permissionModeTitle(mode)
            return totalCount > 1 && !scope.isEmpty ? "\(base) (\(scope))" : base
        }

        let base: String
        switch suggestion.behavior {
        case "deny":
            base = "Always Deny"
        case "ask":
            base = "Always Ask"
        default:
            base = "Always Allow"
        }

        return totalCount > 1 && !scope.isEmpty ? "\(base) (\(scope))" : base
    }

    private func permissionSuggestionScope(_ suggestion: PermissionUpdateEntry) -> String {
        switch suggestion.destination {
        case "session":
            return "Session"
        case "localSettings":
            return "Local"
        case "projectSettings":
            return "Project"
        case "userSettings":
            return "User"
        default:
            return ""
        }
    }

    private func permissionModeTitle(_ mode: String) -> String {
        switch mode {
        case "acceptEdits":
            return "Always Allow Edits"
        case "dontAsk":
            return "Don't Ask Again"
        case "bypassPermissions":
            return "Bypass Permissions"
        case "plan":
            return "Stay in Plan Mode"
        default:
            return "Set Mode: \(mode)"
        }
    }
}

struct AskUserQuestionOption: Equatable {
    let label: String
    let description: String?
}

struct AskUserQuestionQuestion: Identifiable, Equatable {
    let id: String
    let header: String?
    let question: String
    let options: [AskUserQuestionOption]
    let isMultiSelect: Bool
}

struct AskUserQuestionDrafts: Equatable {
    private var singleSelections: [String: String] = [:]
    private var multiSelections: [String: Set<String>] = [:]

    mutating func selectSingle(_ option: String, for question: AskUserQuestionQuestion) {
        singleSelections[question.id] = option
    }

    mutating func toggleMulti(_ option: String, for question: AskUserQuestionQuestion) {
        var selected = multiSelections[question.id, default: []]
        if selected.contains(option) {
            selected.remove(option)
        } else {
            selected.insert(option)
        }
        multiSelections[question.id] = selected
    }

    func contains(_ option: String, for question: AskUserQuestionQuestion) -> Bool {
        multiSelections[question.id]?.contains(option) == true
    }

    func hasAnswer(for question: AskUserQuestionQuestion) -> Bool {
        !answers(for: question).isEmpty
    }

    func answers(for question: AskUserQuestionQuestion) -> [String] {
        if question.isMultiSelect {
            let selected = multiSelections[question.id] ?? []
            return question.options.map(\.label).filter { selected.contains($0) }
        }
        if let single = singleSelections[question.id] {
            return [single]
        }
        return []
    }

    func content(for questions: [AskUserQuestionQuestion]) -> AnyCodable {
        if questions.count == 1, let question = questions.first {
            return .object([
                "answers": .array(answers(for: question).map(AnyCodable.string))
            ])
        }

        return .object([
            "responses": .array(
                questions.map { question in
                    .object([
                        "id": .string(question.id),
                        "answers": .array(answers(for: question).map(AnyCodable.string))
                    ])
                }
            )
        ])
    }
}

func extractAskUserQuestions(from anyCodable: AnyCodable) -> [AskUserQuestionQuestion]? {
    guard case .object(let dict) = anyCodable,
          case .array(let questionsArray) = dict["questions"] else {
        return nil
    }

    var questions: [AskUserQuestionQuestion] = []
    for (index, qAny) in questionsArray.enumerated() {
        guard case .object(let qDict) = qAny,
              case .string(let questionText) = qDict["question"] else {
            continue
        }

        let id: String
        if let idAny = qDict["id"], case .string(let explicitId) = idAny, !explicitId.isEmpty {
            id = explicitId
        } else {
            id = "question-\(index + 1)"
        }

        var header: String?
        if let headerAny = qDict["header"], case .string(let explicitHeader) = headerAny {
            header = explicitHeader
        }

        var isMultiSelect = false
        if let multiSelectAny = qDict["multiSelect"], case .bool(let ms) = multiSelectAny {
            isMultiSelect = ms
        }

        var options: [AskUserQuestionOption] = []
        if let optionsAny = qDict["options"], case .array(let optsArray) = optionsAny {
            for optAny in optsArray {
                if case .object(let optDict) = optAny,
                   case .string(let label) = optDict["label"] {
                    var desc: String?
                    if let descAny = optDict["description"], case .string(let explicitDescription) = descAny {
                        desc = explicitDescription
                    }
                    options.append(AskUserQuestionOption(label: label, description: desc))
                } else if case .string(let label) = optAny {
                    options.append(AskUserQuestionOption(label: label, description: nil))
                }
            }
        }

        questions.append(
            AskUserQuestionQuestion(
                id: id,
                header: header,
                question: questionText,
                options: options,
                isMultiSelect: isMultiSelect
            )
        )
    }

    return questions
}
