import Foundation

/// YAML 1.2 reader that keeps the position (in UTF-8 bytes) of each value.
///
/// Reads the subset that shows up in configuration files (docker-compose, GitHub
/// Actions, Kubernetes, `pubspec.yaml`, OpenAPI); details and reasons in the README:
///
/// - one document per file, with an optional `---` at the start and an optional `...` at the end;
/// - block maps and sequences (indentation with spaces only), including a sequence of maps
///   (`- name: x`) and a sequence at the same indentation as its key (`key:\n- a`);
/// - unquoted values (single- or multi-line), single- and double-quoted (with the
///   spec's escapes) and block scalars (`|` and `>`, with the `-`, `+` and indentation indicators);
/// - flow collections (`[a, b]`, `{a: 1}`), also spanning several lines;
/// - `#` comments.
///
/// Types follow the YAML 1.2 *core schema*: `true`/`false`, `null`/`~`/empty,
/// integers (with `0x` and `0o`), decimals, `.inf` and `.nan`; everything else is text
/// (`yes`, `no`, `on` and `off` included).
///
/// Outside the subset — anchors and aliases (`&x`, `*x`), merge keys (`<<:`), tags
/// (`!!str`, `!Ref`), multiple documents, complex keys (`? `, `[a]: b`), empty or null
/// keys and directives (`%YAML`) — the reader stops with a `ParseError` flagged
/// `outsideSubset`, with the line: the file opens in Text mode only, never half-read.
public enum YAMLReader {
    public static func parse(_ bytes: [UInt8]) throws(ParseError) -> ConfDocument {
        try YAMLParser(bytes).document()
    }

    public static func parse(_ text: String) throws(ParseError) -> ConfDocument {
        try parse(Array(text.utf8))
    }

    /// Reads a standalone value (the text of a raw field): `[1, a]`, `{a: 1}`, `"x"`, a block
    /// sequence (as it is in the file, with its indentation)… Empty text is null, like `key:`.
    public static func parseValue(_ text: String) throws(ParseError) -> Value {
        let doc = try parse(Array(text.utf8))
        return doc.empty ? .null : doc.rootValue
    }

    /// Type of an unquoted value under the YAML 1.2 *core schema*.
    public static func resolver(_ s: String) -> Value {
        switch s {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .boolean(true)
        case "false", "False", "FALSE": return .boolean(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .decimal(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .decimal(-.infinity)
        case ".nan", ".NaN", ".NAN": return .decimal(.nan)
        default: break
        }
        let u = Array(s.utf8)
        func digit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        if u.count > 2, u[0] == 0x30, u[1] == 0x6F || u[1] == 0x78 {            // 0o, 0x
            let rest = u[2...]
            let hex = u[1] == 0x78
            let ok = rest.allSatisfy { c in
                hex ? (digit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)) : (c >= 0x30 && c <= 0x37)
            }
            if ok {
                let t = String(decoding: rest, as: UTF8.self)
                if let n = Int64(t, radix: hex ? 16 : 8) { return .integer(n) }
                if let n = UInt64(t, radix: hex ? 16 : 8) { return .decimal(Double(n)) }
                return .decimal(Double(t.utf8.reduce(0.0) { $0 * (hex ? 16 : 8) + Double(Int(String(UnicodeScalar($1)), radix: 16)!) }))
            }
        }
        // [-+]? ( \.[0-9]+ | [0-9]+ ( \.[0-9]* )? ) ( [eE] [-+]? [0-9]+ )?
        var i = 0
        if i < u.count, u[i] == 0x2B || u[i] == 0x2D { i += 1 }
        var before = 0, after = 0, dot = false, exponent = false
        while i < u.count, digit(u[i]) { i += 1; before += 1 }
        if i < u.count, u[i] == 0x2E {
            dot = true
            i += 1
            while i < u.count, digit(u[i]) { i += 1; after += 1 }
        }
        guard before > 0 || after > 0 else { return .text(s) }
        if i < u.count, u[i] == 0x65 || u[i] == 0x45 {
            exponent = true
            i += 1
            if i < u.count, u[i] == 0x2B || u[i] == 0x2D { i += 1 }
            var d = 0
            while i < u.count, digit(u[i]) { i += 1; d += 1 }
            guard d > 0 else { return .text(s) }
        }
        guard i == u.count else { return .text(s) }
        if !dot && !exponent {
            if let n = Int64(s) { return .integer(n) }
            return .decimal(Double(s) ?? .nan)
        }
        // `Double` doesn't accept "1." or a signed ".5" on every platform: normalize
        var t = s
        if dot && after == 0 { t = t.replacingOccurrences(of: ".", with: ".0") }
        if dot && before == 0 { t = t.replacingOccurrences(of: ".", with: "0.") }
        return .decimal(Double(t) ?? .nan)
    }
}

extension ConfDocument {
    /// YAML with no document at all (empty file or only comments).
    var empty: Bool { format == .yaml && headers.isEmpty && entries.isEmpty }
}

// MARK: - Constants

private let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09, SPACE: UInt8 = 0x20
private let QUOTE: UInt8 = 0x22, APOS: UInt8 = 0x27, HASH: UInt8 = 0x23, COLON: UInt8 = 0x3A
private let HYPHEN: UInt8 = 0x2D, COMMA: UInt8 = 0x2C, BACKSLASH: UInt8 = 0x5C, DOT: UInt8 = 0x2E
private let LBRACKET: UInt8 = 0x5B, RBRACKET: UInt8 = 0x5D, LBRACE: UInt8 = 0x7B, RBRACE: UInt8 = 0x7D

@inline(__always) private func isWhitespace(_ c: UInt8) -> Bool { c == SPACE || c == TAB }
@inline(__always) private func isNewline(_ c: UInt8) -> Bool { c == LF || c == CR }
@inline(__always) private func isFlowIndicator(_ c: UInt8) -> Bool {
    c == COMMA || c == LBRACKET || c == RBRACKET || c == LBRACE || c == RBRACE
}

// MARK: - Tree

/// A parsed node, with its byte range and, for collections, its children.
private final class YAMLNode {
    enum NodeStyle { case plain, single, double, literal, folded, empty, blockMap, blockSeq, flowMap, flowSeq }

    struct Member {
        var key: String
        var keyRange: Range<Int>
        var node: YAMLNode
        var above: [String]
        var end: String?
    }

    struct Item {
        var node: YAMLNode
        var above: [String]
        var end: String?
    }

    var shape: NodeStyle
    var value: Value
    var range: Range<Int>
    var members: [Member] = []
    var items: [Item] = []
    /// Text of a scalar before resolving its type (for unquoted keys: `1: a` has the key "1").
    var text = ""
    /// Comment on the block indicator's line (`key: | # note`).
    var headerComment: String?

    init(_ shape: NodeStyle, _ value: Value, _ range: Range<Int>) {
        self.shape = shape
        self.value = value
        self.range = range
    }

