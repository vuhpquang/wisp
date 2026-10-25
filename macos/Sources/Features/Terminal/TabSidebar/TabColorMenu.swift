import AppKit
import SwiftUI

extension TerminalTabColor {
    /// Tab colors in rainbow order, for menus and pickers.
    static let ordered: [TerminalTabColor] = [
        .red, .orange, .yellow, .lime, .green, .teal, .cyan,
        .blue, .indigo, .purple, .pink, .brown, .graphite,
    ]

    /// A small dot for menu items. Its rim is a shade darker so light colors such as
    /// yellow stay visible on a light menu; None is an empty ring with a slash.
    var menuSwatch: NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            circle.lineWidth = 1
            if let color = self.displayColor {
                color.setFill()
                circle.fill()
                (color.blended(withFraction: 0.3, of: .black) ?? color).setStroke()
                circle.stroke()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                circle.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 3.5, y: rect.minY + 3.5))
                slash.line(to: NSPoint(x: rect.maxX - 3.5, y: rect.maxY - 3.5))
                slash.lineWidth = 1.2
                slash.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// "Tab Color" in a tab's menu: None, then each color with its swatch, checked on the
/// tab's current color.
///
/// SwiftUI drops the icon of a Button, Toggle or Menu label when it turns them into
/// menu items. An inline Picker keeps its items' icons, and an image inside a Text
/// survives in a label, so those carry the swatches.
struct TabColorMenu: View {
    let tab: TabSidebarModel.Tab
    let model: TabSidebarModel

    var body: some View {
        Menu {
            Picker(selection: Binding(
                get: { tab.color },
                set: { model.setColor($0, for: tab.id) }
            )) {
                item(.none)
                Divider()
                ForEach(TerminalTabColor.ordered, id: \.self) { item($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if tab.color == .none {
                Text("Tab Color")
            } else {
                Text(Image(nsImage: tab.color.menuSwatch)) + Text("  Tab Color")
            }
        }
    }

    private func item(_ color: TerminalTabColor) -> some View {
        Label {
            Text(color.localizedName)
        } icon: {
            Image(nsImage: color.menuSwatch)
        }
        .tag(color)
    }
}
