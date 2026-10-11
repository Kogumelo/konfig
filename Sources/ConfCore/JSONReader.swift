import Foundation

/// Reader for JSON (RFC 8259), JSONC and JSON5 that keeps the position (in UTF-8 bytes) of each value.
///
/// JSONC is JSON with `//` and `/* */` comments and a trailing comma after the last item
/// (the dialect of `tsconfig.json` and `.vscode/settings.json`). By default the reader
/// accepts both; with `strict: true`, only plain JSON.
///
/// JSON5 (spec.json5.org, version 1.0.0) is read by `parseJSON5`: on top of JSONC, unquoted
/// keys (identifiers), single-quoted strings and line continuation
/// with `\`, `\x`, `\v`, `\0` and `\'` escapes, hexadecimal numbers, `Infinity`,
/// `NaN`, `+1`, `.5`, `5.` and more kinds of whitespace.
///
/// As in TOML, each object member becomes an `Entry` (with the value's range and the
/// comments above it and at the end of the line); nested objects and objects
/// inside arrays become sections (`SectionHeader`).
public enum JSONReader {
    /// Maximum nesting of arrays and objects. Comparing and freeing values is recursive;
    /// the limit protects the stack of secondary threads (512 KB).
    public static let maxDepth = 128

    public static func parse(_ bytes: [UInt8], strict: Bool = false) throws(ParseError) -> ConfDocument {
        try JSONParser(bytes, strict: strict, json5: false).document()
    }

    /// Reads a JSON5 file.
    public static func parseJSON5(_ bytes: [UInt8]) throws(ParseError) -> ConfDocument {
        try JSONParser(bytes, strict: false, json5: true).document()
    }

    public static func parseJSON5(_ text: String) throws(ParseError) -> ConfDocument {
        try parseJSON5(Array(text.utf8))
    }

    /// Reads a standalone JSON5 value, such as `[0x10, 'a']`.
    public static func parseValueJSON5(_ text: String) throws(ParseError) -> Value {
        try parseJSON5(Array(text.utf8)).rootValue
    }

    public static func parse(_ text: String, strict: Bool = false) throws(ParseError) -> ConfDocument {
        try parse(Array(text.utf8), strict: strict)
    }

    /// Reads a standalone value, such as `[1, 2]` or `"abc"` (comments allowed).
    public static func parseValue(_ text: String) throws(ParseError) -> Value {
        try parse(Array(text.utf8)).rootValue
    }
}

// MARK: - Constants

private let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09, SPACE: UInt8 = 0x20
private let QUOTE: UInt8 = 0x22, BACKSLASH: UInt8 = 0x5C, SLASH: UInt8 = 0x2F, STAR: UInt8 = 0x2A
private let LBRACKET: UInt8 = 0x5B, RBRACKET: UInt8 = 0x5D, LBRACE: UInt8 = 0x7B, RBRACE: UInt8 = 0x7D
private let COLON: UInt8 = 0x3A, COMMA: UInt8 = 0x2C, MINUS: UInt8 = 0x2D, DOT: UInt8 = 0x2E
private let APOS: UInt8 = 0x27, PLUS: UInt8 = 0x2B

@inline(__always) private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

private func hexDigitValue(_ c: UInt8) -> UInt32? {
    switch c {
    case 0x30...0x39: return UInt32(c - 0x30)
    case 0x41...0x46: return UInt32(c - 0x41 + 10)
    case 0x61...0x66: return UInt32(c - 0x61 + 10)
    default: return nil
    }
}

// MARK: - Tree with positions

private final class JSONNode {
    enum Kind { case scalar, array, object }

    /// An array item or object member, with the comments around it.
    struct Child {
        var node: JSONNode
        var key: String = ""
        var keyRange: Range<Int> = 0..<0
        var above: [String] = []
        var end: String?
    }

    let kind: Kind
    var value: Value = .null
    var range: Range<Int> = 0..<0
    var children: [Child] = []
    /// Comment right after `{` or `[`, on the same line.
    var preambleEnd: String?

    init(_ t: Kind) { kind = t }

    var isArrayOfObjects: Bool {
        kind == .array && !children.isEmpty && children.allSatisfy { $0.node.kind == .object }
    }

    var position: Position {
        Position(range: range, items: kind == .array ? children.map(\.node.position) : [])
    }
}

