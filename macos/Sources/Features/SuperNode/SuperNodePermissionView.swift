import SwiftUI

/// Shown over an agent's terminal while Claude waits for you: a tool to allow,
/// a plan to approve, or questions to answer. Claude's own prompt in the
/// terminal works too; whichever answers first wins.
struct SuperNodePermissionPanel: View {
    let permission: SuperNodeAgentState.Permission
    let collapsed: Bool
    let onToggleCollapsed: () -> Void
    let onAnswer: (SuperNodePermissionAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch permission.kind {
            case .tool:
                toolBar
            case let .plan(plan):
                header(icon: "list.bullet.clipboard", title: "Claude has a plan for you to review")
                if !collapsed {
                    Divider()
                    SuperNodePlanReview(plan: plan, onAnswer: onAnswer)
                }
            case let .questions(questions):
                header(icon: "questionmark.bubble", title: questions.count == 1
                       ? "Claude is asking you a question"
                       : "Claude is asking you \(questions.count) questions")
                if !collapsed {
                    Divider()
                    SuperNodeQuestionForm(questions: questions, onAnswer: onAnswer)
                }
            }
        }
        .controlSize(.small)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.6)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }

    private var toolBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude wants to use \(permission.tool)")
                    .font(.system(size: 12, weight: .semibold))
                if let summary = permission.summary {
                    Text(summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button("Deny") { onAnswer(.deny) }
            Button("Allow") { onAnswer(.allow) }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
    }

    private func header(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            Button("Answer in Terminal") { onAnswer(.pass) }
                .help("Close this and use Claude's prompt in the terminal")
            Button {
                onToggleCollapsed()
            } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
            }
            .help(collapsed ? "Show" : "Hide")
        }
        .padding(10)
    }
}

// MARK: - Plans

private struct SuperNodePlanReview: View {
    let plan: String
    let onAnswer: (SuperNodePermissionAnswer) -> Void

    @State private var revising = false
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                SuperNodeMarkdown(text: plan)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            if revising {
                HStack(spacing: 6) {
                    TextField("What should Claude change?", text: $feedback)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { onAnswer(.revisePlan(feedback)) }
                    Button("Cancel") { revising = false }
                    Button("Send") { onAnswer(.revisePlan(feedback)) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
            } else {
                HStack(spacing: 6) {
                    Button("Keep Planning…") { revising = true }
                    Spacer(minLength: 6)
                    Menu("Approve and…") {
                        Button("Auto-Accept Edits") { onAnswer(.approvePlan(mode: "acceptEdits")) }
                        Button("Ask Before Each Edit") { onAnswer(.approvePlan(mode: "default")) }
                    }
                    .fixedSize()
                    Button("Approve") { onAnswer(.approvePlan(mode: nil)) }
                        .buttonStyle(.borderedProminent)
                        .help("Approve and go back to the mode before planning")
                }
                .padding(10)
            }
        }
    }
}

/// Plain Markdown: headings, lists, code blocks and inline styles.
private struct SuperNodeMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, line):
                    inline(line)
                        .font(.system(size: level == 1 ? 15 : level == 2 ? 13.5 : 12.5, weight: .semibold))
                        .padding(.top, 6)
                case let .code(code):
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                case let .item(indent, marker, line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        inline(line)
                    }
                    .padding(.leading, CGFloat(indent) * 6)
                case let .paragraph(line):
                    inline(line)
                case .blank:
                    Spacer().frame(height: 2)
                }
            }
        }
        .font(.system(size: 12))
    }

    private enum Block {
        case heading(Int, String), code(String), item(Int, String, String), paragraph(String), blank
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        var code: [String]?
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            if trimmed.isEmpty {
                blocks.append(.blank)
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
                      trimmed[hashes] == " " {
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                blocks.append(.heading(level, String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.item(indent, "•", String(trimmed.dropFirst(2))))
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
                      trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                blocks.append(.item(indent, String(trimmed[...dot]), String(trimmed[trimmed.index(dot, offsetBy: 2)...])))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        return blocks
    }

    private func inline(_ line: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: line, options: options)) ?? AttributedString(line))
    }
}

// MARK: - Questions

private struct SuperNodeQuestionForm: View {
    let questions: [SuperNodeAgentState.Question]
    let onAnswer: (SuperNodePermissionAnswer) -> Void

    /// Chosen labels by question.
    @State private var chosen: [String: Set<String>] = [:]
    /// Typed answers by question, used when "Other" is chosen.
    @State private var other: [String: String] = [:]
    @State private var otherChosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(questions) { question in
                        questionView(question)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Submit") { onAnswer(.answers(answers)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isComplete)
            }
            .padding(10)
        }
    }

    private func questionView(_ question: SuperNodeAgentState.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.text)
                .font(.system(size: 12.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if question.multiSelect {
                Text("Choose any")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            ForEach(question.options) { option in
                optionRow(question, label: option.label, description: option.description)
            }
            optionRow(question, label: nil, description: nil)
        }
    }

    /// One choice; a nil label is "Other" with a text field.
    private func optionRow(_ question: SuperNodeAgentState.Question, label: String?, description: String?) -> some View {
        let selected = label.map { chosen[question.text, default: []].contains($0) } ?? otherChosen.contains(question.text)
        let symbol = question.multiSelect
            ? (selected ? "checkmark.square.fill" : "square")
            : (selected ? "largecircle.fill.circle" : "circle")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let label {
                    Text(label)
                        .font(.system(size: 12))
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    TextField("Other…", text: Binding(
                        get: { other[question.text] ?? "" },
                        set: { value in
                            other[question.text] = value
                            if !value.isEmpty { choose(question, label: nil, on: true) }
                        }))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(question, label: label, on: !selected) }
    }

    private func choose(_ question: SuperNodeAgentState.Question, label: String?, on: Bool) {
        if !question.multiSelect && on {
            chosen[question.text] = []
            otherChosen.remove(question.text)
        }
        if let label {
            if on { chosen[question.text, default: []].insert(label) } else { chosen[question.text]?.remove(label) }
        } else if on {
            otherChosen.insert(question.text)
        } else {
            otherChosen.remove(question.text)
        }
    }

    private func answer(for question: SuperNodeAgentState.Question) -> String? {
        // Keep the options' order, then the typed answer, as Claude's own picker does.
        var parts = question.options.map(\.label).filter { chosen[question.text, default: []].contains($0) }
        if otherChosen.contains(question.text), let text = other[question.text]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Claude asks every question at once and wants every one answered.
    private var isComplete: Bool {
        questions.allSatisfy { answer(for: $0) != nil }
    }

    private var answers: [String: String] {
        var answers: [String: String] = [:]
        for question in questions {
            if let answer = answer(for: question) { answers[question.text] = answer }
        }
        return answers
    }
}
