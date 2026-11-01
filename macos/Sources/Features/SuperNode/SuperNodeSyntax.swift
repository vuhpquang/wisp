import AppKit

/// A small regex-based syntax highlighter for editor and diff nodes. It knows
/// the common shapes of code (comments, strings, numbers, keywords, types,
/// calls) rather than full grammars, which is enough to make code readable.
struct SuperNodeSyntax {
    enum Token {
        case keyword, string, comment, number, type, function, attribute, constant, heading, key, tag

        var color: NSColor {
            switch self {
            case .keyword: .systemPink
            case .string: NSColor(name: nil) { $0.isDark ? NSColor(red: 0.99, green: 0.42, blue: 0.36, alpha: 1) : NSColor(red: 0.77, green: 0.10, blue: 0.09, alpha: 1) }
            case .comment: NSColor(name: nil) { $0.isDark ? NSColor(red: 0.50, green: 0.55, blue: 0.59, alpha: 1) : NSColor(red: 0.36, green: 0.42, blue: 0.47, alpha: 1) }
            case .number: NSColor(name: nil) { $0.isDark ? NSColor(red: 0.85, green: 0.79, blue: 0.49, alpha: 1) : NSColor(red: 0.11, green: 0.0, blue: 0.81, alpha: 1) }
            case .type: NSColor(name: nil) { $0.isDark ? NSColor(red: 0.36, green: 0.85, blue: 1.0, alpha: 1) : NSColor(red: 0.04, green: 0.31, blue: 0.47, alpha: 1) }
            case .function: NSColor(name: nil) { $0.isDark ? NSColor(red: 0.40, green: 0.72, blue: 1.0, alpha: 1) : NSColor(red: 0.20, green: 0.33, blue: 0.80, alpha: 1) }
            case .attribute: .systemOrange
            case .constant: .systemPurple
            case .heading: .systemBlue
            case .key: .systemTeal
            case .tag: .systemPink
            }
        }
    }

    private let rules: [(NSRegularExpression, Token)]

    // MARK: Highlighting

    /// The tokens in a range of text. Earlier rules win, so a keyword inside a
    /// string or comment stays part of it.
    func tokens(in text: NSString, range: NSRange) -> [(NSRange, Token)] {
        var covered = IndexSet()
        var result: [(NSRange, Token)] = []
        for (regex, token) in rules {
            regex.enumerateMatches(in: text as String, range: range) { match, _, _ in
                guard let match else { return }
                // A rule with a group colors only the group, such as a key before ":".
                let found = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
                guard found.length > 0, let span = Range(found), !covered.intersects(integersIn: span) else { return }
                covered.insert(integersIn: span)
                result.append((found, token))
            }
        }
        return result
    }