/// Comments and blank lines between two elements.
private struct Gap {
    struct Comment {
        var lines: [String]
        var start: Int
        /// Only spaces before it on the line.
        var ownLine: Bool
        /// There was a blank line before it (since the previous element or comment).
        var blankLineBefore: Bool
    }

    var comments: [Comment] = []
    var blankLineAtEnd = false

    /// Block of comments on their own lines right above the next element.
    var above: [String] {
        if blankLineAtEnd { return [] }
        var block: [String] = []
        for c in comments {
            if c.blankLineBefore || !c.ownLine { block = [] }
            if c.ownLine { block += c.lines }
        }
        return block
    }
}

// MARK: - Parser

private final class JSONParser {
    let b: [UInt8]
    let strict: Bool
    let json5: Bool
    let start: Int
    var p = 0
    var usedExtension = false

    lazy var lineStarts: [Int] = {
        var r = [0]
        for (i, c) in b.enumerated() where c == LF { r.append(i + 1) }
        return r
    }()

    var format: Format { json5 ? .json5 : .json }

    init(_ bytes: [UInt8], strict: Bool, json5: Bool) {
        b = bytes
        self.strict = strict
        self.json5 = json5
        start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
    }

    // MARK: Utilities

    @inline(__always) var current: UInt8? { p < b.count ? b[p] : nil }
    @inline(__always) func peek(_ k: Int) -> UInt8? { p + k < b.count ? b[p + k] : nil }

