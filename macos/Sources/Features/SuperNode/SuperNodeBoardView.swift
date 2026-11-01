import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The board view of the canvas: terminals, agents and notes as cards in
/// columns. Cards are the live nodes; moving a card doesn't touch what's
/// running in it, and opening one shows the real terminal.
final class SuperNodeBoardModel: ObservableObject {
    struct Card: Identifiable, Equatable {
        let id: UUID
        let kind: SuperNodeItem.Kind
        let title: String
        let status: String?
        let statusColor: NSColor?
        let subtitle: String
        let preview: String?
        let column: UUID
        let order: Double
        let priority: SuperNodePriority?
        let due: Date?
        let commentCount: Int
        let color: SuperNodeColor
    }

    @Published private(set) var columns: [SuperNodeColumn] = []
    @Published private(set) var cards: [Card] = []
    /// The card open in the detail view.
    @Published var openCard: UUID?

    weak var canvas: SuperNodeCanvasView?
    private var timer: Timer?

    func cards(in column: SuperNodeColumn) -> [Card] {
        cards.filter { $0.column == column.id }.sorted { $0.order < $1.order }
    }

    func card(_ id: UUID) -> Card? {
        cards.first { $0.id == id }
    }

    /// Cards show live status and output, refreshed while the board is shown.
    func setRefreshing(_ refreshing: Bool) {
        timer?.invalidate()
        timer = nil
        guard refreshing else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard let canvas else { return }
        let columns = canvas.document.columns
        let first = columns.first?.id ?? UUID()
        let cards = canvas.nodeViews.filter(\.item.isCard).enumerated().map { index, node -> Card in
            let item = node.item
            let terminal = node as? SuperNodeTerminalView
            let column = item.column.flatMap { id in columns.contains { $0.id == id } ? id : nil } ?? first
            var subtitle = ""
            if let directory = terminal?.directory {
                subtitle = (directory as NSString).abbreviatingWithTildeInPath
                if let branch = TabGitInfo.branch(at: directory) { subtitle += " · " + branch }
            }
            return Card(
                id: item.id,
                kind: item.kind,
                title: node.displayTitle,
                status: terminal?.status?.text,
                statusColor: terminal?.status?.color,
                subtitle: subtitle,
                preview: terminal.map { Self.preview(of: $0) } ?? item.text.map { String($0.prefix(240)) },
                column: column,
                order: item.boardOrder ?? Double(index),
                priority: item.priority,
                due: item.due,
                commentCount: item.comments?.count ?? 0,
                color: item.color)
        }
        if columns != self.columns { self.columns = columns }
        if cards != self.cards { self.cards = cards }
        if let openCard, card(openCard) == nil { self.openCard = nil }
    }

    /// The last few lines on a terminal's screen.
    private static func preview(of terminal: SuperNodeTerminalView) -> String {
        let lines = terminal.surface.cachedVisibleContents.get()
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: "\n")
    }

    // MARK: Changes

    func update(_ id: UUID, _ change: (inout SuperNodeItem) -> Void) {
        guard let node = canvas?.node(id) else { return }
        var item = node.item
        change(&item)
        node.item = item
        canvas?.documentDidChange()
        refresh()
    }

    /// Moves a card into a column, before another card or at the end.
    func move(_ id: UUID, to column: UUID, before target: UUID?) {
        guard id != target else { return }
        let others = cards.filter { $0.column == column && $0.id != id }.sorted { $0.order < $1.order }
        let order: Double
        if let target, let index = others.firstIndex(where: { $0.id == target }) {
            let previous = index > 0 ? others[index - 1].order : others[index].order - 1
            order = (previous + others[index].order) / 2
        } else {
            order = (others.last?.order ?? 0) + 1
        }
        update(id) {
            $0.column = column
            $0.boardOrder = order
        }
    }

    func addCard(_ kind: SuperNodeItem.Kind, agent: SuperNodeAgent? = nil, to column: UUID) {
        guard let node = canvas?.addNode(kind, agent: agent) else { return }
        move(node.item.id, to: column, before: nil)
    }

    func setColumns(_ columns: [SuperNodeColumn]) {
        canvas?.setColumns(columns)
        refresh()
    }

    func renameColumn(_ column: SuperNodeColumn) {
        canvas?.prompt(title: "Rename Column", message: nil, value: column.title) { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.setColumns(self.columns.map { $0.id == column.id ? SuperNodeColumn(id: $0.id, title: title) : $0 })
        }
    }

    func addColumn() {
        canvas?.prompt(title: "New Column", message: nil, value: "") { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.setColumns(self.columns + [SuperNodeColumn(title: title)])
        }
    }

    /// Removes a column; its cards move to the first remaining column.
    func deleteColumn(_ column: SuperNodeColumn) {
        let remaining = columns.filter { $0.id != column.id }
        guard let first = remaining.first else { return }
        for card in cards where card.column == column.id {
            update(card.id) { $0.column = first.id }
        }
        setColumns(remaining)
    }

    func showOnCanvas(_ id: UUID) {
        openCard = nil
        canvas?.showBoard(false)
        if let node = canvas?.node(id) { canvas?.reveal(node, zoomIn: true) }
    }

    func close(_ id: UUID) {
        if openCard == id { openCard = nil }
        if let node = canvas?.node(id) { canvas?.closeNode(node) }
    }
}

