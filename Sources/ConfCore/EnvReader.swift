import Foundation

/// Reader for `.env` files that records the position (in UTF-8 bytes) of each value.
///
/// There is no official spec; the rules follow Node's and Ruby's `dotenv`, with two
/// deliberate differences (the editor would rather refuse than guess): a line that is not
/// `KEY=value`, a comment or a blank line is an error, and so is a repeated key.
///
/// - `KEY=value`, with an optional leading `export ` and spaces around the `=`.
///   Key: ASCII letters, digits, `_`, `.` and `-`.
/// - Unquoted: the value runs to the end of the line or to the first `#` (from there on
///   it is a comment); leading/trailing spaces are not part of the value.
/// - Single quotes: literal text, no escapes.
/// - Double quotes: `\n`, `\r`, `\"` and `\\` are escapes; any other backslash stays as is.
/// - Quoted values may span several lines (CRLF inside them becomes `\n`).
/// - `${VAR}` and `$VAR` are not expanded: they are text.
/// - `#` comments on their own lines right above become the field's help.
///
/// Every value is text; there are no sections (the root is a table of strings).
public enum EnvReader {
    public static func parse(_ bytes: [UInt8]) throws(ParseError) -> ConfDocument {
        var a = EnvParser(bytes)
        return try a.document()
    }

    public static func parse(_ text: String) throws(ParseError) -> ConfDocument {
        try parse(Array(text.utf8))
    }

    /// Parses a standalone value as written after the `=`: `abc`, `'abc'` or `"a\nb"`.
    public static func parseValue(_ text: String) throws(ParseError) -> Value {
        let prefix = "X="
        do throws(ParseError) {
            let doc = try parse(prefix + text)
            guard doc.entries.count == 1, let e = doc.entries.first else {
                throw ParseError(message: NSLocalizedString("the value must fit on a single line (or be quoted)", comment: "Parse error"),
                                  line: 1, column: 1, offset: 0, format: .env)
            }
            if e.trailingComment != nil {
                throw ParseError(message: NSLocalizedString("'#' starts a comment; to use it in the value, put the value in quotes", comment: "Parse error"),
                                  line: 1, column: 1, offset: 0, format: .env)
            }
            return e.value
        } catch {
            var e = error
            if e.line == 1 { e.column = max(1, e.column - prefix.count); e.offset = max(0, e.offset - prefix.utf8.count) }
            throw e
        }
    }

    /// Character allowed in a variable name.
    static func isKeyChar(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
            || c == 0x5F || c == 0x2E || c == 0x2D
    }
}

// MARK: - Constants

private let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09, SPACE: UInt8 = 0x20
private let QUOTE: UInt8 = 0x22, APOS: UInt8 = 0x27, BACKSLASH: UInt8 = 0x5C, HASH: UInt8 = 0x23
private let EQUALS: UInt8 = 0x3D

// MARK: - Parser

private struct EnvParser {
    let b: [UInt8]
    let start: Int
    var p: Int
    let lineStarts: [Int]

