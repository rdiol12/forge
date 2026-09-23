import Foundation

struct MarkdownBlock: Identifiable, Sendable {
    enum Kind: Sendable { case paragraph, heading(Int), code(String), quote, bullet, rule }
    let id: Int
    let kind: Kind
    let text: String

    static func parse(_ text: String) -> [Self] {
        // ponytail: native headings, lists, quotes and fences; embedded HTML stays visible text.
        var blocks: [Self] = [], paragraph: [String] = [], code: [String] = []
        var fence = "", language = ""
        func append(_ kind: Kind, _ text: String) { blocks.append(Self(id: blocks.count, kind: kind, text: text)) }
        func flush() { if !paragraph.isEmpty { append(.paragraph, paragraph.joined(separator: "\n")); paragraph = [] } }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !fence.isEmpty {
                if trimmed.hasPrefix(fence), trimmed.allSatisfy({ $0 == fence.first }) { append(.code(language), code.joined(separator: "\n")); code = []; fence = "" }
                else { code.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); fence = String(trimmed.prefix { $0 == trimmed.first }); language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces); continue
            }
            let level = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(level), trimmed.dropFirst(level).hasPrefix(" ") { flush(); append(.heading(level), String(trimmed.dropFirst(level + 1))); continue }
            if ["---", "***", "___"].contains(trimmed) { flush(); append(.rule, ""); continue }
            if trimmed.hasPrefix("> ") { flush(); append(.quote, String(trimmed.dropFirst(2))); continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { flush(); append(.bullet, String(trimmed.dropFirst(2))); continue }
            if trimmed.isEmpty { flush() } else { paragraph.append(line) }
        }
        flush()
        if !fence.isEmpty { append(.code(language), code.joined(separator: "\n")) }
        return blocks
    }
}

enum CodeSyntax {
    enum Kind: Sendable { case comment, string, number, keyword, type, function, key }
    struct Token: Sendable { let range: NSRange; let kind: Kind }

    static func language(filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "swift": "Swift"
        case "js", "jsx", "mjs", "cjs": "JavaScript"
        case "ts", "tsx": "TypeScript"
        case "py": "Python"
        case "json": "JSON"
        case "yaml", "yml": "YAML"
        case "sh", "bash", "zsh": "Shell"
        case "c", "h", "cpp", "hpp", "m", "mm": "C / C++"
        case "java", "kt", "kts": "Java / Kotlin"
        case "rs": "Rust"
        case "go": "Go"
        case "html", "xml", "svg", "plist": "Markup"
        case "css", "scss": "CSS"
        case "md", "markdown": "Markdown"
        case "diff", "patch": "Diff"
        default: "Text"
        }
    }

    static func tokens(in text: String, filename: String) -> [Token] {
        let language = language(filename: filename)
        guard language != "Text", language != "Diff", language != "Markdown" else { return [] }
        let hashComments = ["Python", "Shell", "YAML"].contains(language)
        let comments = language == "Markup" ? #"<!--[\s\S]*?(?:-->|$)"# : language == "JSON" ? #"(?!)"# : hashComments ? #"[#][^\r\n]*"# : #"//[^\r\n]*|/\*[\s\S]*?(?:\*/|$)"#
        let strings = #"\"\"\"[\s\S]*?(?:\"\"\"|$)|'''[\s\S]*?(?:'''|$)|\"(?:\\[\s\S]|[^\"\\])*(?:\"|$)|'(?:\\[\s\S]|[^'\\])*(?:'|$)|`(?:\\[\s\S]|[^`\\])*(?:`|$)"#
        let keywords = "actor|as|async|await|break|case|catch|class|const|continue|def|default|defer|do|else|enum|export|extension|false|final|finally|for|from|func|function|guard|if|import|in|init|interface|internal|is|let|mut|new|nil|None|null|open|override|package|private|protocol|public|raise|repeat|return|self|static|struct|super|switch|throw|throws|true|try|type|typeof|var|void|when|where|while|with|yield"
        // ponytail: lexical colors, not a compiler. Nested comments/interpolation aren't parsed; text stays intact.
        let patterns = [comments, strings, #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, "\\b(?:\(keywords))\\b", #"\b[A-Z][\w]*\b"#, #"\b[a-zA-Z_][\w]*(?=\s*\()"#, #"[\w.-]+(?=\s*:)"#]
        guard let regex = try? NSRegularExpression(pattern: patterns.map { "(\($0))" }.joined(separator: "|")) else { return [] }
        let kinds: [Kind] = [.comment, .string, .number, .keyword, .type, .function, .key]
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let index = (1...patterns.count).first(where: { match.range(at: $0).location != NSNotFound }) else { return nil }
            return Token(range: match.range, kind: kinds[index - 1])
        }
    }
}
