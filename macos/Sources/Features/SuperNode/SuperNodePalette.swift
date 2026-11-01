import AppKit
import SwiftUI

/// ⌘K: jump to any node, run a canvas command, or switch project by typing.
struct SuperNodePaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
}

final class SuperNodePaletteModel: ObservableObject {
    @Published var query = "" {
        didSet { selection = 0 }
    }
    @Published var selection = 0

    let items: [SuperNodePaletteItem]

    init(items: [SuperNodePaletteItem]) {
        self.items = items
    }

    /// Items with every typed word in their title or subtitle; titles that
    /// start with the query come first.
    var matches: [SuperNodePaletteItem] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return items }
        let found = items.filter { item in
            let text = (item.title + " " + item.subtitle).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let query = self.query.lowercased()
        return found.filter { $0.title.lowercased().hasPrefix(query) }
            + found.filter { !$0.title.lowercased().hasPrefix(query) }
    }

    func move(_ offset: Int) {
        let count = matches.count
        guard count > 0 else { return }
        selection = (selection + offset + count) % count
    }
}

struct SuperNodePaletteView: View {
    @ObservedObject var model: SuperNodePaletteModel
    let onRun: (SuperNodePaletteItem) -> Void
    let onClose: () -> Void

    var body: some View {
        let matches = model.matches
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                SuperNodePaletteField(
                    text: $model.query,
                    onMove: { model.move($0) },
                    onSubmit: {
                        guard matches.indices.contains(model.selection) else { return }
                        onRun(matches[model.selection])
                    },
                    onCancel: onClose)
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if matches.isEmpty {
                            Text("No matches")
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == model.selection)
                                .id(item.id)
                                .onTapGesture { onRun(item) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { selection in
                    if matches.indices.contains(selection) { proxy.scrollTo(matches[selection].id) }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
    }

    private func row(_ item: SuperNodePaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 18)
                .foregroundStyle(selected ? Color.white : .secondary)
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .foregroundStyle(selected ? Color.white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// The search field, which also moves the selection with the arrow keys and
/// closes the palette with Escape.
private struct SuperNodePaletteField: NSViewRepresentable {
    @Binding var text: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SuperNodePaletteField

        init(_ parent: SuperNodePaletteField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Go to a node, run a command, or switch project…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
}