    /// One line of code as an attributed string, for diff rows.
    func highlight(_ line: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: line, attributes: [.font: font, .foregroundColor: color])
        let text = line as NSString
        for (range, token) in tokens(in: text, range: NSRange(location: 0, length: text.length)) {
            result.addAttribute(.foregroundColor, value: token.color, range: range)
        }
        return result
    }

    // MARK: Languages

    /// The highlighter for a file, by its extension or name.
    static func forFile(_ path: String) -> SuperNodeSyntax? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if let language = byName[name] ?? byExtension[ext] { return cache(language) }
        return nil
    }

    private static var compiled: [String: SuperNodeSyntax] = [:]

    private static func cache(_ language: String) -> SuperNodeSyntax? {
        if let syntax = compiled[language] { return syntax }
        guard let syntax = make(language) else { return nil }
        compiled[language] = syntax
        return syntax
    }

    private static let byName: [String: String] = [
        "makefile": "make", "dockerfile": "shell", ".zshrc": "shell", ".bashrc": "shell", ".zprofile": "shell",
        "podfile": "ruby", "gemfile": "ruby", "rakefile": "ruby", "package.swift": "swift",
    ]

    private static let byExtension: [String: String] = [
        "swift": "swift",
        "js": "js", "jsx": "js", "mjs": "js", "cjs": "js", "ts": "js", "tsx": "js", "mts": "js", "cts": "js", "vue": "js", "svelte": "js",
        "py": "python", "pyi": "python",
        "go": "go", "rs": "rust", "zig": "zig",
        "c": "c", "h": "c", "m": "c", "mm": "c", "cc": "c", "cpp": "c", "cxx": "c", "hpp": "c", "hh": "c", "metal": "c", "glsl": "c",
        "java": "java", "kt": "java", "kts": "java", "scala": "java", "cs": "java", "dart": "java", "gradle": "java",
        "rb": "ruby", "lua": "lua", "php": "php",
        "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell", "nu": "shell",
        "json": "json", "jsonc": "json", "json5": "json",
        "yml": "yaml", "yaml": "yaml", "toml": "toml", "ini": "toml", "conf": "toml", "ghostty": "toml", "env": "toml",
        "md": "markdown", "markdown": "markdown", "mdx": "markdown",
        "html": "html", "htm": "html", "xml": "html", "plist": "html", "svg": "html", "xib": "html", "storyboard": "html", "sdef": "html",
        "css": "css", "scss": "css", "sass": "css", "less": "css",
        "sql": "sql", "nix": "nix", "mk": "make",
    ]

    private static func keywords(_ words: String) -> String {
        "\\b(?:" + words.split(separator: " ").joined(separator: "|") + ")\\b"
    }

    private static let tripleQuoted = "\"\"\"[\\s\\S]*?\"\"\""
    private static let doubleString = #""(?:\\.|[^"\\\n])*""#
    private static let singleString = #"'(?:\\.|[^'\\\n])*'"#
    private static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#
    private static let type = #"\b[A-Z][A-Za-z0-9_]*\b"#
    private static let function = #"\b([a-z_][A-Za-z0-9_]*)\s*\("#
    private static let blockComment = #"/\*[\s\S]*?\*/"#
    private static let slashComment = #"//[^\n]*"#
    private static let hashComment = #"#[^\n]*"#

    private static func make(_ language: String) -> SuperNodeSyntax? {
        var rules: [(String, Token, NSRegularExpression.Options)] = []
        func add(_ pattern: String, _ token: Token, _ options: NSRegularExpression.Options = []) {
            rules.append((pattern, token, options))
        }
        func code(comments: [String], strings: [String], words: String, constants: String, attribute: String? = nil) {
            for comment in comments { add(comment, .comment) }
            for string in strings { add(string, .string) }
            if let attribute { add(attribute, .attribute) }
            add(keywords(words), .keyword)
            add(keywords(constants), .constant)
            add(number, .number)
            add(type, .type)
            add(function, .function)
        }

        switch language {
        case "swift":
            code(comments: [blockComment, slashComment], strings: [tripleQuoted, doubleString],
                 words: "actor associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough fileprivate final for func guard if import in indirect init inout internal is let lazy mutating nonisolated open operator override private protocol public repeat required rethrows return some any static struct subscript super switch throw throws try typealias var weak unowned where while get set willSet didSet convenience dynamic optional consume borrowing consuming",
                 constants: "true false nil self Self",
                 attribute: #"@[A-Za-z_][A-Za-z0-9_]*|#[a-z][A-Za-z]*"#)
        case "js":
            code(comments: [blockComment, slashComment], strings: [doubleString, singleString, #"`(?:\\.|[^`\\])*`"#],
                 words: "abstract as async await break case catch class const continue debugger declare default delete do else enum export extends finally for from function get if implements import in instanceof interface keyof let namespace new of private protected public readonly return satisfies set static super switch throw try type typeof var void while with yield",
                 constants: "true false null undefined this NaN Infinity",
                 attribute: #"@[A-Za-z_][A-Za-z0-9_.]*"#)
        case "python":
            code(comments: [hashComment], strings: [#"[rbfuRBFU]*"""[\s\S]*?""""#, #"[rbfuRBFU]*'''[\s\S]*?'''"#, doubleString, singleString],
                 words: "and as assert async await break class continue def del elif else except finally for from global if import in is lambda match case nonlocal not or pass raise return try while with yield",
                 constants: "True False None self cls",
                 attribute: #"@[A-Za-z_][A-Za-z0-9_.]*"#)
        case "go":
            code(comments: [blockComment, slashComment], strings: [doubleString, #"`[^`]*`"#, singleString],
                 words: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
                 constants: "true false nil iota")
        case "rust":
            code(comments: [blockComment, slashComment], strings: [doubleString],
                 words: "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while",
                 constants: "true false self Self None Some Ok Err",
                 attribute: #"#!?\[[^\]]*\]|\b[a-z_][a-z0-9_]*!"#)
        case "zig":
            code(comments: [slashComment], strings: [doubleString, #"\\\\[^\n]*"#],
                 words: "addrspace align allowzero and anyframe anytype asm break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while",
                 constants: "true false null undefined",
                 attribute: #"@[A-Za-z_][A-Za-z0-9_]*"#)
        case "c":
            code(comments: [blockComment, slashComment], strings: [doubleString, singleString],
                 words: "auto break case char const constexpr continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while class namespace template typename public private protected virtual override new delete using try catch throw nullptr bool auto interface implementation end property synthesize protocol selector import",
                 constants: "true false NULL nil YES NO self this",
                 attribute: #"#\s*[a-z]+|@[a-z]+"#)
        case "java":
            code(comments: [blockComment, slashComment], strings: [tripleQuoted, doubleString, singleString],
                 words: "abstract as break case catch class companion const continue data default do else enum extends final finally for fun if implements import in interface internal is lateinit new object open override package private protected public return sealed static super suspend switch synchronized throw throws try val var void when while yield async await late required",
                 constants: "true false null this it",
                 attribute: #"@[A-Za-z_][A-Za-z0-9_.]*"#)
        case "ruby":
            code(comments: [hashComment], strings: [doubleString, singleString, #":[a-z_][A-Za-z0-9_]*"#],
                 words: "alias and begin break case class def defined do else elsif end ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require attr_accessor attr_reader private protected public",
                 constants: "true false nil self")
        case "lua":
            code(comments: [#"--\[\[[\s\S]*?\]\]"#, #"--[^\n]*"#], strings: [doubleString, singleString],
                 words: "and break do else elseif end for function goto if in local not or repeat return then until while",
                 constants: "true false nil self")
        case "php":
            code(comments: [blockComment, slashComment, hashComment], strings: [doubleString, singleString],
                 words: "abstract as break case catch class clone const continue declare default do echo else elseif extends final finally fn for foreach function global if implements include interface match namespace new private protected public readonly require return static switch throw trait try use var while yield",
                 constants: "true false null this",
                 attribute: #"\$[A-Za-z_][A-Za-z0-9_]*"#)
        case "shell", "make":
            add(hashComment, .comment)
            add(doubleString, .string)
            add(singleString, .string)
            add(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@#?$!*-]"#, .constant)
            add(keywords("if then else elif fi for while until do done case esac function in return export local readonly declare set unset source alias break continue exit"), .keyword)
            add(#"^\s*([A-Za-z0-9_.-]+)\s*:(?!=)"#, .function, .anchorsMatchLines)
            add(#"(?:^|\s)(--?[A-Za-z][A-Za-z0-9-]*)"#, .attribute, .anchorsMatchLines)
            add(number, .number)
        case "json":
            add(#"//[^\n]*"#, .comment)
            add(#"("(?:\\.|[^"\\])*")\s*:"#, .key)
            add(doubleString, .string)
            add(keywords("true false null"), .constant)
            add(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, .number)
        case "yaml":
            add(hashComment, .comment)
            add(#"^\s*(?:-\s+)?([^\s:#][^:#\n]*?)\s*:(?:\s|$)"#, .key, .anchorsMatchLines)
            add(doubleString, .string)
            add(singleString, .string)
            add(keywords("true false null yes no on off"), .constant)
            add(number, .number)
            add(#"^---$"#, .attribute, .anchorsMatchLines)
        case "toml":
            add(#"(?:^|\s)[#;][^\n]*"#, .comment)
            add(#"^\s*\[[^\]\n]*\]"#, .heading, .anchorsMatchLines)
            add(#"^\s*([A-Za-z0-9_.-]+)\s*="#, .key, .anchorsMatchLines)
            add(tripleQuoted, .string)
            add(doubleString, .string)
            add(singleString, .string)
            add(keywords("true false"), .constant)
            add(number, .number)
        case "markdown":
            add(#"```[\s\S]*?```"#, .string)
            add(#"`[^`\n]+`"#, .string)
            add(#"^#{1,6} [^\n]*"#, .heading, .anchorsMatchLines)
            add(#"^\s*(?:[-*+]|\d+\.)\s"#, .keyword, .anchorsMatchLines)
            add(#"\[[^\]\n]*\]\([^)\n]*\)"#, .function)
            add(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .type)
            add(#"^>[^\n]*"#, .comment, .anchorsMatchLines)
        case "html":
            add(#"<!--[\s\S]*?-->"#, .comment)
            add(doubleString, .string)
            add(singleString, .string)
            add(#"</?[A-Za-z][\w:.-]*|/?>"#, .tag)
            add(#"\b([\w:-]+)="#, .key)
            add(#"&[a-z]+;|&#\d+;"#, .constant)
        case "css":
            add(blockComment, .comment)
            add(doubleString, .string)
            add(singleString, .string)
            add(#"@[\w-]+"#, .keyword)
            add(#"#[0-9a-fA-F]{3,8}\b"#, .number)
            add(#"([\w-]+)\s*:(?!:)"#, .key)
            add(#"-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\b"#, .number)
            add(#"[.#][A-Za-z_][\w-]*"#, .type)
        case "sql":
            add(#"--[^\n]*"#, .comment)
            add(blockComment, .comment)
            add(singleString, .string)
            add(keywords("select from where and or not insert into values update set delete create table index view drop alter add column primary key foreign references join left right inner outer on group by order having limit offset as distinct union all case when then else end is null in exists between like returning with default constraint unique begin commit rollback"), .keyword, .caseInsensitive)
            add(number, .number)
            add(function, .function)
        case "nix":
            add(#"#[^\n]*"#, .comment)
            add(blockComment, .comment)
            add(#"''[\s\S]*?''"#, .string)
            add(doubleString, .string)
            add(keywords("let in with rec inherit if then else assert import"), .keyword)
            add(keywords("true false null"), .constant)
            add(#"([A-Za-z_][\w.-]*)\s*="#, .key)
            add(number, .number)
        default:
            return nil
        }

        let compiled = rules.compactMap { pattern, token, options -> (NSRegularExpression, Token)? in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            return (regex, token)
        }
        return SuperNodeSyntax(rules: compiled)
    }
}
