import SwiftUI

public struct ElicitationView: View {
    public let message: String
    public let requestedSchema: AnyCodable?
    public let onDecision: (PermissionDecision) -> Void

    @State private var inputText: String = ""
    @State private var hoveredButton: String?
    @State private var hoveredOption: String?

    public init(message: String, requestedSchema: AnyCodable?, onDecision: @escaping (PermissionDecision) -> Void) {
        self.message = message
        self.requestedSchema = requestedSchema
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))

            if let schema = requestedSchema, let enumOptions = extractEnum(from: schema) {
                enumSelectBody(enumOptions)
            } else {
                textInputBody
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

    // MARK: - Enum Select (tap to submit)

    private func enumSelectBody(_ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            enumOptionsList(options)
            enumActionButtons
        }
    }

    private func enumOptionsList(_ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.self) { opt in
                enumOptionRow(opt)
            }
        }
    }

    private func enumOptionRow(_ opt: String) -> some View {
        let isHovered = hoveredOption == opt
        return Button(action: {
            let content = AnyCodable.string(opt)
            onDecision(PermissionDecision(decision: "accept", content: content))
        }) {
            HStack {
                Text(opt)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHovered ? .white.opacity(0.9) : .white.opacity(0.7))
                Spacer()
            }
            .padding(8)
            .background(isHovered ? Color.white.opacity(0.07) : Color.white.opacity(0.04))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredOption = isHovering ? opt : (hoveredOption == opt ? nil : hoveredOption)
        }
    }

    private var enumActionButtons: some View {
        VStack(spacing: 4) {
            secondaryButton(title: "Decline", id: "decline") {
                onDecision(PermissionDecision(decision: "decline"))
            }
            tertiaryButton(title: "Continue in terminal", id: "passthrough") {
                onDecision(PermissionDecision(decision: "passthrough"))
            }
        }
    }

    // MARK: - Text Input

    private var textInputBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Enter value...", text: $inputText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(8)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )

            VStack(spacing: 4) {
                primaryButton(title: "Accept", id: "accept") {
                    let content = AnyCodable.string(inputText)
                    onDecision(PermissionDecision(decision: "accept", content: content))
                }
                secondaryButton(title: "Decline", id: "decline") {
                    onDecision(PermissionDecision(decision: "decline"))
                }
                tertiaryButton(title: "Continue in terminal", id: "passthrough") {
                    onDecision(PermissionDecision(decision: "passthrough"))
                }
            }
        }
    }

    // MARK: - Button Styles

    private func primaryButton(title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(hoveredButton == id ? Color.white.opacity(0.18) : Color.white.opacity(0.12))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
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

    private func extractEnum(from schema: AnyCodable) -> [String]? {
        if case .object(let dict) = schema,
           case .array(let enumArray) = dict["enum"] {
            var options: [String] = []
            for item in enumArray {
                if case .string(let str) = item {
                    options.append(str)
                }
            }
            return options.isEmpty ? nil : options
        }
        return nil
    }
}