// MARK: - Views

struct SuperNodeBoardView: View {
    @ObservedObject var model: SuperNodeBoardModel
    let background: Color

    var body: some View {
        ZStack {
            background
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.columns) { column in
                        SuperNodeBoardColumn(model: model, column: column)
                    }
                    Button {
                        model.addColumn()
                    } label: {
                        Label("Add Column", systemImage: "plus")
                            .frame(width: 160, height: 36)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 44)
                .padding(.bottom, 70)
                .frame(maxHeight: .infinity, alignment: .top)
            }

            if let id = model.openCard, let card = model.card(id) {
                Color.black.opacity(0.35)
                    .onTapGesture { model.openCard = nil }
                SuperNodeCardDetail(model: model, card: card)
                    .padding(.horizontal, 40)
                    .padding(.top, 50)
                    .padding(.bottom, 76)
            }
        }
    }
}

private struct SuperNodeBoardColumn: View {
    @ObservedObject var model: SuperNodeBoardModel
    let column: SuperNodeColumn
    @State private var isTargeted = false

    var body: some View {
        let cards = model.cards(in: column)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(column.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(cards.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    addMenu
                    Divider()
                    Button("Rename…") { model.renameColumn(column) }
                    Button("Delete Column") { model.deleteColumn(column) }
                        .disabled(model.columns.count <= 1)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 4)
            .onTapGesture(count: 2) { model.renameColumn(column) }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { card in
                        SuperNodeBoardCard(model: model, card: card)
                            .onDrag { NSItemProvider(object: card.id.uuidString as NSString) }
                            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                drop(providers, before: card.id)
                            }
                    }
                }
                .padding(2)
            }

            Menu {
                addMenu
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(10)
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(isTargeted ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [UTType.text], isTargeted: $isTargeted) { providers in
            drop(providers, before: nil)
        }
    }

    @ViewBuilder
    private var addMenu: some View {
        Button("New Terminal") { model.addCard(.terminal, to: column.id) }
        ForEach(SuperNodeAgent.allCases, id: \.self) { agent in
            Button("New \(agent.name)") { model.addCard(.agent, agent: agent, to: column.id) }
        }
        Button("New Note") { model.addCard(.note, to: column.id) }
    }

    private func drop(_ providers: [NSItemProvider], before target: UUID?) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let id = UUID(uuidString: string) else { return }
            DispatchQueue.main.async {
                model.move(id, to: column.id, before: target)
            }
        }
        return true
    }
}

