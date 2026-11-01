import AppKit
import Combine
import SwiftUI

/// The uncommitted changes of a repository, like the source control panel of
/// an editor: stage, unstage and discard files, commit, push and switch
/// branches. Connected to a terminal, it follows that terminal's folder.
final class SuperNodeDiffView: SuperNodeNodeView {
    let model = SuperNodeGitModel()
    private var cancellables: Set<AnyCancellable> = []

    override init(item: SuperNodeItem) {
        super.init(item: item)
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let content = SuperNodeDiffBody(
            model: model,
            onOpen: { [weak self] change in self?.open(change) },
            onDiscard: { [weak self] changes in self?.confirmDiscard(changes) },
            onDiscardHunk: { [weak self] hunk, file in self?.confirmDiscard(hunk, of: file) },
            onNewBranch: { [weak self] in self?.promptNewBranch() })
        body = NSHostingView(rootView: content)

        header.addButton(symbol: "folder", tooltip: "Choose a folder", target: self, action: #selector(chooseFolder))
        header.addButton(symbol: "arrow.clockwise", tooltip: "Refresh", target: self, action: #selector(refreshNow))

        model.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshHeader() }
            .store(in: &cancellables)
        refreshHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The repository shown: the folder of a connected terminal, or the folder
    /// the user chose.
    var directory: String? {
        canvas?.sourceDirectory(for: self) ?? item.directory
    }

    override func refreshHeader() {
        super.refreshHeader()
        let status = model.status
        var parts: [String] = []
        if let directory = model.directory { parts.append((directory as NSString).abbreviatingWithTildeInPath) }
        if let branch = status.branch { parts.append(branch) }
        if status.error == nil, model.directory != nil {
            let count = Set((status.staged + status.unstaged).map(\.path)).count
            parts.append(count == 1 ? "1 file" : "\(count) files")
        }
        header.subtitleLabel.stringValue = parts.joined(separator: " · ")
        if status.error == nil, !status.isClean {
            header.badge.show("+\(status.added) −\(status.removed)", color: .systemGreen)
        } else {
            header.badge.show(nil, color: .clear)
        }
    }

    @objc func refreshNow() {
        reload()
    }

    /// Follows the current folder and reloads the changes in the background.
    func reload() {
        model.setDirectory(directory)
        model.refresh()
        refreshHeader()
    }

    override func tearDown() {
        cancellables.removeAll()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Show Changes"
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        item.directory = url.path
        canvas?.disconnectSources(of: self)
        canvas?.documentDidChange()
        reload()
    }

    private func open(_ change: SuperNodeGit.Change) {
        guard let directory = model.directory, change.code != "D" else { return }
        let path = URL(fileURLWithPath: directory).appendingPathComponent(change.path).path
        model.patchText(for: change) { [weak self] patch in
            guard let self else { return }
            self.canvas?.openEditor(path: path, line: SuperNodeGit.firstChangedLine(in: patch), from: self)
        }
    }

    private func confirmDiscard(_ changes: [SuperNodeGit.Change]) {
        guard !changes.isEmpty, let window else { return }
        let alert = NSAlert()
        if changes.count == 1, let change = changes.first {
            alert.messageText = "Discard changes to \(change.name)?"
            alert.informativeText = change.isUntracked
                ? "The file will be moved to the Trash."
                : "Your changes to this file will be lost."
        } else {
            alert.messageText = "Discard changes to \(changes.count) files?"
            alert.informativeText = "Changes to tracked files will be lost. New files will be moved to the Trash."
        }
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.discard(changes)
        }
    }

    private func confirmDiscard(_ hunk: SuperNodePatchFile.Hunk, of file: SuperNodePatchFile) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Discard this change to \((file.path as NSString).lastPathComponent)?"
        alert.informativeText = "The lines in this hunk go back to how they were in the index."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.apply(.discard, hunk: hunk, of: file)
        }
    }

    private func promptNewBranch() {
        canvas?.prompt(title: "New Branch", message: "Create a branch from the current one and switch to it.", value: "") { [weak self] name in
            guard !name.isEmpty else { return }
            self?.model.createBranch(name)
        }
    }
}

// MARK: - SwiftUI

