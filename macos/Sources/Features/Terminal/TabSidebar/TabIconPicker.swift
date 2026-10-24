import SwiftUI

/// Workspace icons are either an emoji or an SF Symbol stored as `sf:<name>`.
enum TabIconValue {
    static let symbolPrefix = "sf:"

    static func symbolName(_ icon: String) -> String? {
        icon.hasPrefix(symbolPrefix) ? String(icon.dropFirst(symbolPrefix.count)) : nil
    }
}

/// Renders a workspace icon.
struct TabIcon: View {
    let icon: String

    var body: some View {
        if let symbol = TabIconValue.symbolName(icon) {
            Image(systemName: symbol)
        } else {
            Text(icon)
        }
    }
}

/// A menu item label for a workspace: its icon followed by its name.
struct TabIconLabel: View {
    let icon: String
    let title: String

    var body: some View {
        if let symbol = TabIconValue.symbolName(icon) {
            Label(title, systemImage: symbol)
        } else {
            Text(icon.isEmpty ? title : "\(icon) \(title)")
        }
    }
}

/// Picker with categories of emoji and SF Symbols. Symbols can be searched by name.
struct TabIconPicker: View {
    @Binding var selection: String
    let onPick: () -> Void

    @State private var category: Category = .smileys
    @State private var search = ""