    var isBlockMap: Bool { shape == .blockMap }
    var isMap: Bool { shape == .blockMap || shape == .flowMap }
    /// Block sequence made only of block maps: becomes a group of sections, like `[[array]]` in TOML.
    var isArrayOfMaps: Bool { shape == .blockSeq && !items.isEmpty && items.allSatisfy { $0.node.isBlockMap } }

    var position: Position { Position(range: range, items: items.map(\.node.position)) }
}

// MARK: - Parser

private final class YAMLParser {
    let b: [UInt8]
    let start: Int
    var p = 0

    /// Comments on their own lines right above the next element (with no blank line in between).
    var pendingItems: [String] = []
    /// After `gap()`: whether it moved to another line, that line's indentation (spaces only)
    /// and whether there was a tab between the indentation and the content.
    var crossedLine = false
    var tabInIndent = false

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

    @inline(__always) func c(_ i: Int) -> UInt8 { i < b.count && i >= 0 ? b[i] : 0 }
    /// End of file, space, tab or line break at the position.
    @inline(__always) func emptyAt(_ i: Int) -> Bool { i >= b.count || isWhitespace(b[i]) || isNewline(b[i]) }

    func lineIndex(_ off: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if lineStarts[m] <= off { lo = m } else { hi = m - 1 }
        }
        return lo
    }

    func line(_ off: Int) -> Int { lineIndex(min(max(off, 0), b.count)) + 1 }

    func startOfLine(_ off: Int) -> Int {
        var i = min(off, b.count)
        while i > start, b[i - 1] != LF { i -= 1 }
        return max(i, i == 0 ? start : i)
    }

    /// Column in bytes (the indentation before nodes is always ASCII).
    func column(_ off: Int) -> Int { off - startOfLine(off) }

    func endOfLine(_ off: Int) -> Int {
        var i = off
        while i < b.count, !isNewline(b[i]) { i += 1 }
        return i
    }

    /// `---` or `...` at column 0, followed by a space, line break or end of file.
    func marker(_ i: Int) -> UInt8? {
        guard i + 3 <= b.count, column(i) == 0 else { return nil }
        let x = b[i]
        guard x == HYPHEN || x == DOT, b[i + 1] == x, b[i + 2] == x, emptyAt(i + 3) else { return nil }
        return x
    }

    func error(_ msg: String, at off: Int) -> ParseError {
        let o = min(max(off, 0), b.count)
        let l = lineIndex(o)
        var lineStart = lineStarts[l]
        if l == 0 { lineStart = max(lineStart, start) }
        var col = 1
        if lineStart < o { for i in lineStart..<o where b[i] & 0xC0 != 0x80 { col += 1 } }
        return ParseError(message: msg, line: l + 1, column: col, offset: o, format: .yaml)
    }

    func outside(_ msg: String, at off: Int) -> ParseError {
        var e = error(String(format: NSLocalizedString("%@ is outside the subset Konfig edits in Form mode; the file opens in Text mode only", comment: "YAML parse error; %@ = the unsupported feature (e.g. 'anchor (&)')"), msg),
                      at: off)
        e.outsideSubset = true
        return e
    }

    func text(_ r: Range<Int>) -> String { String(decoding: b[r], as: UTF8.self) }

    /// Text of a comment from the `#`, without the repeated marks and without surrounding spaces.
    func comment(_ r: Range<Int>) -> String {
        var i = r.lowerBound
        while i < r.upperBound, b[i] == HASH { i += 1 }
        return text(i..<r.upperBound).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Characters

    /// Valid UTF-8 and only characters YAML accepts (no control characters other than tab and line breaks).
    func validateAll() throws(ParseError) {
        var i = 0
        let n = b.count
        while i < n {
            let x = b[i]
            if x < 0x80 {
                if (x < 0x20 && x != TAB && x != LF && x != CR) || x == 0x7F {
                    throw error(String(format: NSLocalizedString("control character (%@) is not allowed in YAML", comment: "YAML parse error; %@ = code, e.g. 0x1F or U+0085"), String(format: "0x%02X", x)), at: i)
                }
                if x == CR && c(i + 1) != LF {
                    throw error(NSLocalizedString("lone CR (without LF) is not an accepted line break", comment: "YAML parse error"), at: i)
                }
                i += 1
                continue
            }
            var len = 0, minimum: UInt32 = 0, v: UInt32 = 0
            if x & 0xE0 == 0xC0 { len = 2; minimum = 0x80; v = UInt32(x & 0x1F) }
            else if x & 0xF0 == 0xE0 { len = 3; minimum = 0x800; v = UInt32(x & 0x0F) }
            else if x & 0xF8 == 0xF0 { len = 4; minimum = 0x10000; v = UInt32(x & 0x07) }
            else { throw error(NSLocalizedString("invalid UTF-8 (the file must be in UTF-8)", comment: "YAML parse error"), at: i) }
            guard i + len <= n else { throw error(NSLocalizedString("invalid UTF-8 (incomplete sequence)", comment: "YAML parse error"), at: i) }
            for k in 1..<len {
                let d = b[i + k]
                guard d & 0xC0 == 0x80 else { throw error(NSLocalizedString("invalid UTF-8 (the file must be in UTF-8)", comment: "YAML parse error"), at: i) }
                v = (v << 6) | UInt32(d & 0x3F)
            }
            if v < minimum || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) { throw error(NSLocalizedString("invalid UTF-8", comment: "YAML parse error"), at: i) }
            if (v >= 0x80 && v <= 0x9F && v != 0x85) || v == 0xFFFE || v == 0xFFFF {
                throw error(String(format: NSLocalizedString("control character (%@) is not allowed in YAML", comment: "YAML parse error; %@ = code, e.g. 0x1F or U+0085"), String(format: "U+%04X", v)), at: i)
            }
            i += len
        }
    }

    // MARK: Whitespace and comments

    /// Skips spaces and a comment up to the end of the line and, after that, blank and comment
    /// lines (kept in `pendingItems`). Stops at the first content character of the
    /// next line (or at end of file) — or, if there is more text on the same line, at it.
    /// Returns the comment that was at the end of the line.
    @discardableResult
    func gap(atStartOfLine: Bool = false) throws(ParseError) -> String? {
        var end: String? = nil
        var i = p
        crossedLine = false
        tabInIndent = false
        if !atStartOfLine {
            while i < b.count, isWhitespace(b[i]) { i += 1 }
            if i < b.count, b[i] == HASH {
                guard i == startOfLine(i) || isWhitespace(b[i - 1]) else {
                    throw error(NSLocalizedString("'#' attached to the value: a comment needs a space before it", comment: "YAML parse error"), at: i)
                }
                let f = endOfLine(i)
                end = comment(i..<f)
                i = f
            }
            if i < b.count, !isNewline(b[i]) { p = i; return end }
            // line break
            if i < b.count { i += b[i] == CR ? 2 : 1 }
        }
        while i < b.count {
            while i < b.count, b[i] == SPACE { i += 1 }
            var j = i
            while j < b.count, isWhitespace(b[j]) { j += 1 }
            if j >= b.count { i = j; break }
            if isNewline(b[j]) {
                pendingItems = []          // a blank line separates the comment from what follows
                i = j + (b[j] == CR ? 2 : 1)
                continue
            }
            if b[j] == HASH {
                let f = endOfLine(j)
                pendingItems.append(comment(j..<f))
                i = f < b.count ? f + (b[f] == CR ? 2 : 1) : f
                continue
            }
            p = j
            crossedLine = true
            tabInIndent = j > i
            return end
        }
        p = b.count
        crossedLine = true
        return end
    }

