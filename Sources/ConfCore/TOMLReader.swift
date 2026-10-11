import Foundation

/// TOML 1.0 reader that keeps the position (in UTF-8 bytes) of every value.
///
/// Works directly on the bytes: each parsing function consumes a "token"
/// (key, string, number, date, punctuation) and building the structure follows the
/// TOML 1.0 redefinition rules.
public enum TOMLReader {
    /// Parses a whole TOML file.
    public static func parse(_ bytes: [UInt8]) throws(ParseError) -> ConfDocument {
        let a = TOMLParser(bytes)
        return try a.document()
    }

    public static func parse(_ text: String) throws(ParseError) -> ConfDocument {
        try parse(Array(text.utf8))
    }

    /// Parses a standalone value (the right-hand side of `key = value`), such as `[1, 2]` or `"abc"`.
    /// Accepts multiple lines when the value itself allows it (arrays, `"""` strings).
    public static func parseValue(_ text: String) throws(ParseError) -> Value {
        let prefix = "v = "
        let doc: ConfDocument
        do {
            doc = try parse(Array((prefix + text).utf8))
        } catch {
            var e = error
            if e.line == 1 { e.column = max(1, e.column - prefix.count) }
            e.offset = max(0, e.offset - prefix.utf8.count)
            throw e
        }
        guard doc.headers.isEmpty, doc.entries.count == 1, let v = doc.root["v"] else {
            throw ParseError(message: NSLocalizedString("expected a single value", comment: "Parse error"), line: 1, column: 1, offset: 0)
        }
        return v
    }
}

// MARK: - Constants

private let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09, SPACE: UInt8 = 0x20
private let QUOTE: UInt8 = 0x22, APOS: UInt8 = 0x27, BACKSLASH: UInt8 = 0x5C, HASH: UInt8 = 0x23
private let LBRACKET: UInt8 = 0x5B, RBRACKET: UInt8 = 0x5D, LBRACE: UInt8 = 0x7B, RBRACE: UInt8 = 0x7D
private let EQUALS: UInt8 = 0x3D, DOT: UInt8 = 0x2E, COMMA: UInt8 = 0x2C

@inline(__always) private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(__always) private func isHex(_ c: UInt8) -> Bool {
    isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
}
/// Control characters forbidden in comments and strings (tab is allowed).
@inline(__always) private func isForbiddenControl(_ c: UInt8) -> Bool {
    (c < 0x20 && c != TAB) || c == 0x7F
}

// MARK: - Tree under construction

private typealias NameBytes = [UInt8]

private final class TableNode {
    var order: [NameBytes] = []
    var items: [NameBytes: ItemNode] = [:]

    func convert() -> Table {
        Table(pairs: order.map { n in
            Table.Pair(key: String(decoding: n, as: UTF8.self), value: items[n]!.convert())
        })
    }
}

private enum ItemNode {
    case value(Value)
    case table(TableNode)
    case array(ArrayNode)

    func convert() -> Value {
        switch self {
        case .value(let v): return v
        case .table(let t): return .table(t.convert())
        case .array(let l): return .array(l.tables.map { .table($0.convert()) })
        }
    }
}

private final class ArrayNode {
    var tables: [TableNode] = []
}

/// "Already defined" and "frozen" marks per name path (without indices),
/// in the same scheme as tomli: a new `[[array]]` clears the marks of the previous item.
private final class Flags {
    enum Kind { case frozen, explicit }

    final class Node {
        var marks = Set<Kind>()
        var recursives = Set<Kind>()
        var children: [NameBytes: Node] = [:]
    }

    let root = Node()
    var pendingItems: [([NameBytes], Kind)] = []

    func pending(_ k: [NameBytes], _ t: Kind) { pendingItems.append((k, t)) }

    func flushPending() {
        for (k, t) in pendingItems { define(k, t, recursive: false) }
        pendingItems.removeAll()
    }

    func clearAll(_ k: [NameBytes]) {
        var node = root
        for x in k.dropLast() {
            guard let n = node.children[x] else { return }
            node = n
        }
        node.children[k.last!] = nil
    }

    func define(_ k: [NameBytes], _ t: Kind, recursive: Bool) {
        var node = root
        for x in k {
            if let n = node.children[x] { node = n } else { let n = Node(); node.children[x] = n; node = n }
        }
        if recursive { node.recursives.insert(t) } else { node.marks.insert(t) }
    }

    func has(_ k: [NameBytes], _ t: Kind) -> Bool {
        guard let last = k.last else { return false }
        var node = root
        for x in k.dropLast() {
            guard let n = node.children[x] else { return false }
            if n.recursives.contains(t) { return true }
            node = n
        }
        guard let n = node.children[last] else { return false }
        return n.marks.contains(t) || n.recursives.contains(t)
    }
}

// MARK: - Parser

private final class TOMLParser {
    let b: [UInt8]
    var p = 0
    let start: Int

    let root = TableNode()
    let flags = Flags()
    /// Names of the current header (without indices) and concrete path of the current table.
    var headerNames: [NameBytes] = []
    var currentSection: Int? = nil

