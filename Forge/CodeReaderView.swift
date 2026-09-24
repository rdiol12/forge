import SwiftUI
import UIKit

struct CodeTextView: View {
    let text: String
    var filename = ""
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var codeWidth = 0.0
    @State private var lines: [AttributedString] = []
    @State private var query = ""
    @State private var matches: [Int] = []
    @State private var matchIndex = 0
    @State private var wrap = false
    @State private var copied = false
    @ScaledMetric(relativeTo: .footnote) private var gutter = 44.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(CodeSyntax.language(filename: filename)).fontWeight(.semibold)
                Text("\(lines.count) lines").foregroundStyle(.secondary)
                Spacer()
                Button { UIPasteboard.general.string = text; copied = true } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }.accessibilityLabel(copied ? "Code copied" : "Copy all code")
                Toggle(isOn: $wrap) { Image(systemName: "text.word.spacing") }.toggleStyle(.button).accessibilityLabel("Wrap lines")
            }.font(.caption).padding(.horizontal).padding(.vertical, 8).background(Color(uiColor: .secondarySystemBackground))
            ScrollViewReader { proxy in
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in file", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { moveMatch(1, proxy: proxy) }
                    if !query.isEmpty {
                        Text(matches.isEmpty ? "0" : "\(matchIndex + 1)/\(matches.count)").font(.caption).monospacedDigit()
                        Button { moveMatch(-1, proxy: proxy) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous match").disabled(matches.isEmpty)
                        Button { moveMatch(1, proxy: proxy) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next match").disabled(matches.isEmpty)
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search")
                    }
                }.font(.subheadline).padding(.horizontal).padding(.vertical, 10)
                Divider()
                GeometryReader { geometry in
                ScrollView(wrap ? .vertical : [.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 0) {
                                Text(String(index + 1)).foregroundStyle(.secondary).frame(width: gutter, alignment: .trailing)
                                    .padding(.trailing, 12).accessibilityHidden(true)
                                Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1)
                                Text(lines[index].characters.isEmpty ? AttributedString(" ") : lines[index])
                                    .textSelection(.enabled).padding(.horizontal, 12)
                                    .fixedSize(horizontal: !wrap, vertical: true)
                            }.font(.system(.footnote, design: .monospaced)).padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(matches.contains(index) ? Color.yellow.opacity(0.18) : Color.clear)
                            .id(index)
                        }
                    }.frame(width: wrap ? geometry.size.width : max(geometry.size.width, codeWidth + gutter + 37), alignment: .leading)
                        .padding(.vertical, 10)
                }.defaultScrollAnchor(.topLeading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: query) { _, value in
                    let plainLines = text.components(separatedBy: "\n")
                    matches = value.isEmpty ? [] : plainLines.indices.filter { plainLines[$0].localizedCaseInsensitiveContains(value) }
                    matchIndex = 0
                    if let first = matches.first { proxy.scrollTo(first, anchor: .center) }
                }
                }
            }
        }.background(Color(uiColor: .systemBackground))
        .task(id: text + filename + String(describing: scheme) + String(describing: typeSize)) {
            let source = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let tokens = await Task.detached(priority: .userInitiated) { CodeSyntax.tokens(in: source, filename: filename) }.value
            guard !Task.isCancelled else { return }
            let result = NSMutableAttributedString(string: source)
            for token in tokens { result.addAttribute(.foregroundColor, value: token.kind.color, range: token.range) }
            let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            codeWidth = source.components(separatedBy: "\n").reduce(0) { max($0, ($1 as NSString).size(withAttributes: [.font: font]).width) }.rounded(.up)
            var offset = 0
            lines = source.components(separatedBy: "\n").map { line in
                let range = NSRange(location: offset, length: (line as NSString).length)
                offset += range.length + 1
                return AttributedString(result.attributedSubstring(from: range))
            }
        }
    }

    private func moveMatch(_ direction: Int, proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + direction + matches.count) % matches.count
        proxy.scrollTo(matches[matchIndex], anchor: .center)
    }
}

private extension CodeSyntax.Kind {
    var color: UIColor {
        let light: UInt32, dark: UInt32
        switch self {
        case .comment: (light, dark) = (0x57606A, 0x8B949E)
        case .string: (light, dark) = (0x0A3069, 0xA5D6FF)
        case .number: (light, dark) = (0x0550AE, 0x79C0FF)
        case .keyword: (light, dark) = (0xCF222E, 0xFF7B72)
        case .type: (light, dark) = (0x953800, 0xFFA657)
        case .function: (light, dark) = (0x8250DF, 0xD2A8FF)
        case .key: (light, dark) = (0x0550AE, 0x79C0FF)
        }
        return UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

struct MarkdownDocumentView: View {
    let text: String
    var jump: ((Int) -> Void)? = nil
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if let jump {
                Menu("Contents", systemImage: "list.bullet") {
                    ForEach(MarkdownBlock.parse(text)) { block in
                        if case .heading = block.kind { Button(block.text) { jump(block.id) } }
                    }
                }
            }
            ForEach(MarkdownBlock.parse(text)) { block in
                VStack(alignment: .leading, spacing: 8) {
                switch block.kind {
                case .heading(let level):
                    Text(inline(block.text)).font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .headline).textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader).padding(.top, 6)
                    if level <= 2 { Divider() }
                case .paragraph: Text(inline(block.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                case .quote:
                    HStack(alignment: .top) { RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.35)).frame(width: 3); Text(inline(block.text)).foregroundStyle(.secondary).textSelection(.enabled) }
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet:
                    HStack(alignment: .top, spacing: 10) { Text("•").foregroundStyle(.secondary); Text(inline(block.text)).textSelection(.enabled) }
                case .code(let language):
                    CodeTextView(text: block.text, filename: "snippet.\(language)")
                        .frame(height: min(320, max(130, CGFloat(block.text.components(separatedBy: "\n").count) * 20 + 100)))
                        .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                case .rule: Divider()
                }
                }.id(block.id)
            }
        }.font(.body).lineSpacing(4)
    }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct MarkdownReader: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { MarkdownDocumentView(text: text, jump: { id in withAnimation { proxy.scrollTo(id, anchor: .top) } }).padding() }
        }
    }
}