    // MARK: Document

    var entries: [Entry] = []
    var headers: [SectionHeader] = []

    func document() throws(ParseError) -> ConfDocument {
        try validateAll()
        p = start
        try gap(atStartOfLine: true)
        if p < b.count, b[p] == 0x25, column(p) == 0 {                        // %
            throw outside(String(format: NSLocalizedString("directive (%@)", comment: "YAML feature outside the subset; %@ = the directive"), text(p..<min(endOfLine(p), p + 20))), at: p)
        }
        var root: YAMLNode? = nil
        var aboveRoot: [String] = []
        if marker(p) == HYPHEN {
            let after = p + 3
            p = after
            var i = p
            while i < b.count, isWhitespace(b[i]) { i += 1 }
            if i < b.count, !isNewline(b[i]), b[i] != HASH {
                p = i
                aboveRoot = pendingItems
                root = try nodeWithGap(parent: -1, newLine: false).node
            } else {
                try gap()
                if p < b.count, marker(p) == nil {
                    aboveRoot = pendingItems
                    root = try nodeWithGap(parent: -1, newLine: true).node
                } else {
                    root = YAMLNode(.empty, .null, after..<after)
                }
            }
        } else if p < b.count, marker(p) == nil {
            aboveRoot = pendingItems
            root = try nodeWithGap(parent: -1, newLine: true).node
        }
        if p < b.count {
            if marker(p) == DOT {
                p += 3
                try gap()
                if p < b.count { throw outside(NSLocalizedString("more than one document in the file", comment: "YAML feature outside the subset"), at: p) }
            } else if marker(p) == HYPHEN {
                throw outside(NSLocalizedString("more than one document in the file (second '---')", comment: "YAML feature outside the subset"), at: p)
            } else {
                throw error(NSLocalizedString("unexpected text (less indentation than at the start of the document?)", comment: "YAML parse error"), at: p)
            }
        }

        var rootValue: Value = .table(Table())
        if let r = root {
            rootValue = r.value
            if r.isMap {
                walk(r, path: [], names: [], section: nil)
            } else if r.isArrayOfMaps {
                arrayItems(r, path: [], names: [], aboveArray: [], endOfArray: nil)
            } else {
                let iv = r.range
                entries.append(Entry(path: [], writtenKey: NSLocalizedString("(root)", comment: "Label of a document whose root is a single value"), value: r.value, position: r.position,
                                        keyRange: iv.lowerBound..<iv.lowerBound, line: line(iv.lowerBound),
                                        lastLine: line(max(iv.lowerBound, iv.upperBound - 1)),
                                        commentAbove: aboveRoot, trailingComment: r.headerComment, section: nil))
            }
        }
        var newline = "\n"
        if let i = b.firstIndex(of: LF), i > 0, b[i - 1] == CR { newline = "\r\n" }
        return ConfDocument(format: .yaml, bytes: b, root: rootValue, entries: entries, headers: headers,
                             lineBreak: newline, hasBOM: start == 3)
    }

    /// Members of a map: block maps become sections; sequences of maps only, groups; the rest, fields.
    func walk(_ map: YAMLNode, path: ValuePath, names: [String], section: Int?) {
        for m in map.members {
            let pathSoFar = path + [.key(m.key)]
            if m.node.isBlockMap {
                let idx = headers.count
                headers.append(SectionHeader(path: pathSoFar, names: names + [m.key], isArrayOfTables: false,
                                            range: m.node.range, line: line(m.keyRange.lowerBound),
                                            commentAbove: m.above, trailingComment: m.end))
                walk(m.node, path: pathSoFar, names: names + [m.key], section: idx)
            } else if m.node.isArrayOfMaps {
                arrayItems(m.node, path: pathSoFar, names: names + [m.key], aboveArray: m.above, endOfArray: m.end)
            } else {
                let iv = m.node.range
                entries.append(Entry(path: pathSoFar, writtenKey: m.key, value: m.node.value, position: m.node.position,
                                        keyRange: m.keyRange, line: line(m.keyRange.lowerBound),
                                        lastLine: line(max(iv.lowerBound, iv.upperBound - 1)),
                                        commentAbove: m.above, trailingComment: m.end, section: section))
            }
        }
    }

    /// Each map in a sequence of maps becomes a section, like an item of a TOML `[[array]]`.
    func arrayItems(_ l: YAMLNode, path: ValuePath, names: [String], aboveArray: [String], endOfArray: String?) {
        let ofArray = aboveArray + [endOfArray].compactMap { $0 }
        for (j, item) in l.items.enumerated() {
            let pathSoFar = path + [.index(j)]
            let idx = headers.count
            headers.append(SectionHeader(path: pathSoFar, names: names, isArrayOfTables: true, range: item.node.range,
                                        line: line(item.node.range.lowerBound),
                                        commentAbove: ofArray + item.above, trailingComment: item.end))
            walk(item.node, path: pathSoFar, names: names, section: idx)
        }
    }

    // MARK: Block nodes

