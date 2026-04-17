import SwiftUI

public struct PermissionView: View {
    public let toolName: String
    public let toolInput: AnyCodable
    public let onDecision: (PermissionDecision) -> Void

    @State private var selectedOptions: Set<String> = []
    @State private var hoveredButton: String?
    @State private var hoveredOption: String?

    public init(toolName: String, toolInput: AnyCodable, onDecision: @escaping (PermissionDecision) -> Void) {
        self.toolName = toolName
        self.toolInput = toolInput
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
        if let questions = extractQuestions(from: toolInput), let firstQ = questions.first {
            VStack(alignment: .leading, spacing: 10) {
                Text(firstQ.question)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))

                if let options = firstQ.options {
                    if firstQ.isMultiSelect {
                        multiSelectOptions(options)
                    } else {
                        singleSelectOptions(options)
                    }
                }

                VStack(spacing: 4) {
                    if firstQ.isMultiSelect {
                        let count = selectedOptions.count
                        primaryButton(
                            title: count > 0 ? "Submit (\(count) selected)" : "Submit",
                            id: "allow",
                            disabled: selectedOptions.isEmpty
                        ) {
                            let answers = Array(selectedOptions)
                            let content = AnyCodable.object(["answers": .array(answers.map { .string($0) })])
                            onDecision(PermissionDecision(decision: "allow", content: content))
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
    }

    // MARK: - Single Select (tap to submit)

    private func singleSelectOptions(_ options: [ExtractedOption]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.label) { opt in
                Button(action: {
                    let content = AnyCodable.object(["answers": .array([.string(opt.label)])])
                    onDecision(PermissionDecision(decision: "allow", content: content))
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(hoveredOption == opt.label ? .white.opacity(0.9) : .white.opacity(0.7))
                            if let desc = opt.description {
                                Text(desc)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(hoveredOption == opt.label ? Color.white.opacity(0.07) : Color.white.opacity(0.04))
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

    private func multiSelectOptions(_ options: [ExtractedOption]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.label) { opt in
                let isSelected = selectedOptions.contains(opt.label)
                Button(action: {
                    if isSelected {
                        selectedOptions.remove(opt.label)
                    } else {
                        selectedOptions.insert(opt.label)
                    }
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
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(disabled ? .white.opacity(0.25) : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(disabled ? Color.white.opacity(0.04) : (hoveredButton == id ? Color.white.opacity(0.18) : Color.white.opacity(0.12)))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovering in
            if isHovering { hoveredButton = id } else if hoveredButton == id { hoveredButton = nil }
        }
    }

    private func secondaryButton(title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(hoveredButton == id ? Color.white.opacity(0.10) : Color.white.opacity(0.06))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { hoveredButton = id } else if hoveredButton == id { hoveredButton = nil }
        }
    }

    private func tertiaryButton(title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hoveredButton == id ? .white.opacity(0.6) : .white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { hoveredButton = id } else if hoveredButton == id { hoveredButton = nil }
        }
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

    private struct ExtractedQuestion {
        let question: String
        let options: [ExtractedOption]?
        let isMultiSelect: Bool
    }

    private struct ExtractedOption {
        let label: String
        let description: String?
    }

    private func extractQuestions(from anyCodable: AnyCodable) -> [ExtractedQuestion]? {
        guard case .object(let dict) = anyCodable,
              case .array(let questionsArray) = dict["questions"] else {
            return nil
        }

        var questions: [ExtractedQuestion] = []
        for qAny in questionsArray {
            guard case .object(let qDict) = qAny,
                  case .string(let questionText) = qDict["question"] else {
                continue
            }

            var isMultiSelect = false
            if let multiSelectAny = qDict["multiSelect"], case .bool(let ms) = multiSelectAny {
                isMultiSelect = ms
            }

            var options: [ExtractedOption]? = nil
            if let optionsAny = qDict["options"], case .array(let optsArray) = optionsAny {
                var extractedOpts: [ExtractedOption] = []
                for optAny in optsArray {
                    if case .object(let optDict) = optAny,
                       case .string(let label) = optDict["label"] {
                        var desc: String? = nil
                        if let descAny = optDict["description"], case .string(let d) = descAny {
                            desc = d
                        }
                        extractedOpts.append(ExtractedOption(label: label, description: desc))
                    } else if case .string(let strOpt) = optAny {
                        extractedOpts.append(ExtractedOption(label: strOpt, description: nil))
                    }
                }
                options = extractedOpts
            }

            questions.append(ExtractedQuestion(question: questionText, options: options, isMultiSelect: isMultiSelect))
        }
        return questions
    }
}