private struct SuperNodeBoardCard: View {
    @ObservedObject var model: SuperNodeBoardModel
    let card: SuperNodeBoardModel.Card
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: card.kind.symbol)
                    .foregroundStyle(card.color.nsColor.map { Color($0) } ?? .secondary)
                Text(card.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let status = card.status, let color = card.statusColor {
                    Text(status)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(color))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(color).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                }
            }

            if !card.subtitle.isEmpty {
                Text(card.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            if let preview = card.preview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 10, design: card.kind == .note ? .default : .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(card.kind == .note ? 4 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.black.opacity(card.kind == .note ? 0 : 0.25), in: RoundedRectangle(cornerRadius: 6))
            }

            if card.priority != nil || card.due != nil || card.commentCount > 0 {
                HStack(spacing: 6) {
                    if let priority = card.priority {
                        chip(priority.name, color: Color(priority.color))
                    }
                    if let due = card.due {
                        let overdue = due < Date()
                        chip(due.formatted(.dateTime.month(.abbreviated).day()), systemImage: "calendar", color: overdue ? .red : .secondary)
                    }
                    if card.commentCount > 0 {
                        chip("\(card.commentCount)", systemImage: "text.bubble", color: .secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(card.status == "NEEDS YOU" ? Color.orange : Color.primary.opacity(isHovered ? 0.25 : 0.1),
                              lineWidth: card.status == "NEEDS YOU" ? 1.5 : 1))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { model.openCard = card.id }
        .contextMenu {
            Button("Open") { model.openCard = card.id }
            Button("Show on Canvas") { model.showOnCanvas(card.id) }
            Menu("Move To") {
                ForEach(model.columns) { column in
                    Button(column.title) { model.move(card.id, to: column.id, before: nil) }
                }
            }
            Menu("Priority") {
                Button("None") { model.update(card.id) { $0.priority = nil } }
                ForEach(SuperNodePriority.allCases, id: \.self) { priority in
                    Button(priority.name) { model.update(card.id) { $0.priority = priority } }
                }
            }
            Divider()
            Button("Close Node") { model.close(card.id) }
        }
    }

    private func chip(_ text: String, systemImage: String? = nil, color: Color) -> some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Card detail

/// An open card: the live terminal (or note) beside the card's details.
private struct SuperNodeCardDetail: View {
    @ObservedObject var model: SuperNodeBoardModel
    let card: SuperNodeBoardModel.Card
    @State private var newComment = ""

    private var item: SuperNodeItem? { model.canvas?.node(card.id)?.item }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if card.kind == .note {
                    TextEditor(text: binding(\.text, default: ""))
                        .font(.system(size: 13))
                        .padding(8)
                } else {
                    SuperNodeLiveTerminal(canvas: model.canvas, id: card.id)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScrollView {
                details
                    .padding(16)
            }
            .frame(width: 300)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: card.kind.symbol)
                if let status = card.status, let color = card.statusColor {
                    Text(status)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(color))
                }
                Spacer()
                Button {
                    model.openCard = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }

            TextField(card.title, text: Binding(
                get: { item?.title ?? "" },
                set: { value in model.update(card.id) { $0.title = value.isEmpty ? nil : value } }))
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))

            if !card.subtitle.isEmpty {
                Text(card.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            field("Column") {
                Picker("", selection: Binding(
                    get: { card.column },
                    set: { model.move(card.id, to: $0, before: nil) })) {
                    ForEach(model.columns) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
            }

            field("Priority") {
                Picker("", selection: binding(\.priority, default: nil)) {
                    Text("None").tag(SuperNodePriority?.none)
                    ForEach(SuperNodePriority.allCases, id: \.self) { Text($0.name).tag(Optional($0)) }
                }
                .labelsHidden()
            }

            field("Due") {
                HStack {
                    Toggle("", isOn: Binding(
                        get: { item?.due != nil },
                        set: { on in model.update(card.id) { $0.due = on ? Calendar.current.date(byAdding: .day, value: 1, to: Date()) : nil } }))
                        .labelsHidden()
                    if item?.due != nil {
                        DatePicker("", selection: Binding(
                            get: { item?.due ?? Date() },
                            set: { date in model.update(card.id) { $0.due = date } }), displayedComponents: .date)
                            .labelsHidden()
                    }
                }
            }

            field("Description") {
                TextEditor(text: binding(\.details, default: ""))
                    .font(.system(size: 12))
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            }

            field("Comments") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item?.comments ?? []) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comment.text)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                            Text(comment.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .contextMenu {
                            Button("Delete Comment") {
                                model.update(card.id) { $0.comments?.removeAll { $0.id == comment.id } }
                            }
                        }
                    }
                    TextField("Add a comment", text: $newComment)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addComment)
                }
            }

            HStack {
                Button("Show on Canvas") { model.showOnCanvas(card.id) }
                Spacer()
                Button("Done") { model.openCard = nil }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .font(.system(size: 12))
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SuperNodeItem, Value?>, default value: Value?) -> Binding<Value?> {
        Binding(
            get: { item?[keyPath: keyPath] ?? value },
            set: { newValue in model.update(card.id) { $0[keyPath: keyPath] = newValue } })
    }

    private func binding(_ keyPath: WritableKeyPath<SuperNodeItem, String?>, default value: String) -> Binding<String> {
        Binding(
            get: { item?[keyPath: keyPath] ?? value },
            set: { newValue in model.update(card.id) { $0[keyPath: keyPath] = newValue.isEmpty ? nil : newValue } })
    }

    private func addComment() {
        let text = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.update(card.id) { $0.comments = ($0.comments ?? []) + [SuperNodeComment(text: text)] }
        newComment = ""
    }
}

/// Shows a node's live terminal in an open card, borrowing it from the canvas
/// and giving it back when the card closes.
private struct SuperNodeLiveTerminal: NSViewRepresentable {
    weak var canvas: SuperNodeCanvasView?
    let id: UUID

    final class Coordinator {
        weak var node: SuperNodeTerminalView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        if let node = canvas?.node(id) as? SuperNodeTerminalView, let body = node.lendBody() {
            body.frame = container.bounds
            body.autoresizingMask = [.width, .height]
            container.addSubview(body)
            context.coordinator.node = node
            DispatchQueue.main.async { container.window?.makeFirstResponder(node.surface) }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.node?.returnBody()
    }
}