    var entries: [Entry] = []
    var headers: [SectionHeader] = []
    var commentsAbove: [String] = []

    /// Start of each line, to convert an offset into line/column.
    lazy var lineStarts: [Int] = {
        var r = [0]
        for (i, c) in b.enumerated() where c == LF { r.append(i + 1) }
        return r
    }()

    init(_ bytes: [UInt8]) {
        b = bytes
        start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
    }

    // MARK: Utilities

    @inline(__always) var current: UInt8? { p < b.count ? b[p] : nil }
    @inline(__always) func peek(_ k: Int) -> UInt8? { p + k < b.count ? b[p + k] : nil }

    func lineColumn(_ off: Int) -> (Int, Int) {
        let off = min(max(off, 0), b.count)
        // binary search for the line
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if lineStarts[m] <= off { lo = m } else { hi = m - 1 }
        }
        var lineStart = lineStarts[lo]
        if lo == 0 { lineStart = max(lineStart, start) }
        var col = 1
        if lineStart < off {
            for i in lineStart..<off where b[i] & 0xC0 != 0x80 { col += 1 }
        }
        return (lo + 1, col)
    }

    func error(_ msg: String, at off: Int? = nil) -> ParseError {
        let o = off ?? p
        let (l, c) = lineColumn(o)
        return ParseError(message: msg, line: l, column: c, offset: o)
    }

    func describe(_ c: UInt8?) -> String {
        guard let c else { return NSLocalizedString("end of file", comment: "Parse error fragment: what was found") }
        switch c {
        case LF, CR: return NSLocalizedString("end of line", comment: "Parse error fragment: what was found")
        case TAB: return NSLocalizedString("tab", comment: "Parse error fragment: what was found")
        case SPACE: return NSLocalizedString("space", comment: "Parse error fragment: what was found")
        case 0x21...0x7E: return "'\(String(UnicodeScalar(c)))'"
        default: return String(format: "byte 0x%02X", c)
        }
    }

    func skipSpaces() {
        while p < b.count, b[p] == SPACE || b[p] == TAB { p += 1 }
    }

    /// Consumes a line break (LF or CRLF).
    func expectNewline() throws(ParseError) {
        if current == LF { p += 1; return }
        if current == CR {
            if peek(1) == LF { p += 2; return }
            throw error(NSLocalizedString("lone CR (\\r); use LF or CRLF as line break", comment: "Parse error"))
        }
        throw error(String(format: NSLocalizedString("expected line break, found %@", comment: "Parse error; %@ = what was found"), describe(current)))
    }

    /// Reads a comment starting at `#`. Returns the text without `#` and without surrounding spaces.
    func comment() throws(ParseError) -> String {
        p += 1
        let begin = p
        while p < b.count {
            let c = b[p]
            if c == LF { break }
            if c == CR {
                if peek(1) == LF { break }
                throw error(NSLocalizedString("lone CR (\\r) inside comment", comment: "Parse error"))
            }
            if isForbiddenControl(c) { throw error(NSLocalizedString("control character not allowed in comment", comment: "Parse error")) }
            p += 1
        }
        return String(decoding: b[begin..<p], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// After a value or header: spaces, optional comment and end of line.
    func lineEnding() throws(ParseError) -> String? {
        skipSpaces()
        var c: String? = nil
        if current == HASH { c = try comment() }
        if current == nil { return c }
        if current == LF || current == CR {
            try expectNewline()
            return c
        }
        throw error(String(format: NSLocalizedString("expected end of line after the value, found %@", comment: "Parse error; %@ = what was found"), describe(current)))
    }

    /// Spaces, line breaks and comments (inside arrays).
    func skipSpacesLinesComments() throws(ParseError) {
        while let c = current {
            if c == SPACE || c == TAB { p += 1 }
            else if c == LF || c == CR { try expectNewline() }
            else if c == HASH { _ = try comment() }
            else { break }
        }
    }

    // MARK: UTF-8 validation

    func validateUTF8() throws(ParseError) {
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c < 0x80 { i += 1; continue }
            var len = 0, minimum: UInt32 = 0, v: UInt32 = 0
            if c & 0xE0 == 0xC0 { len = 2; minimum = 0x80; v = UInt32(c & 0x1F) }
            else if c & 0xF0 == 0xE0 { len = 3; minimum = 0x800; v = UInt32(c & 0x0F) }
            else if c & 0xF8 == 0xF0 { len = 4; minimum = 0x10000; v = UInt32(c & 0x07) }
            else { throw error(NSLocalizedString("invalid UTF-8", comment: "Parse error"), at: i) }
            guard i + len <= n else { throw error(NSLocalizedString("invalid UTF-8 (incomplete sequence)", comment: "Parse error"), at: i) }
            for k in 1..<len {
                let d = b[i + k]
                guard d & 0xC0 == 0x80 else { throw error(NSLocalizedString("invalid UTF-8", comment: "Parse error"), at: i) }
                v = (v << 6) | UInt32(d & 0x3F)
            }
            if v < minimum || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) {
                throw error(NSLocalizedString("invalid UTF-8", comment: "Parse error"), at: i)
            }
            i += len
        }
    }

    // MARK: Document

    func document() throws(ParseError) -> ConfDocument {
        try validateUTF8()
        p = start
        while true {
            skipSpaces()
            guard let c = current else { break }
            switch c {
            case HASH:
                commentsAbove.append(try comment())
                if current != nil { try expectNewline() }
            case LF, CR:
                try expectNewline()
                commentsAbove.removeAll()
            case LBRACKET:
                flags.flushPending()
                try header()
            default:
                try keyValuePair()
            }
        }
        var newline = "\n"
        if let i = b.firstIndex(of: LF), i > 0, b[i - 1] == CR { newline = "\r\n" }
        return ConfDocument(bytes: b, root: root.convert(), entries: entries, headers: headers,
                             lineBreak: newline, hasBOM: start == 3)
    }

    // MARK: Keys

    struct ParsedKey {
        var parts: [NameBytes]
        var range: Range<Int>
        var text: String
    }

    func key() throws(ParseError) -> ParsedKey {
        var parts: [NameBytes] = []
        skipSpaces()
        let begin = p
        var end = p
        while true {
            skipSpaces()
            parts.append(try bareKey())
            end = p
            skipSpaces()
            if current == DOT { p += 1; continue }
            break
        }
        return ParsedKey(parts: parts, range: begin..<end, text: String(decoding: b[begin..<end], as: UTF8.self))
    }

    func bareKey() throws(ParseError) -> NameBytes {
        guard let c = current else { throw error(String(format: NSLocalizedString("expected key, found %@", comment: "Parse error; %@ = what was found"), describe(nil))) }
        if c == QUOTE {
            if peek(1) == QUOTE && peek(2) == QUOTE { throw error(NSLocalizedString("multiline string cannot be a key", comment: "Parse error")) }
            return Array(try basicString().utf8)
        }
        if c == APOS {
            if peek(1) == APOS && peek(2) == APOS { throw error(NSLocalizedString("multiline string cannot be a key", comment: "Parse error")) }
            return Array(try literalString().utf8)
        }
        let begin = p
        while let d = current, isBareKeyChar(d) { p += 1 }
        if p == begin { throw error(String(format: NSLocalizedString("expected key, found %@", comment: "Parse error; %@ = what was found"), describe(c))) }
        return Array(b[begin..<p])
    }

    func displayName(_ k: [NameBytes]) -> String {
        k.map { PathSegment.formattedKey(String(decoding: $0, as: UTF8.self)) }.joined(separator: ".")
    }

    // MARK: Structure

    /// Walks (creating implicit tables) to the path; in `[[arrays]]` it enters the last item.
    func createOrGet(_ k: [NameBytes], at base: TableNode? = nil, accessesArrays: Bool = true,
                     errorAt: Int) throws(ParseError) -> (TableNode, ValuePath) {
        var t = base ?? root
        var pathSoFar: ValuePath = []
        for (i, n) in k.enumerated() {
            pathSoFar.append(.key(String(decoding: n, as: UTF8.self)))
            switch t.items[n] {
            case nil:
                let updated = TableNode()
                t.items[n] = .table(updated)
                t.order.append(n)
                t = updated
            case .table(let x)?:
                t = x
            case .array(let l)? where accessesArrays:
                pathSoFar.append(.index(l.tables.count - 1))
                t = l.tables[l.tables.count - 1]
            default:
                throw error(String(format: NSLocalizedString("'%@' already has a value that is not a table", comment: "Parse error; %@ = key"), displayName(Array(k[...i]))), at: errorAt)
            }
        }
        return (t, pathSoFar)
    }

    func header() throws(ParseError) {
        let begin = p
        let isArray = peek(1) == LBRACKET
        p += isArray ? 2 : 1
        let k = try key()
        skipSpaces()
        if isArray {
            guard current == RBRACKET, peek(1) == RBRACKET else {
                throw error(String(format: NSLocalizedString("expected ']]' at the end of the header, found %@", comment: "Parse error; %@ = what was found"), describe(current)))
            }
            p += 2
        } else {
            guard current == RBRACKET else { throw error(String(format: NSLocalizedString("expected ']' at the end of the header, found %@", comment: "Parse error; %@ = what was found"), describe(current))) }
            p += 1
        }
        let end = p
        let name = displayName(k.parts)
        var path: ValuePath
        if isArray {
            if flags.has(k.parts, .frozen) {
                throw error(String(format: NSLocalizedString("'%@' is an array or table written inline in a value and cannot be extended", comment: "Parse error; %@ = key"), name), at: k.range.lowerBound)
            }
            flags.clearAll(k.parts)
            flags.define(k.parts, .explicit, recursive: false)
            let (parent, pathSoFar) = try createOrGet(Array(k.parts.dropLast()), errorAt: k.range.lowerBound)
            let last = k.parts.last!
            path = pathSoFar + [.key(String(decoding: last, as: UTF8.self))]
            switch parent.items[last] {
            case nil:
                let l = ArrayNode()
                l.tables.append(TableNode())
                parent.items[last] = .array(l)
                parent.order.append(last)
                path.append(.index(0))
            case .array(let l)?:
                l.tables.append(TableNode())
                path.append(.index(l.tables.count - 1))
            default:
                throw error(String(format: NSLocalizedString("'%@' was already defined and is not an array of tables", comment: "Parse error; %@ = key"), name), at: k.range.lowerBound)
            }
        } else {
            if flags.has(k.parts, .explicit) || flags.has(k.parts, .frozen) {
                throw error(String(format: NSLocalizedString("table '%@' was already defined", comment: "Parse error; %@ = table name"), name), at: k.range.lowerBound)
            }
            flags.define(k.parts, .explicit, recursive: false)
            (_, path) = try createOrGet(k.parts, errorAt: k.range.lowerBound)
        }
        headerNames = k.parts
        let trailingComment = try lineEnding()
        headers.append(SectionHeader(
            path: path,
            names: k.parts.map { String(decoding: $0, as: UTF8.self) },
            isArrayOfTables: isArray,
            range: begin..<end,
            line: lineColumn(begin).0,
            commentAbove: commentsAbove,
            trailingComment: trailingComment))
        commentsAbove.removeAll()
        currentSection = headers.count - 1
    }

    func keyValuePair() throws(ParseError) {
        let k = try key()
        skipSpaces()
        guard current == EQUALS else { throw error(String(format: NSLocalizedString("expected '=' after the key, found %@", comment: "Parse error; %@ = what was found"), describe(current))) }
        p += 1
        skipSpaces()
        let (v, pos) = try value()

        let parent = Array(k.parts.dropLast()), last = k.parts.last!
        let parentAbs = headerNames + parent
        if k.parts.count > 1 {
            for i in 1..<k.parts.count {
                let counter = headerNames + Array(k.parts[0..<i])
                if flags.has(counter, .explicit) {
                    throw error(String(format: NSLocalizedString("table '%@' was already defined and cannot be redefined with a dotted key", comment: "Parse error; %@ = table name"), displayName(counter)),
                               at: k.range.lowerBound)
                }
                flags.pending(counter, .explicit)
            }
        }
        if flags.has(parentAbs, .frozen) {
            throw error(String(format: NSLocalizedString("'%@' is an inline table and does not accept new keys", comment: "Parse error; %@ = table name"), displayName(parentAbs)),
                       at: k.range.lowerBound)
        }
        let (t, pathSoFar) = try createOrGet(parentAbs, errorAt: k.range.lowerBound)
        if t.items[last] != nil {
            throw error(String(format: NSLocalizedString("key '%@' was already defined", comment: "Parse error; %@ = key"), displayName(headerNames + k.parts)), at: k.range.lowerBound)
        }
        switch v {
        case .array, .table: flags.define(headerNames + k.parts, .frozen, recursive: true)
        default: break
        }
        t.items[last] = .value(v)
        t.order.append(last)

        let valueEnd = p
        let trailingComment = try lineEnding()
        entries.append(Entry(
            path: pathSoFar + [.key(String(decoding: last, as: UTF8.self))],
            writtenKey: k.text,
            value: v,
            position: pos,
            keyRange: k.range,
            line: lineColumn(k.range.lowerBound).0,
            lastLine: lineColumn(valueEnd).0,
            commentAbove: commentsAbove,
            trailingComment: trailingComment,
            section: currentSection))
        commentsAbove.removeAll()
    }

    // MARK: Values

    func value() throws(ParseError) -> (Value, Position) {
        guard let c = current else { throw error(String(format: NSLocalizedString("expected value, found %@", comment: "Parse error; %@ = what was found"), describe(nil))) }
        let begin = p
        let v: Value
        var items: [Position] = []
        switch c {
        case QUOTE:
            if peek(1) == QUOTE && peek(2) == QUOTE { v = .text(try multilineBasicString()) }
            else { v = .text(try basicString()) }
        case APOS:
            if peek(1) == APOS && peek(2) == APOS { v = .text(try multilineLiteralString()) }
            else { v = .text(try literalString()) }
        case 0x74 /* t */:
            try word("true"); v = .boolean(true)
        case 0x66 /* f */:
            try word("false"); v = .boolean(false)
        case LBRACKET:
            let (l, pos) = try array(); v = .array(l); items = pos
        case LBRACE:
            v = .table(try inlineTable())
        case LF, CR, HASH:
            throw error(NSLocalizedString("expected value after '='", comment: "Parse error"))
        default:
            v = try numberOrDate()
        }
        return (v, Position(range: begin..<p, items: items))
    }

    func word(_ s: String) throws(ParseError) {
        let u = Array(s.utf8)
        guard p + u.count <= b.count, Array(b[p..<(p + u.count)]) == u else {
            throw error(String(format: NSLocalizedString("invalid value (expected %@)", comment: "Parse error; %@ = true or false"), s))
        }
        p += u.count
    }

    // MARK: Strings

    func escape(_ output: inout [UInt8]) throws(ParseError) {
        let begin = p
        p += 1 // backslash
        guard let c = current else { throw error(NSLocalizedString("incomplete escape at end of file", comment: "Parse error")) }
        p += 1
        switch c {
        case 0x62: output.append(0x08)          // \b
        case 0x74: output.append(TAB)           // \t
        case 0x6E: output.append(LF)            // \n
        case 0x66: output.append(0x0C)          // \f
        case 0x72: output.append(CR)            // \r
        case QUOTE: output.append(QUOTE)
        case BACKSLASH: output.append(BACKSLASH)
        case 0x75, 0x55:                        // \uXXXX, \UXXXXXXXX
            let n = c == 0x75 ? 4 : 8
            guard p + n <= b.count else { throw error(String(format: NSLocalizedString("incomplete escape %@", comment: "Parse error; %@ = escape such as \\u"), "\\" + String(UnicodeScalar(c))), at: begin) }
            var v: UInt32 = 0
            for k in 0..<n {
                let d = b[p + k]
                guard isHex(d) else { throw error(String(format: NSLocalizedString("escape %@ with invalid hexadecimal digit", comment: "Parse error; %@ = escape such as \\u"), "\\" + String(UnicodeScalar(c))), at: begin) }
                v = v * 16 + UInt32(hexValue(d))
            }
            p += n
            guard let u = UnicodeScalar(v) else {
                throw error(String(format: NSLocalizedString("escape %@ is not a valid Unicode character", comment: "Parse error; %@ = escape such as \\u"), "\\" + String(UnicodeScalar(c))), at: begin)
            }
            output.append(contentsOf: Array(String(Character(u)).utf8))
        default:
            throw error(String(format: NSLocalizedString("invalid escape '%@'", comment: "Parse error; %@ = escape found"), "\\" + describeUnquoted(c)), at: begin)
        }
    }

    func describeUnquoted(_ c: UInt8) -> String {
        (0x21...0x7E).contains(c) ? String(UnicodeScalar(c)) : String(format: "0x%02X", c)
    }

    func hexValue(_ d: UInt8) -> UInt8 {
        if isDigit(d) { return d - 0x30 }
        if d >= 0x61 { return d - 0x61 + 10 }
        return d - 0x41 + 10
    }

    func basicString() throws(ParseError) -> String {
        let begin = p
        p += 1
        var s: [UInt8] = []
        while true {
            guard let c = current else { throw error(NSLocalizedString("string without closing quote", comment: "Parse error"), at: begin) }
            if c == QUOTE { p += 1; break }
            if c == BACKSLASH { try escape(&s); continue }
            if c == LF || c == CR { throw error(NSLocalizedString("string without closing quote before end of line", comment: "Parse error"), at: begin) }
            if isForbiddenControl(c) { throw error(NSLocalizedString("control character not allowed in string", comment: "Parse error")) }
            s.append(c); p += 1
        }
        return String(decoding: s, as: UTF8.self)
    }

    func literalString() throws(ParseError) -> String {
        let begin = p
        p += 1
        let contentStart = p
        while true {
            guard let c = current else { throw error(NSLocalizedString("string without closing apostrophe", comment: "Parse error"), at: begin) }
            if c == APOS { break }
            if c == LF || c == CR { throw error(NSLocalizedString("string without closing apostrophe before end of line", comment: "Parse error"), at: begin) }
            if isForbiddenControl(c) { throw error(NSLocalizedString("control character not allowed in string", comment: "Parse error")) }
            p += 1
        }
        let s = String(decoding: b[contentStart..<p], as: UTF8.self)
        p += 1
        return s
    }

    /// Skips the line break right after the opening `"""`/`'''`.
    func skipLeadingNewline() throws(ParseError) {
        if current == LF { p += 1 }
        else if current == CR && peek(1) == LF { p += 2 }
    }

    func multilineBasicString() throws(ParseError) -> String {
        let begin = p
        p += 3
        try skipLeadingNewline()
        var s: [UInt8] = []
        while true {
            guard let c = current else { throw error(String(format: NSLocalizedString("multiline string without closing %@", comment: "Parse error; %@ = closing delimiter"), "\"\"\""), at: begin) }
            if c == QUOTE {
                var q = 0
                while peek(q) == QUOTE { q += 1 }
                if q >= 3 {
                    if q > 5 { throw error(NSLocalizedString("too many quotes at the end of multiline string", comment: "Parse error")) }
                    s.append(contentsOf: [UInt8](repeating: QUOTE, count: q - 3))
                    p += q
                    break
                }
                s.append(contentsOf: [UInt8](repeating: QUOTE, count: q))
                p += q
                continue
            }
            if c == BACKSLASH {
                // backslash at end of line: joins with the next one, discarding spaces and line breaks
                var k = 1
                while let d = peek(k), d == SPACE || d == TAB { k += 1 }
                if peek(k) == LF || (peek(k) == CR && peek(k + 1) == LF) {
                    p += k
                    while let d = current {
                        if d == SPACE || d == TAB { p += 1 }
                        else if d == LF || d == CR { try expectNewline() }
                        else { break }
                    }
                    continue
                }
                try escape(&s)
                continue
            }
            if c == LF { s.append(LF); p += 1; continue }
            if c == CR {
                guard peek(1) == LF else { throw error(NSLocalizedString("lone CR (\\r) inside string", comment: "Parse error")) }
                s.append(LF); p += 2; continue
            }
            if isForbiddenControl(c) { throw error(NSLocalizedString("control character not allowed in string", comment: "Parse error")) }
            s.append(c); p += 1
        }
        return String(decoding: s, as: UTF8.self)
    }

    func multilineLiteralString() throws(ParseError) -> String {
        let begin = p
        p += 3
        try skipLeadingNewline()
        var s: [UInt8] = []
        while true {
            guard let c = current else { throw error(String(format: NSLocalizedString("multiline string without closing %@", comment: "Parse error; %@ = closing delimiter"), "'''"), at: begin) }
            if c == APOS {
                var q = 0
                while peek(q) == APOS { q += 1 }
                if q >= 3 {
                    if q > 5 { throw error(NSLocalizedString("too many apostrophes at the end of multiline string", comment: "Parse error")) }
                    s.append(contentsOf: [UInt8](repeating: APOS, count: q - 3))
                    p += q
                    break
                }
                s.append(contentsOf: [UInt8](repeating: APOS, count: q))
                p += q
                continue
            }
            if c == LF { s.append(LF); p += 1; continue }
            if c == CR {
                guard peek(1) == LF else { throw error(NSLocalizedString("lone CR (\\r) inside string", comment: "Parse error")) }
                s.append(LF); p += 2; continue
            }
            if isForbiddenControl(c) { throw error(NSLocalizedString("control character not allowed in string", comment: "Parse error")) }
            s.append(c); p += 1
        }
        return String(decoding: s, as: UTF8.self)
    }

    // MARK: Arrays and inline tables

    func array() throws(ParseError) -> ([Value], [Position]) {
        let begin = p
        p += 1
        var vs: [Value] = []
        var ps: [Position] = []
        while true {
            try skipSpacesLinesComments()
            if current == RBRACKET { p += 1; break }
            if current == nil { throw error(NSLocalizedString("array without closing ']'", comment: "Parse error"), at: begin) }
            let (v, pos) = try value()
            vs.append(v); ps.append(pos)
            try skipSpacesLinesComments()
            if current == COMMA { p += 1; continue }
            if current == RBRACKET { p += 1; break }
            if current == nil { throw error(NSLocalizedString("array without closing ']'", comment: "Parse error"), at: begin) }
            throw error(String(format: NSLocalizedString("expected ',' or ']' in array, found %@", comment: "Parse error; %@ = what was found"), describe(current)))
        }
        return (vs, ps)
    }

    func inlineTable() throws(ParseError) -> Table {
        let begin = p
        p += 1
        let t = TableNode()
        let marks = Flags()
        skipSpaces()
        if current == RBRACE { p += 1; return t.convert() }
        while true {
            let k = try key()
            skipSpaces()
            guard current == EQUALS else { throw error(String(format: NSLocalizedString("expected '=' after the key, found %@", comment: "Parse error; %@ = what was found"), describe(current))) }
            p += 1
            skipSpaces()
            let (v, _) = try value()
            if marks.has(k.parts, .frozen) {
                throw error(String(format: NSLocalizedString("'%@' cannot be extended", comment: "Parse error; %@ = key"), displayName(k.parts)), at: k.range.lowerBound)
            }
            let (parent, _) = try createOrGet(Array(k.parts.dropLast()), at: t, accessesArrays: false,
                                           errorAt: k.range.lowerBound)
            let last = k.parts.last!
            if parent.items[last] != nil {
                throw error(String(format: NSLocalizedString("key '%@' was already defined in this table", comment: "Parse error; %@ = key"), displayName(k.parts)), at: k.range.lowerBound)
            }
            parent.items[last] = .value(v)
            parent.order.append(last)
            switch v {
            case .array, .table: marks.define(k.parts, .frozen, recursive: true)
            default: break
            }
            skipSpaces()
            if current == COMMA {
                p += 1
                skipSpaces()
                if current == RBRACE { throw error(NSLocalizedString("trailing comma in inline table is not allowed in TOML 1.0", comment: "Parse error")) }
                continue
            }
            if current == RBRACE { p += 1; break }
            if current == nil { throw error(NSLocalizedString("inline table without closing '}'", comment: "Parse error"), at: begin) }
            throw error(String(format: NSLocalizedString("expected ',' or '}' in inline table, found %@", comment: "Parse error; %@ = what was found"), describe(current)))
        }
        return t.convert()
    }

    // MARK: Numbers and dates

    func numberOrDate() throws(ParseError) -> Value {
        let begin = p
        func isTokenChar(_ c: UInt8) -> Bool {
            isDigit(c) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x5F || c == 0x2B || c == 0x2D || c == DOT || c == 0x3A
        }
        while let c = current, isTokenChar(c) { p += 1 }
        // date followed by space and time: `1979-05-27 07:32:00`
        if p - begin == 10, current == SPACE, let h1 = peek(1), let h2 = peek(2), isDigit(h1), isDigit(h2), peek(3) == 0x3A,
           b[begin + 4] == 0x2D, b[begin + 7] == 0x2D {
            p += 1
            while let c = current, isTokenChar(c) { p += 1 }
        }
        if p == begin { throw error(String(format: NSLocalizedString("invalid value: %@", comment: "Parse error; %@ = what was found"), describe(current))) }
        let tok = Array(b[begin..<p])
        if tok.count >= 10, tok[4] == 0x2D, tok[0..<4].allSatisfy(isDigit) {
            return .dateTime(try dateTime(tok, begin))
        }
        if tok.count >= 5, tok[2] == 0x3A, isDigit(tok[0]), isDigit(tok[1]) {
            return .dateTime(try timeOnly(tok, begin))
        }
        return try number(tok, begin)
    }

    /// Removes the `_`s, checking that each one is between two valid digits.
    func withoutUnderscores(_ s: ArraySlice<UInt8>, _ isValid: (UInt8) -> Bool, _ off: Int) throws(ParseError) -> [UInt8] {
        var r: [UInt8] = []
        var previous: UInt8? = nil
        for c in s {
            if c == 0x5F {
                guard let a = previous, a != 0x5F else { throw error(NSLocalizedString("'_' must be between two digits", comment: "Parse error"), at: off) }
            } else {
                guard isValid(c) else { throw error(String(format: NSLocalizedString("invalid number: '%@'", comment: "Parse error; %@ = number text"), String(decoding: s, as: UTF8.self)), at: off) }
                r.append(c)
            }
            previous = c
        }
        if previous == 0x5F { throw error(NSLocalizedString("'_' must be between two digits", comment: "Parse error"), at: off) }
        if r.isEmpty { throw error(NSLocalizedString("number without digits", comment: "Parse error"), at: off) }
        return r
    }

    func number(_ tok: [UInt8], _ off: Int) throws(ParseError) -> Value {
        let s = String(decoding: tok, as: UTF8.self)
        switch s {
        case "inf", "+inf": return .decimal(.infinity)
        case "-inf": return .decimal(-.infinity)
        case "nan", "+nan": return .decimal(.nan)
        case "-nan": return .decimal(-.nan)
        default: break
        }
        // bases 16, 8 and 2: unsigned
        if tok.count > 2, tok[0] == 0x30, tok[1] == 0x78 || tok[1] == 0x6F || tok[1] == 0x62 {
            let base: UInt64, valid: (UInt8) -> Bool
            switch tok[1] {
            case 0x78: base = 16; valid = isHex
            case 0x6F: base = 8; valid = { $0 >= 0x30 && $0 <= 0x37 }
            default: base = 2; valid = { $0 == 0x30 || $0 == 0x31 }
            }
            let digitStr = try withoutUnderscores(tok[2...], valid, off)
            var v: UInt64 = 0
            for d in digitStr {
                let (m, o1) = v.multipliedReportingOverflow(by: base)
                let (a, o2) = m.addingReportingOverflow(UInt64(hexValue(d)))
                if o1 || o2 || a > UInt64(Int64.max) { throw error(NSLocalizedString("integer out of 64-bit range", comment: "Parse error"), at: off) }
                v = a
            }
            return .integer(Int64(v))
        }
        var i = 0
        var negative = false
        if tok.first == 0x2B || tok.first == 0x2D { negative = tok.first == 0x2D; i = 1 }
        // integer part
        var j = i
        while j < tok.count, isDigit(tok[j]) || tok[j] == 0x5F { j += 1 }
        guard j > i else { throw error(String(format: NSLocalizedString("invalid value: '%@'", comment: "Parse error; %@ = value text"), s), at: off) }
        let integer = try withoutUnderscores(tok[i..<j], isDigit, off)
        if integer.count > 1 && integer[0] == 0x30 { throw error(String(format: NSLocalizedString("leading zeros are not allowed: '%@'", comment: "Parse error; %@ = number text"), s), at: off) }
        if j == tok.count {
            // decimal integer
            var v: Int64 = 0
            for d in integer {
                let dv = Int64(d - 0x30)
                let (m, o1) = v.multipliedReportingOverflow(by: 10)
                let (a, o2) = negative ? m.subtractingReportingOverflow(dv) : m.addingReportingOverflow(dv)
                if o1 || o2 { throw error(NSLocalizedString("integer out of 64-bit range", comment: "Parse error"), at: off) }
                v = a
            }
            return .integer(v)
        }
        // decimal: fraction and/or exponent
        var text = (negative ? "-" : "") + String(decoding: integer, as: UTF8.self)
        if tok[j] == DOT {
            var k = j + 1
            while k < tok.count, isDigit(tok[k]) || tok[k] == 0x5F { k += 1 }
            guard k > j + 1 else { throw error(String(format: NSLocalizedString("decimal needs digits after the point: '%@'", comment: "Parse error; %@ = number text"), s), at: off) }
            text += "." + String(decoding: try withoutUnderscores(tok[(j + 1)..<k], isDigit, off), as: UTF8.self)
            j = k
        }
        if j < tok.count, tok[j] == 0x65 || tok[j] == 0x45 {
            var k = j + 1
            var signText = ""
            if k < tok.count, tok[k] == 0x2B || tok[k] == 0x2D { signText = tok[k] == 0x2D ? "-" : "+"; k += 1 }
            guard k < tok.count else { throw error(String(format: NSLocalizedString("exponent without digits: '%@'", comment: "Parse error; %@ = number text"), s), at: off) }
            text += "e" + signText + String(decoding: try withoutUnderscores(tok[k...], isDigit, off), as: UTF8.self)
            j = tok.count
        }
        guard j == tok.count, let d = Double(text) else { throw error(String(format: NSLocalizedString("invalid number: '%@'", comment: "Parse error; %@ = number text"), s), at: off) }
        return .decimal(d)
    }

    func twoDigits(_ t: [UInt8], _ i: Int) -> Int? {
        guard i + 1 < t.count, isDigit(t[i]), isDigit(t[i + 1]) else { return nil }
        return Int(t[i] - 0x30) * 10 + Int(t[i + 1] - 0x30)
    }

    /// Parses `HH:MM:SS(.frac)?` starting at `i`; returns the next position.
    func parseTime(_ t: [UInt8], _ i: Int, _ dt: inout DateTime, _ off: Int) throws(ParseError) -> Int {
        guard let h = twoDigits(t, i), i + 2 < t.count, t[i + 2] == 0x3A,
              let m = twoDigits(t, i + 3), i + 5 < t.count, t[i + 5] == 0x3A,
              let s = twoDigits(t, i + 6) else {
            throw error(NSLocalizedString("invalid time (use HH:MM:SS)", comment: "Parse error"), at: off)
        }
        guard h <= 23, m <= 59, s <= 60 else { throw error(NSLocalizedString("time out of range", comment: "Parse error"), at: off) }
        dt.hour = h; dt.minute = m; dt.second = s
        var j = i + 8
        if j < t.count, t[j] == DOT {
            j += 1
            let fracStart = j
            while j < t.count, isDigit(t[j]) { j += 1 }
            guard j > fracStart else { throw error(NSLocalizedString("fraction of second without digits", comment: "Parse error"), at: off) }
            let digitStr = t[fracStart..<j]
            dt.fractionDigits = digitStr.count
            var n = 0
            for (k, d) in digitStr.prefix(9).enumerated() { _ = k; n = n * 10 + Int(d - 0x30) }
            for _ in 0..<max(0, 9 - digitStr.count) { n *= 10 }
            dt.nanos = n
        }
        return j
    }

    func timeOnly(_ t: [UInt8], _ off: Int) throws(ParseError) -> DateTime {
        var dt = DateTime(kind: .time)
        let j = try parseTime(t, 0, &dt, off)
        guard j == t.count else { throw error(String(format: NSLocalizedString("invalid time: '%@'", comment: "Parse error; %@ = time text"), String(decoding: t, as: UTF8.self)), at: off) }
        return dt
    }

    func dateTime(_ t: [UInt8], _ off: Int) throws(ParseError) -> DateTime {
        let invalid = error(String(format: NSLocalizedString("invalid date: '%@'", comment: "Parse error; %@ = date text"), String(decoding: t, as: UTF8.self)), at: off)
        guard t.count >= 10, t[0..<4].allSatisfy(isDigit), t[4] == 0x2D,
              let month = twoDigits(t, 5), t[7] == 0x2D, let day = twoDigits(t, 8) else { throw invalid }
        let year = t[0..<4].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        let isLeapYear = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, isLeapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard month >= 1, month <= 12, day >= 1, day <= days[month - 1] else {
            throw error(String(format: NSLocalizedString("date not in the calendar: '%@'", comment: "Parse error; %@ = date text"), String(decoding: t, as: UTF8.self)), at: off)
        }
        var dt = DateTime(kind: .date)
        dt.year = year; dt.month = month; dt.day = day
        if t.count == 10 { return dt }
        guard t[10] == 0x54 || t[10] == 0x74 || t[10] == SPACE else { throw invalid }
        dt.kind = .local
        var j = try parseTime(t, 11, &dt, off)
        if j == t.count { return dt }
        dt.kind = .withOffset
        if t[j] == 0x5A || t[j] == 0x7A {
            dt.offsetIsZ = true
            dt.offsetMinutes = 0
            j += 1
        } else if t[j] == 0x2B || t[j] == 0x2D {
            guard let oh = twoDigits(t, j + 1), j + 3 < t.count, t[j + 3] == 0x3A,
                  let om = twoDigits(t, j + 4), oh <= 23, om <= 59 else { throw invalid }
            dt.offsetIsZ = false
            dt.offsetMinutes = (oh * 60 + om) * (t[j] == 0x2D ? -1 : 1)
            j += 6
        } else {
            throw invalid
        }
        guard j == t.count else { throw invalid }
        return dt
    }
}