    /// Reads the node starting at `p` and the rest of the line (and the following blank and
    /// comment lines). `parent` is the indentation of the map or sequence containing the node (−1 at
    /// the root); `newLine`, whether the node starts at the beginning of a line (only then can it be a
    /// block map or sequence). Block collections already end after the gap.
    func nodeWithGap(parent n: Int, newLine: Bool) throws(ParseError) -> (node: YAMLNode, end: String?) {
        let x = b[p]
        switch x {
        case 0x26: throw outside(NSLocalizedString("anchor (&)", comment: "YAML feature outside the subset"), at: p)
        case 0x2A: throw outside(NSLocalizedString("alias (*)", comment: "YAML feature outside the subset"), at: p)
        case 0x21: throw outside(NSLocalizedString("type tag (!)", comment: "YAML feature outside the subset"), at: p)
        case 0x3F where emptyAt(p + 1): throw outside(NSLocalizedString("complex key ('? ')", comment: "YAML feature outside the subset"), at: p)
        case HYPHEN where emptyAt(p + 1):
            guard newLine else { throw error(NSLocalizedString("a block list ('- ') cannot start on this line", comment: "YAML parse error"), at: p) }
            if tabInIndent { throw error(NSLocalizedString("tab in indentation (YAML indentation uses spaces only)", comment: "YAML parse error"), at: p) }
            return (try blockSeq(column: column(p)), nil)
        case 0x7C, 0x3E:                                                     // | >
            let node = try blockScalar(parent: n)
            try gap()
            return (node, node.headerComment)
        default: break
        }
        if try isImplicitKey() {
            guard newLine else {
                throw error(NSLocalizedString("a map ('key: value') cannot start on this line; put the value in quotes or on its own line", comment: "YAML parse error"), at: p)
            }
            if tabInIndent { throw error(NSLocalizedString("tab in indentation (YAML indentation uses spaces only)", comment: "YAML parse error"), at: p) }
            return (try blockMap(column: column(p)), nil)
        }
        let node: YAMLNode
        switch x {
        case LBRACKET, LBRACE: node = try flow(parent: n)
        case QUOTE, APOS: node = try quotedScalar(parent: n, flow: false)
        default: node = try plainScalar(parent: n, flow: false)
        }
        let end = try gap()
        if !crossedLine {
            if b[p] == COLON {
                throw error(NSLocalizedString("unexpected ':': a map cannot start here (multi-line key, or a value with ': ' that needs quotes)", comment: "YAML parse error"), at: p)
            }
            throw error(NSLocalizedString("unexpected text after the value", comment: "YAML parse error"), at: p)
        }
        return (node, end)
    }

    /// Is there a key (`key:` followed by a space or end of line) starting at `p`, on this line?
    func isImplicitKey() throws(ParseError) -> Bool {
        let x = b[p]
        var j = p
        let lineEnd = endOfLine(p)
        switch x {
        case QUOTE, APOS:
            j += 1
            while j < lineEnd {
                if x == QUOTE && b[j] == BACKSLASH { j += 2; continue }
                if b[j] == x {
                    if x == APOS && c(j + 1) == APOS { j += 2; continue }
                    break
                }
                j += 1
            }
            guard j < lineEnd else { return false }
            j += 1
            while j < lineEnd, isWhitespace(b[j]) { j += 1 }
            return j < lineEnd && b[j] == COLON && emptyAt(j + 1)
        case LBRACKET, LBRACE:
            // flow collection used as a key: `[a, b]: c`
            var level = 0
            var quote: UInt8 = 0
            while j < lineEnd {
                let y = b[j]
                if quote != 0 {
                    if quote == QUOTE && y == BACKSLASH { j += 2; continue }
                    if y == quote { quote = 0 }
                } else if y == QUOTE || y == APOS {
                    quote = y
                } else if y == LBRACKET || y == LBRACE {
                    level += 1
                } else if y == RBRACKET || y == RBRACE {
                    level -= 1
                    if level == 0 { break }
                } else if y == HASH, isWhitespace(b[j - 1]) {
                    return false
                }
                j += 1
            }
            guard j < lineEnd else { return false }
            j += 1
            while j < lineEnd, isWhitespace(b[j]) { j += 1 }
            if j < lineEnd, b[j] == COLON, emptyAt(j + 1) {
                throw outside(NSLocalizedString("complex key (collection as key)", comment: "YAML feature outside the subset"), at: p)
            }
            return false
        case COLON where emptyAt(p + 1):
            throw outside(NSLocalizedString("empty key (': value')", comment: "YAML feature outside the subset"), at: p)
        default:
            if !canStartPlain(p, flow: false) { return false }
            while j < lineEnd {
                if b[j] == COLON && emptyAt(j + 1) { return true }
                if b[j] == HASH && j > p && isWhitespace(b[j - 1]) { return false }
                j += 1
            }
            return false
        }
    }

    /// Reads the key at `p` (on a single line) and returns its text and range; `p` ends right after it.
    func key(flow: Bool) throws(ParseError) -> (String, Range<Int>, YAMLNode) {
        let begin = p
        let x = b[p]
        switch x {
        case 0x26: throw outside(NSLocalizedString("anchor (&)", comment: "YAML feature outside the subset"), at: p)
        case 0x2A: throw outside(NSLocalizedString("alias (*)", comment: "YAML feature outside the subset"), at: p)
        case 0x21: throw outside(NSLocalizedString("type tag (!)", comment: "YAML feature outside the subset"), at: p)
        case 0x3F where emptyAt(p + 1) || (flow && isFlowIndicator(c(p + 1))): throw outside(NSLocalizedString("complex key ('? ')", comment: "YAML feature outside the subset"), at: p)
        case LBRACKET, LBRACE: throw outside(NSLocalizedString("complex key (collection as key)", comment: "YAML feature outside the subset"), at: p)
        case COLON where emptyAt(p + 1) || (flow && isFlowIndicator(c(p + 1))): throw outside(NSLocalizedString("empty key (': value')", comment: "YAML feature outside the subset"), at: p)
        default: break
        }
        let node: YAMLNode
        if x == QUOTE || x == APOS {
            node = try quotedScalar(parent: -1, flow: flow)
        } else {
            guard canStartPlain(p, flow: flow) else {
                throw error(String(format: NSLocalizedString("character '%@' cannot start an unquoted key", comment: "YAML parse error; %@ = the character"), String(UnicodeScalar(x))), at: p)
            }
            // inside `{ }` the key may span several lines; in a block map, it may not
            node = try plainScalar(parent: -1, flow: flow, oneLine: !flow)
        }
        if !flow, line(node.range.lowerBound) != line(max(node.range.lowerBound, node.range.upperBound - 1)) {
            throw error(NSLocalizedString("multi-line keys are not accepted", comment: "YAML parse error"), at: begin)
        }
        guard case .text(let k) = node.shape == .plain ? .text(node.text) : node.value else {
            throw error(NSLocalizedString("invalid key", comment: "YAML parse error"), at: begin)
        }
        if node.shape == .plain {
            if k == "<<" { throw outside(NSLocalizedString("merge key ('<<:')", comment: "YAML feature outside the subset"), at: begin) }
            if case .null = node.value { throw outside(String(format: NSLocalizedString("null key ('%@')", comment: "YAML feature outside the subset; %@ = the key"), k), at: begin) }
        }
        return (k, node.range, node)
    }