private struct SuperNodeDiffBody: View {
    @ObservedObject var model: SuperNodeGitModel
    let onOpen: (SuperNodeGit.Change) -> Void
    let onDiscard: ([SuperNodeGit.Change]) -> Void
    let onDiscardHunk: (SuperNodePatchFile.Hunk, SuperNodePatchFile) -> Void
    let onNewBranch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.directory == nil {
                placeholder("Connect a terminal to this node, or choose a folder.")
            } else if let error = model.status.error {
                placeholder(error)
            } else {
                commitBar
                Divider()
                if model.status.isClean {
                    placeholder("No changes. The working tree is clean.")
                } else {
                    VSplitView {
                    fileList
                        .frame(minHeight: 60, idealHeight: 150, maxHeight: .infinity)
                    SuperNodePatchList(model: model, onDiscardHunk: onDiscardHunk)
                        .frame(minHeight: 60, maxHeight: .infinity)
                    }
                }
            }
            if let message = model.message {
                messageBar(message)
            }
        }
        .font(.system(size: 12))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Commit bar

    private var commitBar: some View {
        let status = model.status
        let commitsAll = status.staged.isEmpty
        return HStack(spacing: 6) {
            branchMenu

            if status.ahead > 0 || status.behind > 0 {
                Text([status.ahead > 0 ? "↑\(status.ahead)" : nil, status.behind > 0 ? "↓\(status.behind)" : nil]
                    .compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            TextField("Commit message", text: $model.commitMessage)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { model.commit(stagingAll: commitsAll) }

            Button(commitsAll ? "Commit All" : "Commit") {
                model.commit(stagingAll: commitsAll)
            }
            .controlSize(.small)
            .disabled(status.isClean || model.isBusy)
            .help(commitsAll ? "Stage every change and commit" : "Commit the staged changes")

            Menu {
                Button("Push") { model.push() }
                Button("Pull") { model.pull() }
                Divider()
                Button("Stage All Changes") { model.stage(status.unstaged) }
                    .disabled(status.unstaged.isEmpty)
                Button("Unstage All Changes") { model.unstage(status.staged) }
                    .disabled(status.staged.isEmpty)
                Button("Discard All Changes…") { onDiscard(status.unstaged) }
                    .disabled(status.unstaged.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if model.isBusy {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var branchMenu: some View {
        Menu {
            ForEach(model.branches, id: \.self) { branch in
                Button {
                    model.checkout(branch)
                } label: {
                    if branch == model.status.branch {
                        Label(branch, systemImage: "checkmark")
                    } else {
                        Text(branch)
                    }
                }
            }
            Divider()
            Button("New Branch…", action: onNewBranch)
        } label: {
            Label(model.status.branch ?? "No branch", systemImage: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch branch")
    }

    // MARK: Files

    private var fileList: some View {
        let status = model.status
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SuperNodeAllChangesRow(isSelected: model.selection == nil) { model.select(nil) }

                if !status.staged.isEmpty {
                    sectionHeader("Staged Changes", count: status.staged.count) {
                        iconButton("minus", "Unstage all") { model.unstage(status.staged) }
                    }
                    ForEach(status.staged) { row($0) }
                }
                if !status.unstaged.isEmpty {
                    sectionHeader("Changes", count: status.unstaged.count) {
                        iconButton("arrow.uturn.backward", "Discard all changes") { onDiscard(status.unstaged) }
                        iconButton("plus", "Stage all") { model.stage(status.unstaged) }
                    }
                    ForEach(status.unstaged) { row($0) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sectionHeader<Buttons: View>(_ title: String, count: Int, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .background(Color.secondary.opacity(0.2), in: Capsule())
            Spacer()
            buttons()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(_ change: SuperNodeGit.Change) -> some View {
        SuperNodeChangeRow(
            change: change,
            isSelected: model.selection == change,
            onSelect: { model.select(change) },
            onOpen: { onOpen(change) },
            onDiscard: { onDiscard([change]) },
            onToggleStage: {
                if change.staged { model.unstage([change]) } else { model.stage([change]) }
            })
    }

    private func messageBar(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
            Text(message)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.message = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .padding(8)
        .background(Color.orange.opacity(0.15))
    }
}

private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
}

private struct SuperNodeAllChangesRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text("All Changes")
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct SuperNodeChangeRow: View {
    let change: SuperNodeGit.Change
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDiscard: () -> Void
    let onToggleStage: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(change.isUntracked ? "U" : String(change.code))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(change.color))
                .frame(width: 14)
            Text(change.name)
                .lineLimit(1)
                .strikethrough(change.code == "D")
            Text(change.folder)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if isHovered || isSelected {
                if change.code != "D" {
                    iconButton("doc.text", "Open in an editor node", action: onOpen)
                }
                if !change.staged {
                    iconButton("arrow.uturn.backward", "Discard changes", action: onDiscard)
                }
                iconButton(change.staged ? "minus" : "plus", change.staged ? "Unstage" : "Stage", action: onToggleStage)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(isSelected ? Color.accentColor.opacity(0.25) : isHovered ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .help(change.path)
    }
}

// MARK: - Patch

/// The patch of the selected file, hunk by hunk with line numbers and syntax
/// colors. A file's hunks can be staged, unstaged or discarded one at a time.
private struct SuperNodePatchList: View {
    @ObservedObject var model: SuperNodeGitModel
    let onDiscardHunk: (SuperNodePatchFile.Hunk, SuperNodePatchFile) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    if model.files.isEmpty {
                        Text("No changes.")
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(model.files) { file in
                        SuperNodePatchFileView(model: model, file: file, onDiscardHunk: onDiscardHunk)
                    }
                }
                .padding(.bottom, 8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: model.patchID) { _ in proxy.scrollTo("top", anchor: .top) }
        }
    }
}

private struct SuperNodePatchFileView: View {
    @ObservedObject var model: SuperNodeGitModel
    let file: SuperNodePatchFile
    let onDiscardHunk: (SuperNodePatchFile.Hunk, SuperNodePatchFile) -> Void

    var body: some View {
        let syntax = SuperNodeSyntax.forFile(file.path)
        // Hunk buttons need to know which side the patch came from.
        let change = model.selection.flatMap { $0.isUntracked ? nil : $0 }
        let actionable = change != nil && file.canApplyHunks && !model.isBusy

        if model.selection == nil {
            Text(file.path)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 4)
        }
        if file.hunks.isEmpty {
            Text(file.header.contains { $0.hasPrefix("Binary") } ? "Binary file" : "No text changes")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        ForEach(file.hunks) { hunk in
            HStack(spacing: 6) {
                Text(hunk.header)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(NSColor.systemCyan))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if actionable, let change {
                    if change.staged {
                        hunkButton("Unstage", "minus") { model.apply(.unstage, hunk: hunk, of: file) }
                    } else {
                        hunkButton("Discard", "arrow.uturn.backward") { onDiscardHunk(hunk, file) }
                        hunkButton("Stage", "plus") { model.apply(.stage, hunk: hunk, of: file) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(NSColor.systemCyan).opacity(0.08))
            .padding(.top, hunk.index == 0 ? 2 : 8)

            ForEach(SuperNodePatchRow.rows(of: hunk)) { row in
                SuperNodePatchRowView(row: row, syntax: syntax)
            }
        }
    }

    private func hunkButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .help("\(title) this hunk")
    }
}

/// One line of a hunk with its old and new line numbers.
private struct SuperNodePatchRow: Identifiable {
    enum Kind { case context, added, removed, note }

    /// Unique across the patch: rows of every hunk share one lazy list.
    let id: String
    let kind: Kind
    let old: Int?
    let new: Int?
    let text: String

    static func rows(of hunk: SuperNodePatchFile.Hunk) -> [SuperNodePatchRow] {
        var old = hunk.oldStart, new = hunk.newStart
        var rows: [SuperNodePatchRow] = []
        for (offset, line) in hunk.lines.enumerated() {
            let index = "\(hunk.id)-\(offset)"
            let body = String(line.dropFirst())
            switch line.first ?? " " {
            case "+":
                rows.append(SuperNodePatchRow(id: index, kind: .added, old: nil, new: new, text: body))
                new += 1
            case "-":
                rows.append(SuperNodePatchRow(id: index, kind: .removed, old: old, new: nil, text: body))
                old += 1
            case "\\":
                rows.append(SuperNodePatchRow(id: index, kind: .note, old: nil, new: nil, text: line))
            default:
                rows.append(SuperNodePatchRow(id: index, kind: .context, old: old, new: new, text: body))
                old += 1
                new += 1
            }
        }
        return rows
    }
}

private struct SuperNodePatchRowView: View {
    let row: SuperNodePatchRow
    let syntax: SuperNodeSyntax?

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(row.old)
            number(row.new)
            Text(marker)
                .foregroundStyle(markerColor)
                .frame(width: 16)
            Text(content)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.trailing, 6)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: String {
        switch row.kind {
        case .added: "+"
        case .removed: "−"
        case .context, .note: ""
        }
    }

    private var markerColor: Color {
        row.kind == .added ? .green : .red
    }

    private var background: Color {
        switch row.kind {
        case .added: Color.green.opacity(0.12)
        case .removed: Color.red.opacity(0.12)
        case .context, .note: .clear
        }
    }

    private var content: AttributedString {
        if row.kind == .note {
            var text = AttributedString(row.text)
            text.foregroundColor = .secondary
            return text
        }
        let base: NSColor = row.kind == .context ? .secondaryLabelColor : .labelColor
        let highlighted = syntax?.highlight(row.text, font: Self.font, color: base)
            ?? NSAttributedString(string: row.text, attributes: [.font: Self.font, .foregroundColor: base])
        return (try? AttributedString(highlighted, including: \.appKit)) ?? AttributedString(row.text)
    }
}