    func lineIndex(_ off: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if lineStarts[m] <= off { lo = m } else { hi = m - 1 }
        }
        return lo
    }

    func line(_ off: Int) -> Int { lineIndex(min(max(off, 0), b.count)) + 1 }

    func error(_ msg: String, at off: Int? = nil) -> ParseError {
        let o = min(max(off ?? p, 0), b.count)
        let l = lineIndex(o)
        var lineStart = lineStarts[l]
        if l == 0 { lineStart = max(lineStart, start) }
        var col = 1
        if lineStart < o { for i in lineStart..<o where b[i] & 0xC0 != 0x80 { col += 1 } }
        return ParseError(message: msg, line: l + 1, column: col, offset: o, format: format)
    }

    func describe(_ c: UInt8?) -> String {
        guard let c else { return NSLocalizedString("end of file", comment: "Parse error fragment: what was found") }
        switch c {
        case LF, CR: return NSLocalizedString("end of line", comment: "Parse error fragment: what was found")
        case TAB: return NSLocalizedString("tab", comment: "Parse error fragment: what was found")
        case SPACE: return NSLocalizedString("space", comment: "Parse error fragment: what was found")
        case 0x21...0x7E: return "'\(String(UnicodeScalar(c)))'"
        default:
            if c >= 0x80, let s = String(bytes: b[p...].prefix(4), encoding: .utf8)?.first { return "'\(s)'" }
            return String(format: "byte 0x%02X", c)
        }
    }

    /// Only spaces and tabs between the start of the line and `off`.
    func onlySpacesBefore(_ off: Int) -> Bool {
        var i = off
        while i > start, b[i - 1] == SPACE || b[i - 1] == TAB { i -= 1 }
        return i == start || b[i - 1] == LF || b[i - 1] == CR
    }

    func hasNewline(_ r: Range<Int>) -> Bool { r.lowerBound < r.upperBound && b[r].contains(LF) }

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
            else { throw error(NSLocalizedString("invalid UTF-8 (the file must be in UTF-8)", comment: "Parse error"), at: i) }
            guard i + len <= n else { throw error(NSLocalizedString("invalid UTF-8 (incomplete sequence)", comment: "Parse error"), at: i) }
            for k in 1..<len {
                let d = b[i + k]
                guard d & 0xC0 == 0x80 else { throw error(NSLocalizedString("invalid UTF-8 (the file must be in UTF-8)", comment: "Parse error"), at: i) }
                v = (v << 6) | UInt32(d & 0x3F)
            }
            if v < minimum || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) {
                throw error(NSLocalizedString("invalid UTF-8", comment: "Parse error"), at: i)
            }
            i += len
        }
    }

    // MARK: Whitespace and comments

    func acceptExtension(_ what: String, at off: Int) throws(ParseError) {
        if json5 { return }
        if strict {
            throw error(String(format: NSLocalizedString("%@ is not allowed in plain JSON (only in JSONC)", comment: "Parse error; %@ = the JSONC extension used (comment, trailing comma)"), what), at: off)
        }
        usedExtension = true
    }

    /// Spaces, line breaks and comments up to the next element.
    func gap() throws(ParseError) -> Gap {
        var r = Gap()
        var newlines = 0
        while let c = current {
            if c == SPACE || c == TAB { p += 1; continue }
            if c == CR {
                // JSON5 accepts a lone CR as a line break
                if json5 && peek(1) != LF { newlines += 1 }
                p += 1
                continue
            }
            if c == LF { newlines += 1; p += 1; continue }
            if json5, let e = json5Space() {
                if e.newline { newlines += 1 }
                p += e.size
                continue
            }
            guard c == SLASH, peek(1) == SLASH || peek(1) == STAR else { break }
            let begin = p
            try acceptExtension(NSLocalizedString("comment", comment: "Parse error fragment: JSONC extension"), at: begin)
            var lines: [String]
            if peek(1) == SLASH {
                p += 2
                while let d = current, d != LF, d != CR, !(json5 && unicodeSeparator(p)) { p += 1 }
                var t = b[(begin + 2)..<p]
                while t.first == SLASH { t = t.dropFirst() }
                lines = [String(decoding: t, as: UTF8.self).trimmingCharacters(in: .whitespaces)]
            } else {
                p += 2
                var end: Int? = nil
                while p + 1 < b.count {
                    if b[p] == STAR && b[p + 1] == SLASH { end = p; break }
                    p += 1
                }
                guard let f = end else { throw error(NSLocalizedString("'/*' comment without '*/'", comment: "Parse error"), at: begin) }
                p = f + 2
                lines = String(decoding: b[(begin + 2)..<f], as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { l in
                        var s = l.trimmingCharacters(in: .whitespacesAndNewlines)
                        while s.hasPrefix("*") { s.removeFirst() }
                        return s.trimmingCharacters(in: .whitespaces)
                    }
                while lines.first?.isEmpty == true { lines.removeFirst() }
                while lines.last?.isEmpty == true { lines.removeLast() }
            }
            r.comments.append(.init(lines: lines, start: begin, ownLine: onlySpacesBefore(begin),
                                       blankLineBefore: newlines >= 2))
            newlines = 0
        }
        r.blankLineAtEnd = newlines >= 2
        return r
    }

    /// U+2028 or U+2029 (line and paragraph separator) at `i`.
    func unicodeSeparator(_ i: Int) -> Bool {
        i + 2 < b.count && b[i] == 0xE2 && b[i + 1] == 0x80 && (b[i + 2] == 0xA8 || b[i + 2] == 0xA9)
    }

    /// Whitespace that only JSON5 accepts (vertical tab, form feed,
    /// U+00A0, U+FEFF, the Zs category and the U+2028/U+2029 separators), with its size in bytes.
    func json5Space() -> (size: Int, newline: Bool)? {
        guard let c = current else { return nil }
        if c == 0x0B || c == 0x0C { return (1, false) }
        guard c >= 0xC2, let (u, len) = scalar(at: p) else { return nil }
        if u.value == 0x2028 || u.value == 0x2029 { return (len, true) }
        if u.value == 0xFEFF || u.properties.generalCategory == .spaceSeparator { return (len, false) }
        return nil
    }

    /// The Unicode scalar that starts at `i` (the text has already been validated as UTF-8).
    func scalar(at i: Int) -> (Unicode.Scalar, Int)? {
        guard i < b.count else { return nil }
        let c = b[i]
        let len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4
        guard i + len <= b.count else { return nil }
        var v = UInt32(len == 1 ? c : len == 2 ? c & 0x1F : len == 3 ? c & 0x0F : c & 0x07)
        for k in 1..<len { v = (v << 6) | UInt32(b[i + k] & 0x3F) }
        return Unicode.Scalar(v).map { ($0, len) }
    }

    /// First comment on the same line where the previous element ended (at `endOfPrevious`).
    func inlineComment(_ l: Gap, afterOf endOfPrevious: Int) -> String? {
        for c in l.comments where !c.ownLine {
            if hasNewline(endOfPrevious..<c.start) { return nil }
            let t = c.lines.joined(separator: " ")
            return t.isEmpty ? nil : t
        }
        return nil
    }

    // MARK: Values

    /// Reads a complete value. Arrays and objects are read with an explicit stack (no
    /// recursion), so that deeply nested files don't overflow the thread's stack.
    func value() throws(ParseError) -> JSONNode {
        /// Open array or object, with the item (or member) being read.
        struct OpenContainer {
            var node: JSONNode
            var begin: Int
            var pending: JSONNode.Child
        }
        var stack: [OpenContainer] = []
        var done: JSONNode? = nil

        /// After `{` or `,` in an object: key, `:` and whitespace up to the value.
        func key(_ a: inout OpenContainer, _ gapInfo: Gap) throws(ParseError) {
            let kStart = p
            if current == QUOTE || (json5 && current == APOS) {
                a.pending.key = try text()
            } else if json5 {
                a.pending.key = try identifier()
            } else {
                throw error(current == APOS ? NSLocalizedString("single-quoted key is not JSON; use double quotes", comment: "Parse error")
                           : String(format: NSLocalizedString("expected a quoted key, found %@", comment: "Parse error; %@ = what was found"), describe(current)))
            }
            a.pending.keyRange = kStart..<p
            a.pending.above = gapInfo.above
            _ = try gap()
            guard current == COLON else { throw error(String(format: NSLocalizedString("expected ':' after the key, found %@", comment: "Parse error; %@ = what was found"), describe(current))) }
            p += 1
            _ = try gap()
        }

        func closes(_ a: OpenContainer) -> JSONNode {
            let n = a.node
            n.range = a.begin..<p
            if n.kind == .object {
                // repeated key: the last one wins (as in JavaScript), at the position of the first
                var t = Table()
                for f in n.children { t[f.key] = f.node.value }
                n.value = .table(t)
            } else {
                n.value = .array(n.children.map(\.node.value))
            }
            return n
        }

        while true {
            if let doneOne = done {
                // a value ended: it goes into the top of the stack, or it is the result
                guard var a = stack.popLast() else { return doneOne }
                let object = a.node.kind == .object
                let closing = object ? RBRACE : RBRACKET
                var f = a.pending
                f.node = doneOne
                let valueEnd = doneOne.range.upperBound
                let after = try gap()
                f.end = inlineComment(after, afterOf: valueEnd)
                if current == COMMA {
                    let v = p
                    p += 1
                    let gapInfo = try gap()
                    if f.end == nil { f.end = inlineComment(gapInfo, afterOf: valueEnd) }
                    a.node.children.append(f)
                    if current == closing {
                        try acceptExtension(NSLocalizedString("trailing comma after the last item", comment: "Parse error fragment: JSONC extension"), at: v)
                        p += 1
                        done = closes(a)
                        continue
                    }
                    a.pending = JSONNode.Child(node: a.node)
                    if object { try key(&a, gapInfo) } else { a.pending.above = gapInfo.above }
                    stack.append(a)
                    done = nil
                    continue
                }
                a.node.children.append(f)
                if current == closing {
                    p += 1
                    done = closes(a)
                    continue
                }
                throw error(String(format: NSLocalizedString("expected ',' or '%@', found %@", comment: "Parse error; first %@ = closing bracket, second %@ = what was found"), object ? "}" : "]", describe(current)))
            }

            guard let c = current else { throw error(String(format: NSLocalizedString("expected a value, found %@", comment: "Parse error; %@ = what was found"), describe(nil))) }
            switch c {
            case LBRACE, LBRACKET:
                guard stack.count < JSONReader.maxDepth else {
                    throw error(String(format: NSLocalizedString("nesting too deep (more than %ld levels)", comment: "Parse error; %ld = maximum depth"), JSONReader.maxDepth))
                }
                let object = c == LBRACE
                let n = JSONNode(object ? .object : .array)
                var a = OpenContainer(node: n, begin: p, pending: JSONNode.Child(node: n))
                p += 1
                let gapInfo = try gap()
                n.preambleEnd = inlineComment(gapInfo, afterOf: a.begin + 1)
                if current == (object ? RBRACE : RBRACKET) {
                    p += 1
                    done = closes(a)
                    continue
                }
                if object { try key(&a, gapInfo) } else { a.pending.above = gapInfo.above }
                stack.append(a)
            case QUOTE:
                let n = JSONNode(.scalar)
                let begin = p
                n.value = .text(try text())
                n.range = begin..<p
                done = n
            case APOS where json5:
                let n = JSONNode(.scalar)
                let begin = p
                n.value = .text(try text())
                n.range = begin..<p
                done = n
            case MINUS, 0x30...0x39: done = json5 ? try numberJSON5() : try number()
            case PLUS where json5, DOT where json5, 0x49 where json5, 0x4E where json5:
                done = try numberJSON5()
            case 0x74: done = try literal("true", .boolean(true))
            case 0x66: done = try literal("false", .boolean(false))
            case 0x6E: done = try literal("null", .null)
            case APOS: throw error(NSLocalizedString("single-quoted string is not JSON; use double quotes", comment: "Parse error"))
            default: throw error(String(format: NSLocalizedString("expected a value, found %@", comment: "Parse error; %@ = what was found"), describe(c)))
            }
        }
    }

    func literal(_ word: String, _ v: Value) throws(ParseError) -> JSONNode {
        let begin = p
        for u in word.utf8 {
            guard current == u else { throw error(String(format: NSLocalizedString("invalid value; expected '%@'", comment: "Parse error; %@ = literal such as true"), word), at: begin) }
            p += 1
        }
        let n = JSONNode(.scalar)
        n.value = v
        n.range = begin..<p
        return n
    }

    func number() throws(ParseError) -> JSONNode {
        let begin = p
        if current == MINUS { p += 1 }
        guard let c = current, isDigit(c) else { throw error(NSLocalizedString("invalid number: missing digit", comment: "Parse error"), at: begin) }
        p += 1
        if c == 0x30 {
            if let d = current, isDigit(d) { throw error(NSLocalizedString("number with a leading zero is not JSON", comment: "Parse error"), at: begin) }
        } else {
            while let d = current, isDigit(d) { p += 1 }
        }
        var integer = true
        if current == DOT {
            p += 1
            guard let d = current, isDigit(d) else { throw error(NSLocalizedString("invalid number: missing digit after the point", comment: "Parse error")) }
            while let d = current, isDigit(d) { p += 1 }
            integer = false
        }
        if current == 0x65 || current == 0x45 {
            p += 1
            if current == 0x2B || current == MINUS { p += 1 }
            guard let d = current, isDigit(d) else { throw error(NSLocalizedString("invalid number: missing digit in the exponent", comment: "Parse error")) }
            while let d = current, isDigit(d) { p += 1 }
            integer = false
        }
        let t = String(decoding: b[begin..<p], as: UTF8.self)
        let n = JSONNode(.scalar)
        n.range = begin..<p
        // An integer that doesn't fit in 64 bits stays a decimal (approximate; only changes if edited).
        if integer, let x = Int64(t) { n.value = .integer(x) } else { n.value = .decimal(Double(t) ?? .nan) }
        return n
    }

    /// JSON5 number: optional `+` or `-` sign; `Infinity`, `NaN`, hexadecimal `0x…`
    /// or decimal with `.5` and `5.` allowed. A leading zero (`010`) is rejected, as in JSON.
    func numberJSON5() throws(ParseError) -> JSONNode {
        let begin = p
        var negative = false
        if current == PLUS || current == MINUS { negative = current == MINUS; p += 1 }
        let n = JSONNode(.scalar)
        func word(_ w: String, _ v: Double) throws(ParseError) -> JSONNode {
            for u in w.utf8 {
                guard current == u else { throw error(String(format: NSLocalizedString("invalid number; expected '%@'", comment: "Parse error; %@ = Infinity or NaN"), w), at: begin) }
                p += 1
            }
            n.value = .decimal(negative ? -v : v)
            n.range = begin..<p
            return n
        }
        if current == 0x49 { return try word("Infinity", .infinity) }
        if current == 0x4E { return try word("NaN", .nan) }
        if current == 0x30, peek(1) == 0x78 || peek(1) == 0x58 {
            p += 2
            var mag: UInt64 = 0, large = false, approx = 0.0
            let digStart = p
            while let c = current, let h = hexDigitValue(c) {
                approx = approx * 16 + Double(h)
                if mag > (UInt64.max >> 4) { large = true } else { mag = mag << 4 | UInt64(h) }
                p += 1
            }
            guard p > digStart else { throw error(NSLocalizedString("hexadecimal number without digits", comment: "Parse error"), at: begin) }
            n.range = begin..<p
            if !large, !negative, mag <= UInt64(Int64.max) { n.value = .integer(Int64(mag)) }
            else if !large, negative, mag <= UInt64(Int64.max) + 1 { n.value = .integer(mag == UInt64(Int64.max) + 1 ? .min : -Int64(mag)) }
            // doesn't fit in 64 bits: approximate decimal, as in JSON
            else { n.value = .decimal(negative ? -approx : approx) }
            return n
        }
        var whole = "", fraction = "", exponent = ""
        if let c = current, isDigit(c) {
            let digStart = p
            p += 1
            if c == 0x30 {
                if let d = current, isDigit(d) { throw error(NSLocalizedString("number with a leading zero is not JSON5", comment: "Parse error"), at: begin) }
            } else {
                while let d = current, isDigit(d) { p += 1 }
            }
            whole = String(decoding: b[digStart..<p], as: UTF8.self)
        }
        var integer = true
        if current == DOT {
            p += 1
            let digStart = p
            while let d = current, isDigit(d) { p += 1 }
            fraction = String(decoding: b[digStart..<p], as: UTF8.self)
            integer = false
        }
        guard !whole.isEmpty || !fraction.isEmpty else { throw error(NSLocalizedString("invalid number: missing digit", comment: "Parse error"), at: begin) }
        if current == 0x65 || current == 0x45 {
            let expStart = p
            p += 1
            if current == PLUS || current == MINUS { p += 1 }
            guard let d = current, isDigit(d) else { throw error(NSLocalizedString("invalid number: missing digit in the exponent", comment: "Parse error")) }
            while let d = current, isDigit(d) { p += 1 }
            exponent = String(decoding: b[(expStart + 1)..<p], as: UTF8.self)
            integer = false
        }
        n.range = begin..<p
        let signText = negative ? "-" : ""
        if integer, let x = Int64(signText + whole) { n.value = .integer(x); return n }
        let t = signText + (whole.isEmpty ? "0" : whole) + "." + (fraction.isEmpty ? "0" : fraction)
            + (exponent.isEmpty ? "" : "e" + exponent)
        n.value = .decimal(Double(t) ?? .nan)
        return n
    }

    /// Unquoted JSON5 key: an ECMAScript 5.1 identifier (letters, `$`, `_`,
    /// digits and marks after the first character; `\uXXXX` escapes allowed).
    func identifier() throws(ParseError) -> String {
        let begin = p
        var r = String.UnicodeScalarView()
        func beginning(_ u: Unicode.Scalar) -> Bool {
            if u == "$" || u == "_" { return true }
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .letterNumber:
                return true
            default: return false
            }
        }
        func part(_ u: Unicode.Scalar) -> Bool {
            if beginning(u) || u.value == 0x200C || u.value == 0x200D { return true }
            switch u.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .decimalNumber, .connectorPunctuation: return true
            default: return false
            }
        }
        while p < b.count {
            let u: Unicode.Scalar, len: Int
            if b[p] == BACKSLASH {
                let esc = p
                guard peek(1) == 0x75 else { throw error(NSLocalizedString("in an unquoted key, only the \\uXXXX escape is allowed", comment: "Parse error"), at: esc) }
                p += 2
                let v = try hex4(esc)
                p = esc
                guard let x = Unicode.Scalar(v), r.isEmpty ? beginning(x) : part(x) else {
                    throw error(NSLocalizedString("\\u escape that does not form an identifier in an unquoted key", comment: "Parse error"), at: esc)
                }
                u = x; len = 6
            } else {
                guard let (x, t) = scalar(at: p), r.isEmpty ? beginning(x) : part(x) else { break }
                u = x; len = t
            }
            r.append(u)
            p += len
        }
        if r.isEmpty {
            throw error(String(format: NSLocalizedString("invalid key: use quotes or an identifier (letters, digits, _ and $; cannot start with a digit), found %@", comment: "Parse error; %@ = what was found"), describe(current)), at: begin)
        }
        return String(r)
    }

    /// Quoted string (the cursor is on the opening quote: `"`, or `'` in JSON5).
    func text() throws(ParseError) -> String {
        let begin = p
        let quote = b[p]
        p += 1
        var r: [UInt8] = []
        func put(_ v: UInt32) {
            let u = UnicodeScalar(v)!
            r.append(contentsOf: Array(String(Character(u)).utf8))
        }
        while true {
            guard let c = current else { throw error(NSLocalizedString("string without a closing quote", comment: "Parse error"), at: begin) }
            if c == quote { p += 1; break }
            if c == LF || c == CR {
                throw error(json5 ? NSLocalizedString("line break inside a string; use \\n or \\ at the end of the line", comment: "Parse error")
                           : NSLocalizedString("line break inside a string; use \\n", comment: "Parse error"))
            }
            if c < 0x20 && !json5 {
                throw error(NSLocalizedString("control character inside a string; use an escape such as \\t or \\u00XX", comment: "Parse error"))
            }
            if c != BACKSLASH { r.append(c); p += 1; continue }
            let esc = p
            guard let e = peek(1) else { throw error(NSLocalizedString("string without a closing quote", comment: "Parse error"), at: begin) }
            p += 2
            switch e {
            case QUOTE: r.append(QUOTE)
            case BACKSLASH: r.append(BACKSLASH)
            case SLASH: r.append(SLASH)
            case 0x62: r.append(0x08)
            case 0x66: r.append(0x0C)
            case 0x6E: r.append(LF)
            case 0x72: r.append(CR)
            case 0x74: r.append(TAB)
            case 0x75:
                let high = try hex4(esc)
                if high >= 0xD800 && high <= 0xDBFF {
                    guard current == BACKSLASH, peek(1) == 0x75 else {
                        throw error(NSLocalizedString("\\u escape of a high surrogate without the low pair", comment: "Parse error"), at: esc)
                    }
                    let esc2 = p
                    p += 2
                    let low = try hex4(esc2)
                    guard low >= 0xDC00 && low <= 0xDFFF else {
                        throw error(NSLocalizedString("\\u escape of a high surrogate followed by something that is not the low pair", comment: "Parse error"), at: esc2)
                    }
                    put(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
                } else if high >= 0xDC00 && high <= 0xDFFF {
                    throw error(NSLocalizedString("lone \\u escape of a low surrogate", comment: "Parse error"), at: esc)
                } else {
                    put(high)
                }
            case APOS where json5: r.append(APOS)
            case 0x76 where json5: r.append(0x0B)
            case 0x30 where json5:
                if let d = current, isDigit(d) { throw error(NSLocalizedString("\\0 escape followed by a digit is not JSON5", comment: "Parse error"), at: esc) }
                r.append(0)
            case 0x78 where json5:
                var v: UInt32 = 0
                for _ in 0..<2 {
                    guard let c = current, let h = hexDigitValue(c) else { throw error(NSLocalizedString("\\x escape needs 2 hexadecimal digits", comment: "Parse error"), at: esc) }
                    v = v << 4 | h
                    p += 1
                }
                put(v)
            case LF where json5: break                                  // line continuation
            case CR where json5: if current == LF { p += 1 }              // continuation with CRLF or CR
            case 0x31...0x39 where json5:
                throw error(String(format: NSLocalizedString("escape '\\%@' is not allowed in JSON5", comment: "Parse error; %@ = escaped character"), String(UnicodeScalar(e))), at: esc)
            default:
                guard json5 else { throw error(String(format: NSLocalizedString("invalid escape '\\%@'", comment: "Parse error; %@ = escaped character"), String(UnicodeScalar(e))), at: esc) }
                // any other escaped character stands for itself; U+2028/U+2029 are line continuations
                if unicodeSeparator(esc + 1) { p += 2; break }
                r.append(e)
                while let d = current, d & 0xC0 == 0x80 { r.append(d); p += 1 }
            }
        }
        return String(decoding: r, as: UTF8.self)
    }

    func hex4(_ esc: Int) throws(ParseError) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard let c = current, let h = hexDigitValue(c) else { throw error(NSLocalizedString("\\u escape needs 4 hexadecimal digits", comment: "Parse error"), at: esc) }
            v = v << 4 | h
            p += 1
        }
        return v
    }

    // MARK: Document

    var entries: [Entry] = []
    var headers: [SectionHeader] = []

    func document() throws(ParseError) -> ConfDocument {
        try validateUTF8()
        p = start
        let before = try gap()
        guard current != nil else { throw error(String(format: NSLocalizedString("file without a %@ value", comment: "Parse error; %@ = format name (JSON, JSON5)"), format.name)) }
        let root = try value()
        _ = try gap()
        if current != nil { throw error(String(format: NSLocalizedString("text after the end of the %@ value: %@", comment: "Parse error; first %@ = format name, second %@ = what was found"), format.name, describe(current))) }

        switch root.kind {
        case .object:
            walk(root, path: [], names: [], section: nil)
        case .array where root.isArrayOfObjects:
            arrayItems(root, path: [], names: [], aboveArray: before.above, endOfArray: nil)
        default:
            let r = root.range
            entries.append(Entry(path: [], writtenKey: NSLocalizedString("(root)", comment: "Label of a document whose root is a single value"), value: root.value, position: root.position,
                                    keyRange: r.lowerBound..<r.lowerBound, line: line(r.lowerBound),
                                    lastLine: line(r.upperBound - 1), commentAbove: before.above,
                                    trailingComment: root.preambleEnd, section: nil))
        }
        var newline = "\n"
        if let i = b.firstIndex(of: LF) {
            if i > 0, b[i - 1] == CR { newline = "\r\n" }
        } else if b.contains(CR) {
            newline = "\r"
        }
        return ConfDocument(format: format, bytes: b, root: root.value, entries: entries, headers: headers,
                             lineBreak: newline, hasBOM: start == 3, usesJSONCExtensions: usedExtension)
    }

    /// Members of an object: simple values become entries; objects and arrays of objects, sections.
    func walk(_ obj: JSONNode, path: ValuePath, names: [String], section: Int?) {
        // with a repeated key, only the last occurrence counts (and is editable)
        var lastIndexByKey: [[UInt32]: Int] = [:]
        for (i, f) in obj.children.enumerated() { lastIndexByKey[f.key.unicodeScalars.map(\.value)] = i }
        for (i, f) in obj.children.enumerated() where lastIndexByKey[f.key.unicodeScalars.map(\.value)] == i {
            let pathSoFar = path + [.key(f.key)]
            if f.node.kind == .object {
                let idx = headers.count
                headers.append(SectionHeader(path: pathSoFar, names: names + [f.key], isArrayOfTables: false,
                                            range: f.node.range, line: line(f.keyRange.lowerBound),
                                            commentAbove: f.above, trailingComment: f.end ?? f.node.preambleEnd))
                walk(f.node, path: pathSoFar, names: names + [f.key], section: idx)
            } else if f.node.isArrayOfObjects {
                arrayItems(f.node, path: pathSoFar, names: names + [f.key], aboveArray: f.above,
                             endOfArray: f.node.preambleEnd ?? f.end)
            } else {
                entries.append(Entry(path: pathSoFar, writtenKey: f.key, value: f.node.value, position: f.node.position,
                                        keyRange: f.keyRange, line: line(f.keyRange.lowerBound),
                                        lastLine: line(f.node.range.upperBound - 1), commentAbove: f.above,
                                        trailingComment: f.end, section: section))
            }
        }
    }

    /// Each object in an array of objects becomes a section, like an item of a TOML `[[array]]`.
    func arrayItems(_ l: JSONNode, path: ValuePath, names: [String], aboveArray: [String], endOfArray: String?) {
        let ofArray = aboveArray + [endOfArray].compactMap { $0 }
        for (j, item) in l.children.enumerated() {
            let pathSoFar = path + [.index(j)]
            let idx = headers.count
            let end = [item.end, item.node.preambleEnd].compactMap { $0 }.joined(separator: "\n")
            headers.append(SectionHeader(path: pathSoFar, names: names, isArrayOfTables: true, range: item.node.range,
                                        line: line(item.node.range.lowerBound),
                                        commentAbove: ofArray + item.above, trailingComment: end.isEmpty ? nil : end))
            walk(item.node, path: pathSoFar, names: names, section: idx)
        }
    }
}