    /// Block map whose keys are at column `m`; `p` is at the first key.
    func blockMap(column m: Int) throws(ParseError) -> YAMLNode {
        let begin = p
        var members: [YAMLNode.Member] = []
        var lineOfKey: [String: Int] = [:]
        var table = Table()
        var valueEnd = p
        while true {
            let above = pendingItems
            pendingItems = []
            if b[p] == HYPHEN && emptyAt(p + 1) {
                throw error(NSLocalizedString("list item ('- ') where a map key was expected (check the indentation)", comment: "YAML parse error"), at: p)
            }
            let (k, rKey, _) = try key(flow: false)
            while p < b.count, isWhitespace(b[p]) { p += 1 }
            guard p < b.count, b[p] == COLON else { throw error(String(format: NSLocalizedString("expected ':' after key '%@'", comment: "YAML parse error; %@ = the key"), k), at: p) }
            guard emptyAt(p + 1) else { throw error(NSLocalizedString("':' must be followed by a space or end of line", comment: "YAML parse error"), at: p + 1) }
            if let l = lineOfKey[k] {
                throw error(String(format: NSLocalizedString("key '%@' already appeared on line %ld in this map; duplicate keys are not accepted", comment: "YAML parse error; %@ = the key, %ld = line number"), k, l), at: rKey.lowerBound)
            }
            lineOfKey[k] = line(rKey.lowerBound)
            p += 1
            let (node, end) = try valueOfKey(indent: m)
            members.append(YAMLNode.Member(key: k, keyRange: rKey, node: node, above: above, end: end))
            table.pairs.append(Table.Pair(key: k, value: node.value))
            valueEnd = max(node.range.upperBound, rKey.upperBound + 1)
            // p is at the next content
            if p >= b.count || marker(p) != nil { break }
            let col = column(p)
            if col < m { break }
            if col > m { throw error(String(format: NSLocalizedString("unexpected indentation (expected a key at column %ld)", comment: "YAML parse error; %ld = column number"), m + 1), at: p) }
            if tabInIndent { throw error(NSLocalizedString("tab in indentation (YAML indentation uses spaces only)", comment: "YAML parse error"), at: p) }
        }
        let node = YAMLNode(.blockMap, .table(table), begin..<valueEnd)
        node.members = members
        return node
    }

    /// Value after `key:` in a block map with indentation `m`; `p` is right after the `:`.
    func valueOfKey(indent m: Int) throws(ParseError) -> (YAMLNode, String?) {
        let after = p
        while p < b.count, isWhitespace(b[p]) { p += 1 }
        if p >= b.count || isNewline(b[p]) || b[p] == HASH {
            p = after
            let end = try gap()
            if p < b.count, marker(p) == nil {
                let col = column(p)
                if col > m {
                    return (try nodeWithGap(parent: m, newLine: true).node, end)
                }
                if col == m, b[p] == HYPHEN, emptyAt(p + 1) {
                    // sequence at the same indentation as the key (`key:\n- a`)
                    if tabInIndent { throw error(NSLocalizedString("tab in indentation (YAML indentation uses spaces only)", comment: "YAML parse error"), at: p) }
                    return (try blockSeq(column: m), end)
                }
            }
            return (YAMLNode(.empty, .null, after..<after), end)
        }
        let r = try nodeWithGap(parent: m, newLine: false)
        return (r.node, r.end)
    }

    /// Block sequence with its `-` at column `col`; `p` is at the first `-`.
    func blockSeq(column col: Int) throws(ParseError) -> YAMLNode {
        let dash0 = p
        var items: [YAMLNode.Item] = []
        var values: [Value] = []
        var itemEnd = p + 1
        while true {
            let above = pendingItems
            pendingItems = []
            let dash = p
            p += 1
            while p < b.count, isWhitespace(b[p]) { p += 1 }
            let node: YAMLNode
            var end: String? = nil
            if p >= b.count || isNewline(b[p]) || b[p] == HASH {
                p = dash + 1
                end = try gap()
                if p < b.count, marker(p) == nil, column(p) > col {
                    node = try nodeWithGap(parent: col, newLine: true).node
                } else {
                    node = YAMLNode(.empty, .null, (dash + 1)..<(dash + 1))
                }
            } else {
                let tab = b[(dash + 1)..<p].contains(TAB)
                // compact sequence or map (`- - a`, `- key: value`)
                var compact = b[p] == HYPHEN && emptyAt(p + 1)
                if !compact { compact = try isImplicitKey() }
                if compact && tab { throw error(NSLocalizedString("tab in indentation (YAML indentation uses spaces only)", comment: "YAML parse error"), at: p) }
                tabInIndent = false
                let r = try nodeWithGap(parent: col, newLine: true)
                node = r.node
                end = r.end
            }
            items.append(YAMLNode.Item(node: node, above: above, end: end))
            values.append(node.value)
            itemEnd = endOfLine(max(node.range.upperBound, dash + 1))
            if p >= b.count || marker(p) != nil { break }
            let c2 = column(p)
            if c2 < col { break }
            if c2 > col { throw error(String(format: NSLocalizedString("unexpected indentation (expected '- ' at column %ld)", comment: "YAML parse error; %ld = column number"), col + 1), at: p) }
            guard b[p] == HYPHEN, emptyAt(p + 1) else { break }
            if tabInIndent { throw error(NSLocalizedString("tab in indentation (YAML indentation uses spaces only)", comment: "YAML parse error"), at: p) }
        }
        // the sequence spans the items' whole lines (from the start of the first `-`'s line to the end
        // of the last item's line): this way lines can be added and removed
        let firstLine = startOfLine(dash0)
        let begin = b[firstLine..<dash0].allSatisfy { $0 == SPACE } ? firstLine : dash0
        let node = YAMLNode(.blockSeq, .array(values), begin..<itemEnd)
        node.items = items
        return node
    }

    // MARK: Scalars

    /// Can the character at `i` start an unquoted value?
    func canStartPlain(_ i: Int, flow: Bool) -> Bool {
        let x = c(i)
        switch x {
        case 0, SPACE, TAB, LF, CR: return false
        case COMMA, LBRACKET, RBRACKET, LBRACE, RBRACE, HASH, 0x26, 0x2A, 0x21, 0x7C, 0x3E,
             APOS, QUOTE, 0x25, 0x40, 0x60:                                   // , [ ] { } # & * ! | > ' " % @ `
            return false
        case HYPHEN, 0x3F, COLON:                                        // - ? :
            let y = c(i + 1)
            return !emptyAt(i + 1) && !(flow && isFlowIndicator(y))
        default:
            return true
        }
    }