    init(_ bytes: [UInt8]) {
        b = bytes
        start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        p = start
        var l = [0]
        for (i, c) in bytes.enumerated() where c == LF { l.append(i + 1) }
        lineStarts = l
    }

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
        var lo = lineStarts[l]
        if l == 0 { lo = max(lo, start) }
        var col = 1
        if lo < o { for i in lo..<o where b[i] & 0xC0 != 0x80 { col += 1 } }
        return ParseError(message: msg, line: l + 1, column: col, offset: o, format: .env)
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
            return String(format: NSLocalizedString("the character 0x%02X", comment: "Parse error fragment: what was found; %02X = byte value"), c)
        }
    }

    var current: UInt8? { p < b.count ? b[p] : nil }

    mutating func skipSpaces() { while p < b.count, b[p] == SPACE || b[p] == TAB { p += 1 } }

    /// At the end of the line (LF, CRLF or end of file)?
    var atEndOfLine: Bool {
        guard p < b.count else { return true }
        return b[p] == LF || (b[p] == CR && p + 1 < b.count && b[p + 1] == LF)
    }

    /// Consumes the line break (must be at the end of the line).
    mutating func consumeNewline() throws(ParseError) {
        guard p < b.count else { return }
        if b[p] == LF { p += 1; return }
        if b[p] == CR, p + 1 < b.count, b[p + 1] == LF { p += 2; return }
        throw error(String(format: NSLocalizedString("expected end of line, found %@", comment: "Parse error; %@ = what was found"), describe(current)))
    }

    /// Text of a comment from the `#` to the end of the line, without the `#` and without leading/trailing spaces.
    mutating func comment() throws(ParseError) -> String {
        p += 1
        let lo = p
        while p < b.count, b[p] != LF, !(b[p] == CR && p + 1 < b.count && b[p + 1] == LF) {
            if b[p] == CR { throw error(NSLocalizedString("a lone CR (without LF) is not an accepted line break", comment: "Parse error")) }
            p += 1
        }
        return String(decoding: b[lo..<p], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // MARK: UTF-8

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
            else { throw error(NSLocalizedString("invalid UTF-8 (the file must be UTF-8)", comment: "Parse error"), at: i) }
            guard i + len <= n else { throw error(NSLocalizedString("invalid UTF-8 (incomplete sequence)", comment: "Parse error"), at: i) }
            for k in 1..<len {
                let d = b[i + k]
                guard d & 0xC0 == 0x80 else { throw error(NSLocalizedString("invalid UTF-8 (the file must be UTF-8)", comment: "Parse error"), at: i) }
                v = (v << 6) | UInt32(d & 0x3F)
            }
            if v < minimum || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) {
                throw error(NSLocalizedString("invalid UTF-8", comment: "Parse error"), at: i)
            }
            i += len
        }
    }

    // MARK: Document

    mutating func document() throws(ParseError) -> ConfDocument {
        try validateUTF8()
        var entries: [Entry] = []
        var root = Table()
        var lineOfKey: [String: Int] = [:]
        var above: [String] = []

        while p < b.count {
            skipSpaces()
            if atEndOfLine {
                try consumeNewline()
                above.removeAll()          // a blank line separates the comment from the variable
                continue
            }
            if b[p] == HASH {
                above.append(try comment())
                try consumeNewline()
                continue
            }
            let lineStart = p
            // leading `export ` (but `export=1` is the variable "export")
            if b[p...].starts(with: Array("export".utf8)), p + 6 < b.count, b[p + 6] == SPACE || b[p + 6] == TAB {
                p += 6
                skipSpaces()
                if !(current.map(EnvReader.isKeyChar) ?? false) { p = lineStart }
            }
            let keyStart = p
            while p < b.count, EnvReader.isKeyChar(b[p]) { p += 1 }
            guard p > keyStart else {
                throw error(String(format: NSLocalizedString("expected a variable name (letters, digits, '_', '.' or '-'), found %@", comment: "Parse error; %@ = what was found"), describe(current)))
            }
            let keyEnd = p
            let key = String(decoding: b[keyStart..<keyEnd], as: UTF8.self)
            skipSpaces()
            guard current == EQUALS else {
                if atEndOfLine { throw error(String(format: NSLocalizedString("missing '=' and the value after '%@'", comment: "Parse error; %@ = key"), key)) }
                throw error(String(format: NSLocalizedString("expected '=' after '%@', found %@", comment: "Parse error; %1$@ = key, %2$@ = what was found"), key, describe(current)))
            }
            p += 1
            let afterEquals = p
            skipSpaces()

            let value: String
            let range: Range<Int>
            var commentEnd: String?
            if let q = current, q == QUOTE || q == APOS {
                (value, range) = try quoted(q)
                skipSpaces()
                if current == HASH {
                    commentEnd = try comment()
                } else if !atEndOfLine {
                    throw error(String(format: NSLocalizedString("only a '#' comment may follow the quotes, found %@", comment: "Parse error; %@ = what was found"), describe(current)))
                }
            } else {
                let lo = p
                while p < b.count, b[p] != HASH, b[p] != LF {
                    if b[p] == CR {
                        if p + 1 < b.count, b[p + 1] == LF { break }
                        throw error(NSLocalizedString("a lone CR (without LF) is not an accepted line break", comment: "Parse error"))
                    }
                    p += 1
                }
                var end = p
                while end > lo, b[end - 1] == SPACE || b[end - 1] == TAB { end -= 1 }
                // empty value: its place is right after the '=' (before spaces and comment)
                range = end > lo ? lo..<end : afterEquals..<afterEquals
                value = String(decoding: b[lo..<end], as: UTF8.self)
                if current == HASH { commentEnd = try comment() }
            }
            let lastLine = line(range.upperBound)
            try consumeNewline()

            if let l = lineOfKey[key] {
                throw error(String(format: NSLocalizedString("the variable '%@' was already defined on line %ld; repeated keys are not accepted", comment: "Parse error; %1$@ = key, %2$ld = line"), key, l), at: keyStart)
            }
            let keyLine = line(keyStart)
            lineOfKey[key] = keyLine
            root[key] = .text(value)
            entries.append(Entry(path: [.key(key)], writtenKey: key, value: .text(value),
                                    position: Position(range: range), keyRange: keyStart..<keyEnd,
                                    line: keyLine, lastLine: lastLine,
                                    commentAbove: above, trailingComment: commentEnd, section: nil))
            above.removeAll()
        }

        var newline = "\n"
        if let i = b.firstIndex(of: LF), i > 0, b[i - 1] == CR { newline = "\r\n" }
        return ConfDocument(format: .env, bytes: b, root: .table(root), entries: entries, headers: [],
                             lineBreak: newline, hasBOM: start == 3)
    }

    /// Single-quoted (literal) or double-quoted (with escapes) value. May span several lines.
    mutating func quoted(_ q: UInt8) throws(ParseError) -> (String, Range<Int>) {
        let lo = p
        p += 1
        var s: [UInt8] = []
        while true {
            guard p < b.count else {
                throw error(q == QUOTE ? NSLocalizedString("double quote opened here and never closed", comment: "Parse error")
                                   : NSLocalizedString("single quote opened here and never closed", comment: "Parse error"),
                           at: lo)
            }
            let c = b[p]
            if c == q { p += 1; break }
            if q == QUOTE, c == BACKSLASH, p + 1 < b.count {
                switch b[p + 1] {
                case 0x6E: s.append(LF); p += 2           // \n
                case 0x72: s.append(CR); p += 2           // \r
                case QUOTE: s.append(QUOTE); p += 2         // \"
                case BACKSLASH: s.append(BACKSLASH); p += 2
                default: s.append(BACKSLASH); p += 1      // any other backslash stays as is
                }
                continue
            }
            if c == CR, p + 1 < b.count, b[p + 1] == LF {
                s.append(LF); p += 2
                continue
            }
            s.append(c)
            p += 1
        }
        return (String(decoding: s, as: UTF8.self), lo..<p)
    }
}
