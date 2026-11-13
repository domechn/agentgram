import Foundation

/// A Telegram text entity, reduced to what we render. Offsets are UTF-16 code units.
public struct MDEntity: Equatable {
    public enum Kind: Equatable {
        case bold, italic, strike, code
        case pre(language: String)
        case link(String)
        case quote(collapsible: Bool)
    }
    public var offset: Int
    public var length: Int
    public var kind: Kind
    public init(offset: Int, length: Int, kind: Kind) {
        self.offset = offset
        self.length = length
        self.kind = kind
    }
}

public enum MDBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, text: String)
    case quote(text: String, collapsible: Bool)
    case table(header: [String], rows: [[String]])
    case rule
}

/// Collapsible quotes have no Markdown syntax; we mark them with this line prefix.
let collapsibleQuotePrefix = ">! "

/// Turns Telegram text + entities into Markdown source. Plain text is passed through as is, so
/// Markdown a bot sent unparsed is still rendered.
public func markdown(from text: String, entities: [MDEntity]) -> String {
    if entities.isEmpty { return text }
    let u = Array(text.utf16)
    let newline: UInt16 = 10
    func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == newline || c == 13 }
    func clamp(_ e: MDEntity) -> Range<Int> {
        let lo = max(0, min(e.offset, u.count))
        return lo..<max(lo, min(e.offset + e.length, u.count))
    }

    struct Span { var range: Range<Int>; var open: String; var close: String }
    var spans: [Span] = []
    var linePrefix: [Int: String] = [:] // line start -> quote prefix
    let pres = entities.filter { if case .pre = $0.kind { return true } else { return false } }.map(clamp)

    for e in entities {
        let r = clamp(e)
        if r.isEmpty { continue }
        switch e.kind {
        case .pre(let language):
            let body = String(decoding: u[r], as: UTF16.self)
            let fence = body.contains("```") ? "````" : "```"
            let atLineStart = r.lowerBound == 0 || u[r.lowerBound - 1] == newline
            let atLineEnd = r.upperBound == u.count || u[r.upperBound] == newline
            let bodyEndsLine = u[r.upperBound - 1] == newline
            spans.append(Span(range: r,
                              open: (atLineStart ? "" : "\n") + fence + language + "\n",
                              close: (bodyEndsLine ? "" : "\n") + fence + (atLineEnd ? "" : "\n")))
        case .quote(let collapsible):
            var i = r.lowerBound
            while i > 0 && u[i - 1] != newline { i -= 1 }
            while i < r.upperBound {
                linePrefix[i] = collapsible ? collapsibleQuotePrefix : "> "
                while i < u.count && u[i] != newline { i += 1 }
                i += 1
            }
        case .bold, .italic, .strike, .code, .link:
            if pres.contains(where: { $0.overlaps(r) }) { continue }
            let (open, close): (String, String)
            switch e.kind {
            case .bold: (open, close) = ("**", "**")
            case .italic: (open, close) = ("_", "_")
            case .strike: (open, close) = ("~~", "~~")
            case .code: (open, close) = ("`", "`")
            case .link(let url): (open, close) = ("[", "](\(url))")
            default: continue
            }
            // Inline markers must hug non-space text and cannot span lines: split per line and trim.
            var lineStart = r.lowerBound
            while lineStart < r.upperBound {
                var lineEnd = lineStart
                while lineEnd < r.upperBound && u[lineEnd] != newline { lineEnd += 1 }
                var a = lineStart, b = lineEnd
                while a < b && isSpace(u[a]) { a += 1 }
                while b > a && isSpace(u[b - 1]) { b -= 1 }
                if a < b { spans.append(Span(range: a..<b, open: open, close: close)) }
                lineStart = lineEnd + 1
            }
        }
    }

    var out: [UInt16] = []
    out.reserveCapacity(u.count + spans.count * 6)
    for i in 0...u.count {
        // Close the most recently opened span first, open the longest span first.
        for s in spans.enumerated().filter({ $0.element.range.upperBound == i })
            .sorted(by: { ($0.element.range.lowerBound, $0.offset) > ($1.element.range.lowerBound, $1.offset) }) {
            out.append(contentsOf: s.element.close.utf16)
        }
        if let p = linePrefix[i] { out.append(contentsOf: p.utf16) }
        for s in spans.enumerated().filter({ $0.element.range.lowerBound == i })
            .sorted(by: { ($0.element.range.upperBound, -$0.offset) > ($1.element.range.upperBound, -$1.offset) }) {
            out.append(contentsOf: s.element.open.utf16)
        }
        if i < u.count { out.append(u[i]) }
    }
    return String(decoding: out, as: UTF16.self)
}

/// Splits Markdown into renderable blocks. Tolerates half-streamed input: an unclosed code fence
/// runs to the end of the text.
public func parseBlocks(_ source: String) -> [MDBlock] {
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var blocks: [MDBlock] = []
    var paragraph: [String] = []
    func flush() {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
        paragraph = []
    }
    func fenceLength(_ line: Substring) -> Int { line.prefix(while: { $0 == "`" }).count }
    func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    func isTableSeparator(_ line: String) -> Bool {
        let c = cells(line)
        return line.contains("-") && !c.isEmpty && c.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.drop(while: { $0 == " " })
        let fence = fenceLength(trimmed)
        if fence >= 3 {
            flush()
            let language = trimmed.dropFirst(fence).trimmingCharacters(in: .whitespaces)
            var body: [String] = []
            i += 1
            while i < lines.count {
                let t = lines[i].drop(while: { $0 == " " })
                if fenceLength(t) >= fence && t.allSatisfy({ $0 == "`" }) { break }
                body.append(lines[i])
                i += 1
            }
            i += 1 // closing fence (or past the end while streaming)
            blocks.append(.code(language: language, text: body.joined(separator: "\n")))
            continue
        }
        if trimmed.isEmpty { flush(); i += 1; continue }
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
            flush()
            blocks.append(.heading(level: hashes, text: trimmed.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)))
            i += 1
            continue
        }
        if trimmed.count >= 3, let c = trimmed.first, "-*_".contains(c), trimmed.allSatisfy({ $0 == c }) {
            flush(); blocks.append(.rule); i += 1; continue
        }
        if trimmed.hasPrefix(">") {
            flush()
            let collapsible = trimmed.hasPrefix(">!")
            var body: [String] = []
            while i < lines.count {
                let t = lines[i].drop(while: { $0 == " " })
                guard t.hasPrefix(">") else { break }
                var rest = t.dropFirst(t.hasPrefix(">!") ? 2 : 1)
                if rest.first == " " { rest = rest.dropFirst() }
                body.append(String(rest))
                i += 1
            }
            blocks.append(.quote(text: body.joined(separator: "\n"), collapsible: collapsible))
            continue
        }
        if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
            flush()
            let header = cells(line)
            var rows: [[String]] = []
            i += 2
            while i < lines.count, lines[i].contains("|") {
                rows.append(cells(lines[i]))
                i += 1
            }
            blocks.append(.table(header: header, rows: rows))
            continue
        }
        // Lists stay inside paragraphs; only the bullet is prettified.
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let indent = line.prefix(while: { $0 == " " })
            paragraph.append(indent + "• " + trimmed.dropFirst(2))
        } else {
            paragraph.append(line)
        }
        i += 1
    }
    flush()
    return blocks
}