    /// Unquoted value, single- or multi-line (line breaks become a space; blank lines, `\n`).
    func plainScalar(parent n: Int, flow: Bool, oneLine: Bool = false) throws(ParseError) -> YAMLNode {
        let begin = p
        guard canStartPlain(p, flow: flow) else {
            let x = b[p]
            if x == 0x40 || x == 0x60 { throw error(String(format: NSLocalizedString("'%@' is reserved and cannot start an unquoted value", comment: "YAML parse error; %@ = the character"), String(UnicodeScalar(x))), at: p) }
            throw error(String(format: NSLocalizedString("unexpected character '%@'", comment: "YAML parse error; %@ = the character"), String(UnicodeScalar(x))), at: p)
        }
        var output: [UInt8] = []
        var end = p
        /// Reads one line's text from `i`; returns where it stopped and the end of the text (without trailing whitespace).
        func hunk(_ i0: Int) -> (stopped: Int, textEnd: Int) {
            var i = i0
            var ft = i0
            while i < b.count, !isNewline(b[i]) {
                let x = b[i]
                if x == COLON && (emptyAt(i + 1) || (flow && isFlowIndicator(c(i + 1)))) { break }
                if x == HASH && i > i0 && isWhitespace(b[i - 1]) { break }
                if flow && isFlowIndicator(x) { break }
                i += 1
                if !isWhitespace(x) { ft = i }
            }
            return (i, ft)
        }
        let (stopped, ft) = hunk(p)
        output += b[p..<ft]
        end = ft
        p = ft
        var i = stopped
        while !oneLine, i >= b.count || isNewline(b[i]) {
            // following lines: a continuation if indented more than the parent
            var k = i
            var blanks = 0
            var next: Int? = nil
            while k < b.count {
                k += b[k] == CR ? 2 : 1                                       // the line break
                let ls = k
                while k < b.count, b[k] == SPACE { k += 1 }
                let spaces = k - ls
                while k < b.count, isWhitespace(b[k]) { k += 1 }
                if k >= b.count { break }
                if isNewline(b[k]) { blanks += 1; continue }
                if b[k] == HASH { break }                               // a comment ends the value
                if spaces == 0, marker(ls) != nil { break }
                if !flow, spaces <= n { break }
                if flow, n >= 0, spaces <= n { break }
                next = k
                break
            }
            guard let cs = next else { break }
            let (stopped2, ft2) = hunk(cs)
            if ft2 == cs { break }                                            // the line starts with an indicator
            if blanks == 0 { output.append(SPACE) } else { output += [UInt8](repeating: LF, count: blanks) }
            output += b[cs..<ft2]
            end = ft2
            p = ft2
            i = stopped2
        }
        let s = String(decoding: output, as: UTF8.self)
        let node = YAMLNode(.plain, YAMLReader.resolver(s), begin..<end)
        node.text = s
        return node
    }