    private static let columns = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Category.allCases) { cat in
                    Button {
                        category = cat
                        search = ""
                    } label: {
                        Text(cat.tabIcon)
                            .font(.system(size: 14))
                            .frame(width: 28, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(category == cat ? Color.primary.opacity(0.14) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(cat.title)
                }
            }

            TextField("Search symbols", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 2) {
                    ForEach(items, id: \.self) { item in
                        Button {
                            selection = item
                            onPick()
                        } label: {
                            TabIcon(icon: item)
                                .font(.system(size: TabIconValue.symbolName(item) == nil ? 18 : 15))
                                .frame(width: 30, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selection == item ? Color.accentColor.opacity(0.3) : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(TabIconValue.symbolName(item) ?? "")
                    }
                }
            }
            .frame(height: 230)

            Button("No Icon") {
                selection = ""
                onPick()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(10)
        .frame(width: 300)
    }

    /// Searching looks through every symbol regardless of the category.
    private var items: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return category.items }
        return Category.symbols.items.filter { $0.lowercased().contains(query) }
    }

    enum Category: String, CaseIterable, Identifiable {
        case smileys, people, nature, food, activities, travel, objects, symbols, flagsAndShapes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .smileys: "Smileys"
            case .people: "People"
            case .nature: "Nature"
            case .food: "Food"
            case .activities: "Activities"
            case .travel: "Travel"
            case .objects: "Objects"
            case .symbols: "SF Symbols"
            case .flagsAndShapes: "Shapes"
            }
        }

        var tabIcon: String {
            switch self {
            case .smileys: "😀"
            case .people: "🧑‍💻"
            case .nature: "🌿"
            case .food: "🍕"
            case .activities: "⚽️"
            case .travel: "🚀"
            case .objects: "💡"
            case .symbols: "⌘"
            case .flagsAndShapes: "🔷"
            }
        }

        var items: [String] {
            switch self {
            case .smileys: Self.split("""
                😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 🫠 😉 😊 😇 🥰 😍 🤩 😘 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🫢 🤫 🤔 🫡 \
                🤐 🤨 😐 😑 😶 🫥 😏 😒 🙄 😬 😮‍💨 🤥 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🥵 🥶 🥴 😵 😵‍💫 🤯 🤠 🥳 \
                🥸 😎 🤓 🧐 😕 🫤 😟 🙁 😮 😯 😲 😳 🥺 🥹 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 \
                😡 😠 🤬 😈 👿 💀 ☠️ 💩 🤡 👹 👺 👻 👽 👾 🤖 😺 😸 😹 😻 😼 😽 🙀 😿 😾 🙈 🙉 🙊
                """)
            case .people: Self.split("""
                👋 🤚 🖐️ ✋ 🖖 👌 🤌 🤏 ✌️ 🤞 🫰 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 🫶 👐 🤲 \
                🙏 ✍️ 💪 🦾 🧠 🫀 👀 👁️ 👅 👄 🧑‍💻 👨‍💻 👩‍💻 🧑‍🔬 🧑‍🎨 🧑‍🚀 🧑‍🏫 🧑‍🍳 🧑‍🔧 🧑‍🏭 🧑‍💼 🕵️ 🥷 🧙 🧚 🧛 🧜 🧝 🧞 🧟 \
                🦸 🦹 👶 🧒 🧑 🧓 👮 👷 💂 🤴 👸 🎅 🤶 🧑‍🎄 🙋 🙆 🙅 🤷 🤦 💁 🙇 🧘 🏃 🚶 💃 🕺 👯 🧗 🏄
                """)
            case .nature: Self.split("""
                🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐻‍❄️ 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🐤 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🪲 \
                🐛 🦋 🐌 🐞 🐜 🪰 🦟 🦗 🕷️ 🦂 🐢 🐍 🦎 🦖 🦕 🐙 🦑 🦐 🦞 🦀 🐡 🐠 🐟 🐬 🐳 🐋 🦈 🐊 🐅 🐆 \
                🦓 🦍 🦧 🐘 🦛 🦏 🐪 🦒 🦘 🦬 🐃 🐂 🐄 🐎 🐖 🐏 🐑 🦙 🐐 🦌 🐕 🐩 🐈 🐓 🦃 🦚 🦜 🦢 🦩 🕊️ \
                🐇 🦝 🦨 🦡 🦫 🦦 🦥 🐁 🐿️ 🦔 🌵 🎄 🌲 🌳 🌴 🪵 🌱 🌿 ☘️ 🍀 🎍 🪴 🎋 🍃 🍂 🍁 🍄 🐚 🪨 🌾 \
                💐 🌷 🌹 🥀 🌺 🌸 🌼 🌻 🌞 🌝 🌛 🌜 🌚 🌕 🌙 🌎 🌍 🌏 🪐 💫 ⭐️ 🌟 ✨ ⚡️ ☄️ 💥 🔥 🌪️ 🌈 ☀️ \
                🌤️ ⛅️ 🌥️ ☁️ 🌦️ 🌧️ ⛈️ 🌩️ 🌨️ ❄️ ☃️ ⛄️ 🌬️ 💨 💧 💦 🌊
                """)
            case .food: Self.split("""
                🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌶️ 🫑 🌽 🥕 🧄 🧅 🥔 \
                🍠 🥐 🥯 🍞 🥖 🥨 🧀 🥚 🍳 🧈 🥞 🧇 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🫓 🥪 🥙 🧆 🌮 🌯 🫔 🥗 🥘 🫕 \
                🍝 🍜 🍲 🍛 🍣 🍱 🥟 🦪 🍤 🍙 🍚 🍘 🍥 🥠 🥮 🍢 🍡 🍧 🍨 🍦 🥧 🧁 🍰 🎂 🍮 🍭 🍬 🍫 🍿 🍩 \
                🍪 🌰 🥜 🍯 🥛 🍼 ☕️ 🍵 🧃 🥤 🧋 🍶 🍺 🍻 🥂 🍷 🥃 🍸 🍹 🧉 🍾 🧊 🥄 🍴 🍽️ 🥢
                """)
            case .activities: Self.split("""
                ⚽️ 🏀 🏈 ⚾️ 🥎 🎾 🏐 🏉 🥏 🎱 🪀 🏓 🏸 🏒 🏑 🥍 🏏 🪃 🥅 ⛳️ 🪁 🏹 🎣 🤿 🥊 🥋 🎽 🛹 🛼 🛷 \
                ⛸️ 🥌 🎿 ⛷️ 🏂 🪂 🏋️ 🤸 ⛹️ 🤺 🤾 🏌️ 🏇 🧘 🏆 🥇 🥈 🥉 🏅 🎖️ 🏵️ 🎗️ 🎫 🎟️ 🎪 🤹 🎭 🩰 🎨 🎬 \
                🎤 🎧 🎼 🎹 🥁 🪘 🎷 🎺 🪗 🎸 🪕 🎻 🎲 ♟️ 🎯 🎳 🎮 🎰 🧩 🪄 🎉 🎊 🎈 🎁 🎀 🪅 🪩
                """)
            case .travel: Self.split("""
                🚗 🚕 🚙 🚌 🚎 🏎️ 🚓 🚑 🚒 🚐 🛻 🚚 🚛 🚜 🏍️ 🛵 🚲 🛴 🚨 🚔 🚍 🚘 🚖 🚡 🚠 🚟 🚃 🚋 🚞 🚝 \
                🚄 🚅 🚈 🚂 🚆 🚇 🚊 🚉 ✈️ 🛫 🛬 🛩️ 💺 🛰️ 🚀 🛸 🚁 🛶 ⛵️ 🚤 🛥️ 🛳️ ⛴️ 🚢 ⚓️ 🪝 ⛽️ 🚧 🚦 🚥 \
                🗺️ 🗿 🗽 🗼 🏰 🏯 🏟️ 🎡 🎢 🎠 ⛲️ ⛱️ 🏖️ 🏝️ 🏜️ 🌋 ⛰️ 🏔️ 🗻 🏕️ ⛺️ 🛖 🏠 🏡 🏘️ 🏚️ 🏗️ 🏭 🏢 🏬 \
                🏣 🏤 🏥 🏦 🏨 🏪 🏫 🏩 💒 🏛️ ⛪️ 🕌 🕍 🛕 🕋 ⛩️ 🌅 🌄 🌠 🎇 🎆 🌇 🌆 🏙️ 🌃 🌌 🌉 🌁
                """)
            case .objects: Self.split("""
                ⌚️ 📱 📲 💻 ⌨️ 🖥️ 🖨️ 🖱️ 🖲️ 🕹️ 🗜️ 💽 💾 💿 📀 📼 📷 📸 📹 🎥 📽️ 🎞️ 📞 ☎️ 📟 📠 📺 📻 🎙️ 🎚️ \
                🎛️ 🧭 ⏱️ ⏲️ ⏰ 🕰️ ⌛️ ⏳ 📡 🔋 🪫 🔌 💡 🔦 🕯️ 🪔 🧯 🛢️ 💸 💵 💴 💶 💷 🪙 💰 💳 💎 ⚖️ 🪜 🧰 \
                🪛 🔧 🔨 ⚒️ 🛠️ ⛏️ 🪚 🔩 ⚙️ 🪤 🧱 ⛓️ 🧲 🔫 💣 🧨 🪓 🔪 🗡️ ⚔️ 🛡️ 🚬 ⚰️ 🪦 ⚱️ 🏺 🔮 📿 🧿 🪬 \
                💈 ⚗️ 🔭 🔬 🕳️ 🩹 🩺 💊 💉 🩸 🧬 🦠 🧫 🧪 🌡️ 🧹 🪠 🧺 🧻 🚽 🚰 🚿 🛁 🛀 🧼 🪥 🪒 🧽 🪣 🧴 \
                🛎️ 🔑 🗝️ 🚪 🪑 🛋️ 🛏️ 🛌 🧸 🪆 🖼️ 🪞 🪟 🛍️ 🛒 🎁 🎈 🎏 🎀 🪄 🪅 🎊 🎉 🎎 🏮 🎐 🧧 ✉️ 📩 📨 \
                📧 💌 📥 📤 📦 🏷️ 🪧 📪 📫 📬 📭 📮 📯 📜 📃 📄 📑 🧾 📊 📈 📉 🗒️ 🗓️ 📆 📅 🗑️ 📇 🗃️ 🗳️ 🗄️ \
                📋 📁 📂 🗂️ 🗞️ 📰 📓 📔 📒 📕 📗 📘 📙 📚 📖 🔖 🧷 🔗 📎 🖇️ 📐 📏 🧮 📌 📍 ✂️ 🖊️ 🖋️ ✒️ 🖌️ \
                🖍️ 📝 ✏️ 🔍 🔎 🔏 🔐 🔒 🔓
                """)
            case .symbols: [
                "terminal", "terminal.fill", "apple.terminal", "chevron.left.forwardslash.chevron.right",
                "curlybraces", "curlybraces.square", "function", "number", "at", "command", "option",
                "keyboard", "cpu", "memorychip", "server.rack", "externaldrive", "internaldrive",
                "network", "globe", "wifi", "antenna.radiowaves.left.and.right", "cloud", "cloud.fill",
                "icloud", "bolt", "bolt.fill", "flame", "flame.fill", "sparkles", "star", "star.fill",
                "heart", "heart.fill", "bookmark", "bookmark.fill", "flag", "flag.fill", "tag", "tag.fill",
                "bell", "bell.fill", "house", "house.fill", "building.2", "briefcase", "briefcase.fill",
                "folder", "folder.fill", "doc", "doc.text", "doc.fill", "tray", "tray.full", "archivebox",
                "shippingbox", "cube", "cube.fill", "square.stack.3d.up", "puzzlepiece", "puzzlepiece.fill",
                "hammer", "hammer.fill", "wrench", "wrench.and.screwdriver", "screwdriver", "gearshape",
                "gearshape.fill", "gearshape.2", "slider.horizontal.3", "paintbrush", "paintpalette",
                "pencil", "scissors", "ladybug", "ladybug.fill", "ant", "ant.fill", "leaf", "leaf.fill",
                "tree", "camera", "photo", "film", "music.note", "headphones", "mic", "video",
                "message", "bubble.left.and.bubble.right", "envelope", "paperplane", "paperplane.fill",
                "phone", "person", "person.fill", "person.2", "person.3", "brain", "brain.head.profile",
                "eye", "lock", "lock.fill", "key", "key.fill", "shield", "shield.fill", "checkmark.seal",
                "exclamationmark.triangle", "questionmark.circle", "info.circle", "lightbulb",
                "lightbulb.fill", "graduationcap", "book", "book.fill", "books.vertical", "newspaper",
                "chart.bar", "chart.bar.fill", "chart.pie", "chart.line.uptrend.xyaxis", "dollarsign.circle",
                "creditcard", "cart", "bag", "gift", "gamecontroller", "gamecontroller.fill", "trophy",
                "flag.checkered", "car", "airplane", "bicycle", "tram", "map", "location", "mappin",
                "safari", "compass.drawing", "sun.max", "moon", "moon.fill", "moon.stars", "cloud.rain",
                "snowflake", "drop", "wind", "tornado", "atom", "testtube.2", "flask", "cross.case",
                "pills", "stethoscope", "pawprint", "hare", "tortoise", "fish", "bird", "cat", "dog",
                "teddybear", "figure.run", "figure.walk", "dumbbell", "sportscourt", "soccerball",
                "basketball", "tennis.racket", "cup.and.saucer", "fork.knife", "wineglass", "birthday.cake",
                "app", "app.badge", "square.grid.2x2", "circle.grid.3x3", "rectangle.split.3x1",
                "sidebar.left", "macwindow", "display", "laptopcomputer", "iphone", "ipad", "applewatch",
                "airpodspro", "tv", "hifispeaker", "printer", "scanner", "flashlight.on.fill",
                "infinity", "arrow.triangle.branch", "arrow.triangle.merge", "arrow.triangle.pull",
                "arrow.clockwise", "arrow.uturn.backward", "link", "paperclip", "pin", "pin.fill",
                "circle", "circle.fill", "square", "square.fill", "triangle", "triangle.fill",
                "diamond", "diamond.fill", "hexagon", "hexagon.fill", "seal", "seal.fill",
                "1.circle", "2.circle", "3.circle", "4.circle", "5.circle", "a.circle", "b.circle",
            ].map { TabIconValue.symbolPrefix + $0 }
            case .flagsAndShapes: Self.split("""
                🔴 🟠 🟡 🟢 🔵 🟣 🟤 ⚫️ ⚪️ 🟥 🟧 🟨 🟩 🟦 🟪 🟫 ⬛️ ⬜️ 🔶 🔷 🔸 🔹 🔺 🔻 💠 🔘 🔳 🔲 ❤️ 🧡 \
                💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 ☮️ ✝️ ☪️ 🕉️ ☸️ ✡️ ☯️ ♈️ ♉️ ♊️ ♋️ ♌️ ♍️ ♎️ \
                ♏️ ♐️ ♑️ ♒️ ♓️ ⛎ 🆔 ⚛️ ☢️ ☣️ 📴 📳 ✴️ 🆚 💮 🉐 ㊙️ ㊗️ 🅰️ 🅱️ 🆎 🆑 🅾️ 🆘 ❌ ⭕️ 🛑 ⛔️ 📛 🚫 \
                💯 💢 ♨️ 🚷 🚯 🚳 🚱 🔞 📵 🚭 ❗️ ❕ ❓ ❔ ‼️ ⁉️ 🔅 🔆 〽️ ⚠️ 🚸 🔱 ⚜️ 🔰 ♻️ ✅ 🈯️ 💹 ❇️ ✳️ \
                ❎ 🌐 💤 🏧 🚾 ♿️ 🅿️ 🛗 🚹 🚺 🚼 ⚧️ 🚻 🚮 🎦 📶 🈁 🔣 ℹ️ 🔤 🔡 🔠 🆖 🆗 🆙 🆒 🆕 🆓 0️⃣ 1️⃣ \
                2️⃣ 3️⃣ 4️⃣ 5️⃣ 6️⃣ 7️⃣ 8️⃣ 9️⃣ 🔟 🔢 #️⃣ *️⃣ ▶️ ⏸️ ⏯️ ⏹️ ⏺️ ⏭️ ⏮️ ⏩ ⏪ 🔀 🔁 🔂 ◀️ 🔼 🔽 ➡️ ⬅️ ⬆️ \
                ⬇️ ↗️ ↘️ ↙️ ↖️ ↕️ ↔️ ↪️ ↩️ ⤴️ ⤵️ 🔄 🎵 🎶 ➕ ➖ ➗ ✖️ 🟰 ♾️ 💲 💱 ™️ ©️ ®️ 〰️ ➰ ➿ 🔚 🔙 \
                🔛 🔝 🔜 ✔️ ☑️ 🏁 🚩 🎌 🏴 🏳️ 🏳️‍🌈 🏴‍☠️ 🇻🇳 🇺🇸 🇬🇧 🇯🇵 🇰🇷 🇨🇳 🇫🇷 🇩🇪 🇸🇬 🇹🇭 🇦🇺 🇨🇦
                """)
            }
        }

        private static func split(_ s: String) -> [String] {
            s.split(whereSeparator: \.isWhitespace).map(String.init)
        }
    }
}