    /// Single-quoted (`''` is one quote) or double-quoted (with escapes) value. May span
    /// several lines: each line break becomes a space; blank lines, `\n`.
    func quotedScalar(parent n: Int, flow: Bool) throws(ParseError) -> YAMLNode {
        let begin = p
        let q = b[p]
        p += 1
        var s: [UInt8] = []
        /// Literal whitespace at the end of `s` (dropped before a line break; escaped ones stay).
        var trailingWhitespace = 0
        func put(_ v: UInt32) {
            s += Array(String(Character(Unicode.Scalar(v)!)).utf8)
            trailingWhitespace = 0
        }
        /// After a line break (already consumed): blank lines and the next line's indentation.
        func continuation(fold: Bool) throws(ParseError) {
            var blanks = 0
            while true {
                let ls = p
                while p < b.count, b[p] == SPACE { p += 1 }
                let spaces = p - ls
                while p < b.count, isWhitespace(b[p]) { p += 1 }
                guard p < b.count else { throw error(NSLocalizedString("unclosed quotes", comment: "YAML parse error"), at: begin) }
                if isNewline(b[p]) {
                    blanks += 1
                    p += b[p] == CR ? 2 : 1
                    continue
                }
                if spaces == 0, marker(ls) != nil {
                    throw error(NSLocalizedString("document marker inside a quoted string", comment: "YAML parse error"), at: ls)
                }
                if n >= 0, spaces <= n {
                    throw error(NSLocalizedString("continuation line of a quoted string is not indented enough", comment: "YAML parse error"), at: p)
                }
                break
            }
            if blanks > 0 { s += [UInt8](repeating: LF, count: blanks) } else if fold { s.append(SPACE) }
            trailingWhitespace = 0
        }
        while true {
            guard p < b.count else { throw error(q == QUOTE ? NSLocalizedString("unclosed double quotes", comment: "YAML parse error") : NSLocalizedString("unclosed single quotes", comment: "YAML parse error"), at: begin) }
            let x = b[p]
            if x == q {
                if q == APOS && c(p + 1) == APOS { s.append(APOS); trailingWhitespace = 0; p += 2; continue }
                p += 1
                break
            }
            if isNewline(x) {
                s.removeLast(trailingWhitespace)
                trailingWhitespace = 0
                p += x == CR ? 2 : 1
                try continuation(fold: true)
                continue
            }
            if q == QUOTE && x == BACKSLASH {
                let e = c(p + 1)
                var v: UInt32
                var len = 2
                switch e {
                case LF, CR:
                    // escaped line break: joins the lines without a space
                    p += e == CR ? 3 : 2
                    trailingWhitespace = 0
                    try continuation(fold: false)
                    continue
                case 0x30: v = 0
                case 0x61: v = 7
                case 0x62: v = 8
                case 0x74, TAB: v = 9
                case 0x6E: v = 0x0A
                case 0x76: v = 0x0B
                case 0x66: v = 0x0C
                case 0x72: v = 0x0D
                case 0x65: v = 0x1B
                case SPACE: v = 0x20
                case QUOTE: v = 0x22
                case 0x2F: v = 0x2F
                case BACKSLASH: v = 0x5C
                case 0x4E: v = 0x85
                case 0x5F: v = 0xA0
                case 0x4C: v = 0x2028
                case 0x50: v = 0x2029
                case 0x78, 0x75, 0x55:                                        // x u U
                    let digitCount = e == 0x78 ? 2 : e == 0x75 ? 4 : 8
                    guard p + 2 + digitCount <= b.count,
                          let h = UInt32(String(decoding: b[(p + 2)..<(p + 2 + digitCount)], as: UTF8.self), radix: 16),
                          b[(p + 2)..<(p + 2 + digitCount)].allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) })
                    else { throw error(String(format: NSLocalizedString("escape '%@' needs %ld hexadecimal digits", comment: "YAML parse error; %@ = the escape, e.g. \\x; %ld = digit count"), "\\" + String(UnicodeScalar(e)), digitCount), at: p) }
                    v = h
                    len = 2 + digitCount
                    if v >= 0xD800 && v <= 0xDBFF, e == 0x75, c(p + 6) == BACKSLASH, c(p + 7) == 0x75, p + 12 <= b.count,
                       let lo = UInt32(String(decoding: b[(p + 8)..<(p + 12)], as: UTF8.self), radix: 16),
                       lo >= 0xDC00 && lo <= 0xDFFF {
                        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                        len = 12
                    }
                    guard Unicode.Scalar(v) != nil else { throw error(String(format: NSLocalizedString("invalid character escape (U+%@)", comment: "YAML parse error; %@ = hex code"), String(v, radix: 16, uppercase: true)), at: p) }
                default:
                    throw error(String(format: NSLocalizedString("escape '%@' does not exist in YAML", comment: "YAML parse error; %@ = the escape, e.g. \\q"), "\\" + (e < 0x80 ? String(UnicodeScalar(e)) : "…")), at: p)
                }
                put(v)
                p += len
                continue
            }
            s.append(x)
            if isWhitespace(x) { trailingWhitespace += 1 } else { trailingWhitespace = 0 }
            p += 1
        }
        return YAMLNode(q == QUOTE ? .double : .single, .text(String(decoding: s, as: UTF8.self)), begin..<p)
    }

    /// Block text `|` (literal) or `>` (folded), with the chomping (`-`, `+`) and indentation indicators.
    /// `p` ends at the end of the value's last line.
    func blockScalar(parent n: Int) throws(ParseError) -> YAMLNode {
        let begin = p
        let literal = b[p] == 0x7C
        p += 1
        var indentIndicator: Int? = nil
        var chomp = 0                                                       // -1 strip, 0 clip, +1 keep
        var sawChomp = false
        for _ in 0..<2 {
            let x = c(p)
            if x >= 0x31 && x <= 0x39 && indentIndicator == nil { indentIndicator = Int(x - 0x30); p += 1 }
            else if (x == 0x2B || x == HYPHEN) && !sawChomp { chomp = x == 0x2B ? 1 : -1; sawChomp = true; p += 1 }
            else if x == 0x30 { throw error(NSLocalizedString("the indentation indicator ranges from 1 to 9", comment: "YAML parse error"), at: p) }
            else { break }
        }
        guard emptyAt(p) else { throw error(String(format: NSLocalizedString("only indicators, spaces and a comment may follow '%@'", comment: "YAML parse error; %@ = | or >"), literal ? "|" : ">"), at: p) }
        while p < b.count, isWhitespace(b[p]) { p += 1 }
        var headerCommentText: String? = nil
        if p < b.count, b[p] == HASH {
            let f = endOfLine(p)
            headerCommentText = comment(p..<f)
            p = f
        }
        guard p >= b.count || isNewline(b[p]) else { throw error(NSLocalizedString("unexpected text after the block indicator", comment: "YAML parse error"), at: p) }
        let headerEnd = p
        let minimum = n + 1

        // lines: (start, end, leading spaces)
        var lines: [(start: Int, end: Int, spaces: Int)] = []
        var i = p
        while i < b.count {
            i += b[i] == CR ? 2 : 1
            if i >= b.count { break }
            let f = endOfLine(i)
            var e = 0
            while i + e < f, b[i + e] == SPACE { e += 1 }
            lines.append((i, f, e))
            i = f
        }
        func isBlank(_ l: (start: Int, end: Int, spaces: Int)) -> Bool { l.start + l.spaces == l.end }

        var indent: Int
        if let d = indentIndicator {
            indent = max(n, 0) + d
        } else {
            var maxEmpty = 0
            indent = minimum
            for l in lines {
                if isBlank(l) { maxEmpty = max(maxEmpty, l.spaces); continue }
                if l.spaces >= minimum, !(l.spaces == 0 && marker(l.start) != nil) {
                    if maxEmpty > l.spaces {
                        throw error(NSLocalizedString("blank line with more spaces than the first line of the block text", comment: "YAML parse error"), at: l.start)
                    }
                    indent = l.spaces
                } else {
                    indent = max(minimum, maxEmpty)
                }
                break
            }
            if lines.allSatisfy(isBlank) { indent = max(minimum, lines.map(\.spaces).max() ?? 0) }
        }
        indent = max(indent, 0)

        // splits the block's lines: empty and content ones, up to the first one with less indentation
        var content: [(text: Range<Int>, blanksBefore: Int)] = []
        var blanks = 0
        var contentEnd = headerEnd
        var totalEnd = headerEnd
        for l in lines {
            if isBlank(l) && l.spaces <= indent {
                // only spaces (up to the indentation): empty line; with more spaces, the extra ones are content
                blanks += 1
                totalEnd = l.end
                continue
            }
            if l.spaces < indent {
                // line with only whitespace and a tab before the indentation: tab in indentation
                if b[(l.start + l.spaces)..<l.end].allSatisfy({ isWhitespace($0) || $0 == CR }) {
                    throw error(NSLocalizedString("tab in the block text indentation (YAML indentation uses spaces only)", comment: "YAML parse error"), at: l.start + l.spaces)
                }
                break
            }
            if indent == 0, marker(l.start) != nil { break }
            content.append(((l.start + indent)..<l.end, blanks))
            blanks = 0
            contentEnd = l.end
            totalEnd = l.end
        }
        var r: [UInt8] = []
        var previousNormal = false
        for (k, lineC) in content.enumerated() {
            let t = b[lineC.text]
            let normal = !(t.first.map(isWhitespace) ?? false)
            if k == 0 {
                r += [UInt8](repeating: LF, count: lineC.blanksBefore)
            } else if !literal && previousNormal && normal {
                if lineC.blanksBefore == 0 { r.append(SPACE) } else { r += [UInt8](repeating: LF, count: lineC.blanksBefore) }
            } else {
                r += [UInt8](repeating: LF, count: lineC.blanksBefore + 1)
            }
            r += t
            previousNormal = normal
        }
        // the last line counts as ending with a line break even at end of file (as in yaml-test-suite)
        if content.isEmpty {
            if chomp == 1 { r += [UInt8](repeating: LF, count: blanks) }
        } else {
            if chomp >= 0 { r.append(LF) }
            if chomp == 1 { r += [UInt8](repeating: LF, count: blanks) }
        }
        // the value runs from the indicator to the end of its last line (with `+`, the trailing empty ones)
        let end = chomp == 1 ? totalEnd : (content.isEmpty ? headerEnd : contentEnd)
        p = end
        let node = YAMLNode(literal ? .literal : .folded, .text(String(decoding: r, as: UTF8.self)), begin..<end)
        node.headerComment = headerCommentText
        return node
    }

    // MARK: Flow collections

    /// Spaces, line breaks and comments inside a flow collection. Following lines
    /// need more indentation than `n` (the indentation of the block containing the collection).
    func flowSpace(parent n: Int) throws(ParseError) {
        while p < b.count {
            let x = b[p]
            if isWhitespace(x) { p += 1; continue }
            if x == HASH {
                guard isWhitespace(c(p - 1)) || isNewline(c(p - 1)) else {
                    throw error(NSLocalizedString("'#' attached: a comment needs a space before it", comment: "YAML parse error"), at: p)
                }
                p = endOfLine(p)
                continue
            }
            if isNewline(x) {
                p += x == CR ? 2 : 1
                let ls = p
                while p < b.count, b[p] == SPACE { p += 1 }
                let spaces = p - ls
                if spaces == 0, marker(ls) != nil {
                    throw error(NSLocalizedString("document marker inside a flow collection", comment: "YAML parse error"), at: ls)
                }
                var k = p
                while k < b.count, isWhitespace(b[k]) { k += 1 }
                if k < b.count, !isNewline(b[k]), b[k] != HASH, n >= 0, spaces <= n {
                    throw error(NSLocalizedString("insufficient indentation inside the flow collection", comment: "YAML parse error"), at: k)
                }
                continue
            }
            break
        }
    }

    func inFlow(parent n: Int) throws(ParseError) -> YAMLNode {
        guard p < b.count else { throw error(NSLocalizedString("unclosed flow collection", comment: "YAML parse error"), at: p) }
        let x = b[p]
        switch x {
        case 0x26: throw outside(NSLocalizedString("anchor (&)", comment: "YAML feature outside the subset"), at: p)
        case 0x2A: throw outside(NSLocalizedString("alias (*)", comment: "YAML feature outside the subset"), at: p)
        case 0x21: throw outside(NSLocalizedString("type tag (!)", comment: "YAML feature outside the subset"), at: p)
        case LBRACKET, LBRACE: return try flow(parent: n)
        case QUOTE, APOS: return try quotedScalar(parent: n, flow: true)
        case 0x3F where emptyAt(p + 1) || isFlowIndicator(c(p + 1)): throw outside(NSLocalizedString("complex key ('? ')", comment: "YAML feature outside the subset"), at: p)
        case HYPHEN where emptyAt(p + 1): throw error(NSLocalizedString("block list ('- ') inside a flow collection", comment: "YAML parse error"), at: p)
        case COLON where emptyAt(p + 1) || isFlowIndicator(c(p + 1)): throw outside(NSLocalizedString("empty key (': value')", comment: "YAML feature outside the subset"), at: p)
        default:
            guard canStartPlain(p, flow: true) else {
                throw error(String(format: NSLocalizedString("unexpected character '%@' in the flow collection", comment: "YAML parse error; %@ = the character"), String(UnicodeScalar(x))), at: p)
            }
            return try plainScalar(parent: n, flow: true)
        }
    }

    /// Flow collection `[…]` or `{…}`, also spanning several lines.
    func flow(parent n: Int) throws(ParseError) -> YAMLNode {
        let begin = p
        let isArray = b[p] == LBRACKET
        let closes = isArray ? RBRACKET : RBRACE
        p += 1
        var items: [YAMLNode.Item] = []
        var members: [YAMLNode.Member] = []
        var table = Table()
        var values: [Value] = []
        var lineOfKey: [String: Int] = [:]
        while true {
            try flowSpace(parent: n)
            guard p < b.count else { throw error(isArray ? NSLocalizedString("missing ']' to close the list", comment: "YAML parse error") : NSLocalizedString("missing '}' to close the map", comment: "YAML parse error"), at: begin) }
            if b[p] == closes { p += 1; break }
            if b[p] == COMMA { throw error(NSLocalizedString("',' without a value before it", comment: "YAML parse error"), at: p) }
            if isArray {
                var node = try inFlow(parent: n)
                try flowSpace(parent: n)
                if p < b.count, b[p] == COLON,
                   emptyAt(p + 1) || isFlowIndicator(c(p + 1)) || node.shape != .plain {
                    // single pair inside the sequence: `[a: 1]` is `[{a: 1}]`
                    guard node.shape == .plain || node.shape == .single || node.shape == .double else {
                        throw outside(NSLocalizedString("complex key (collection as key)", comment: "YAML feature outside the subset"), at: node.range.lowerBound)
                    }
                    if line(node.range.lowerBound) != line(p) { throw error(NSLocalizedString("multi-line keys are not accepted", comment: "YAML parse error"), at: node.range.lowerBound) }
                    let k: String
                    if node.shape == .plain {
                        k = node.text
                        if k == "<<" { throw outside(NSLocalizedString("merge key ('<<:')", comment: "YAML feature outside the subset"), at: node.range.lowerBound) }
                        if case .null = node.value { throw outside(String(format: NSLocalizedString("null key ('%@')", comment: "YAML feature outside the subset; %@ = the key"), k), at: node.range.lowerBound) }
                    } else if case .text(let t) = node.value { k = t } else { k = "" }
                    p += 1
                    try flowSpace(parent: n)
                    let value: YAMLNode
                    if p < b.count, b[p] == COMMA || b[p] == RBRACKET {
                        value = YAMLNode(.empty, .null, p..<p)
                    } else {
                        value = try inFlow(parent: n)
                    }
                    let pair = YAMLNode(.flowMap, .table(Table(pairs: [Table.Pair(key: k, value: value.value)])),
                                     node.range.lowerBound..<value.range.upperBound)
                    pair.members = [YAMLNode.Member(key: k, keyRange: node.range, node: value, above: [], end: nil)]
                    node = pair
                    try flowSpace(parent: n)
                }
                items.append(YAMLNode.Item(node: node, above: [], end: nil))
                values.append(node.value)
            } else {
                if b[p] == COLON, emptyAt(p + 1) || isFlowIndicator(c(p + 1)) {
                    throw outside(NSLocalizedString("empty key (': value')", comment: "YAML feature outside the subset"), at: p)
                }
                let (k, rKey, kNode) = try key(flow: true)
                try flowSpace(parent: n)
                let value: YAMLNode
                if p < b.count, b[p] == COLON,
                   emptyAt(p + 1) || isFlowIndicator(c(p + 1)) || kNode.shape != .plain {
                    p += 1
                    try flowSpace(parent: n)
                    if p < b.count, b[p] == COMMA || b[p] == RBRACE {
                        value = YAMLNode(.empty, .null, p..<p)
                    } else {
                        value = try inFlow(parent: n)
                    }
                } else {
                    // key without a value: `{a, b: 1}` has a: null
                    value = YAMLNode(.empty, .null, rKey.upperBound..<rKey.upperBound)
                }
                if let l = lineOfKey[k] {
                    throw error(String(format: NSLocalizedString("key '%@' already appeared on line %ld in this map; duplicate keys are not accepted", comment: "YAML parse error; %@ = the key, %ld = line number"), k, l), at: rKey.lowerBound)
                }
                lineOfKey[k] = line(rKey.lowerBound)
                members.append(YAMLNode.Member(key: k, keyRange: rKey, node: value, above: [], end: nil))
                table.pairs.append(Table.Pair(key: k, value: value.value))
            }
            try flowSpace(parent: n)
            guard p < b.count else { throw error(isArray ? NSLocalizedString("missing ']' to close the list", comment: "YAML parse error") : NSLocalizedString("missing '}' to close the map", comment: "YAML parse error"), at: begin) }
            if b[p] == COMMA { p += 1; continue }
            if b[p] == closes { continue }
            throw error(String(format: NSLocalizedString("expected ',' or '%@'", comment: "YAML parse error; %@ = ] or }"), isArray ? "]" : "}"), at: p)
        }
        let node = YAMLNode(isArray ? .flowSeq : .flowMap, isArray ? .array(values) : .table(table), begin..<p)
        node.items = items
        node.members = members
        return node
    }
}
