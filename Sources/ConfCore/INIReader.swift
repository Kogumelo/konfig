import Foundation

/// Reader for INI files that records the position (in UTF-8 bytes) of each value.
///
/// INI has no spec; this is the accepted dialect (details and rationale in the README):
///
/// - Line comment: `;` or `#` at the start (leading spaces are allowed).
/// - Section: `[name]`, name without leading/trailing spaces; dots are literal (`[a.b]`
///   is not a subsection). The name runs to the first `]` followed only by spaces and
///   an optional comment: `[*.[ch]]` (EditorConfig) is the section `*.[ch]`.
///   A repeated section continues the first one.
/// - Pair: `key = value` or `key: value` (the first `=` or `:` on the line wins).
/// - Unquoted value: leading/trailing spaces are not part of it; `;` or `#` after a
///   space or tab starts a comment (`url = http://x/#a` stays whole).
///   `;` right at the start of the value is a comment; `#` at the start is value (php.ini's `#DD0000`).
/// - Double- or single-quoted value, no escapes, on a single line; after the
///   quotes, only spaces and an optional comment.
/// - Every value is text.
/// - `key[] = value` on several lines forms an array (PHP style). So do repeated
///   `extension` and `zend_extension` (PHP loads one extension per line).
///   Any other key repeated in the same section is an error, so the wrong occurrence is never edited.
/// - A line that is not a section, pair, comment or blank line is an error.
///
/// Keys before the first section go in the "General" section: in the structure, under the
/// root key `""` (no section can have an empty name, so there is no collision).
public enum INIReader {
    public static func parse(_ bytes: [UInt8]) throws(ParseError) -> ConfDocument {
        var a = INIParser(bytes)
        return try a.document()
    }

    public static func parse(_ text: String) throws(ParseError) -> ConfDocument {
        try parse(Array(text.utf8))
    }

    /// Parses a standalone value as written after the `=`: `abc`, `'a;b'` or `"x y"`.
    public static func parseValue(_ text: String) throws(ParseError) -> Value {
        let prefix = "x="
        do throws(ParseError) {
            let doc = try parse(prefix + text)
            guard doc.entries.count == 1, let e = doc.entries.first else {
                throw ParseError(message: NSLocalizedString("the value must fit on a single line", comment: "Parse error"),
                                  line: 1, column: 1, offset: 0, format: .ini)
            }
            if e.trailingComment != nil {
                throw ParseError(message: NSLocalizedString("';' or '#' after a space starts a comment; to use it in the value, put the value in quotes", comment: "Parse error"),
                                  line: 1, column: 1, offset: 0, format: .ini)
            }
            return e.value
        } catch {
            var e = error
            if e.line == 1 { e.column = max(1, e.column - prefix.count); e.offset = max(0, e.offset - prefix.utf8.count) }
            throw e
        }
    }

    /// Keys PHP accepts repeated, one per line, without `[]`: they become an array.
    public static let repeatableKeys: Set<String> = ["extension", "zend_extension"]
}

// MARK: - Constants

private let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09, SPACE: UInt8 = 0x20
private let QUOTE: UInt8 = 0x22, APOS: UInt8 = 0x27, SEMICOLON: UInt8 = 0x3B, HASH: UInt8 = 0x23
private let EQUALS: UInt8 = 0x3D, COLON: UInt8 = 0x3A, LBRACKET: UInt8 = 0x5B, RBRACKET: UInt8 = 0x5D

@inline(__always) private func isSpace(_ c: UInt8) -> Bool { c == SPACE || c == TAB }
@inline(__always) private func isComment(_ c: UInt8) -> Bool { c == SEMICOLON || c == HASH }

// MARK: - Parser

private struct INIParser {
    let b: [UInt8]
    let start: Int
    let lineStarts: [Int]

    init(_ bytes: [UInt8]) {
        b = bytes
        start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
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

    func error(_ msg: String, at off: Int) -> ParseError {
        let o = min(max(off, 0), b.count)
        let l = lineIndex(o)
        var lo = lineStarts[l]
        if l == 0 { lo = max(lo, start) }
        var col = 1
        if lo < o { for i in lo..<o where b[i] & 0xC0 != 0x80 { col += 1 } }
        return ParseError(message: msg, line: l + 1, column: col, offset: o, format: .ini)
    }

    func text(_ r: Range<Int>) -> String { String(decoding: b[r], as: UTF8.self) }

    /// Range without leading/trailing spaces and tabs.
    func trimmedRange(_ r: Range<Int>) -> Range<Int> {
        var i = r.lowerBound, e = r.upperBound
        while i < e, isSpace(b[i]) { i += 1 }
        while e > i, isSpace(b[e - 1]) { e -= 1 }
        return i..<e
    }

    /// Text of a comment from its marker (`;` or `#`): without the repeated leading
    /// markers (`;;;;`) and without leading/trailing spaces.
    func comment(_ r: Range<Int>) -> String {
        var i = r.lowerBound
        let mark = b[i]
        while i < r.upperBound, b[i] == mark { i += 1 }
        return text(i..<r.upperBound).trimmingCharacters(in: .whitespaces)
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

    /// A section in the structure: index into `headers` (`nil` = General) and its pairs, in order.
    struct ParsedSection {
        var header: Int?
        var name: String
        var table = Table()
        /// Line of the first occurrence of each key (for the repeated-key message).
        var lineOfKey: [String: Int] = [:]
        /// Array key → index into `entries`.
        var arrays: [String: Int] = [:]
    }

    mutating func document() throws(ParseError) -> ConfDocument {
        try validateUTF8()
        var entries: [Entry] = []
        var headers: [SectionHeader] = []
        var sections: [ParsedSection] = [ParsedSection(header: nil, name: "")]
        var sectionByName: [String: Int] = [:]
        var current = 0
        var above: [String] = []

        var p = start
        while p < b.count {
            // line bounds: [p, end) without the break; `next` is the start of the following line
            var end = p
            while end < b.count, b[end] != LF {
                if b[end] == CR, !(end + 1 < b.count && b[end + 1] == LF) {
                    throw error(NSLocalizedString("a lone CR (without LF) is not an accepted line break", comment: "Parse error"), at: end)
                }
                end += 1
            }
            let next = end < b.count ? end + 1 : end
            if end > p, b[end - 1] == CR { end -= 1 }
            defer { p = next }

            var i = p
            while i < end, isSpace(b[i]) { i += 1 }
            if i == end {
                above.removeAll()          // a blank line separates the comment from the key
                continue
            }
            if isComment(b[i]) {
                above.append(comment(i..<end))
                continue
            }
            let lineNumber = line(p)

            if b[i] == LBRACKET {
                // closing `]`: the first one followed only by spaces and an optional comment
                var closes: Int? = nil
                var commentEnd: String? = nil
                var k = i + 1
                while k < end {
                    if b[k] == RBRACKET {
                        var j = k + 1
                        while j < end, isSpace(b[j]) { j += 1 }
                        if j == end { closes = k; break }
                        if isComment(b[j]) { closes = k; commentEnd = comment(j..<end); break }
                    }
                    k += 1
                }
                guard let close = closes else {
                    throw error(NSLocalizedString("section without ']' at the end (only a ';' or '#' comment may follow the ']')", comment: "Parse error"), at: i)
                }
                let nameRange = trimmedRange((i + 1)..<close)
                guard !nameRange.isEmpty else { throw error(NSLocalizedString("section without a name", comment: "Parse error"), at: i) }
                let name = text(nameRange)
                if let s = sectionByName[name] {
                    current = s                 // repeated section: continues the first one
                } else {
                    headers.append(SectionHeader(path: [.key(name)], names: [name], isArrayOfTables: false,
                                                range: i..<(close + 1), line: lineNumber,
                                                commentAbove: above, trailingComment: commentEnd))
                    sections.append(ParsedSection(header: headers.count - 1, name: name))
                    current = sections.count - 1
                    sectionByName[name] = current
                }
                above.removeAll()
                continue
            }

            // pair: key up to the first '=' or ':'
            var sep = i
            while sep < end, b[sep] != EQUALS, b[sep] != COLON { sep += 1 }
            guard sep < end else {
                throw error(NSLocalizedString("the line is not a section ([name]), a pair (key = value) or a comment (; or #)", comment: "Parse error"), at: i)
            }
            let rawKeyRange = trimmedRange(i..<sep)
            guard !rawKeyRange.isEmpty else {
                throw error(String(format: NSLocalizedString("missing key name before '%@'", comment: "Parse error; %@ = separator"), String(UnicodeScalar(b[sep]))), at: sep)
            }
            var key = text(rawKeyRange)
            let isPHPArray = key.hasSuffix("[]")
            if isPHPArray {
                key = String(key.dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                guard !key.isEmpty else { throw error(NSLocalizedString("missing array name before '[]'", comment: "Parse error"), at: rawKeyRange.lowerBound) }
                key += "[]"
            }

            // value
            let afterSep = sep + 1
            var v = afterSep
            while v < end, isSpace(b[v]) { v += 1 }
            let value: String
            let range: Range<Int>
            var commentEnd: String? = nil
            if v < end, b[v] == QUOTE || b[v] == APOS {
                let q = b[v]
                var close = v + 1
                while close < end, b[close] != q { close += 1 }
                guard close < end else {
                    throw error(q == QUOTE ? NSLocalizedString("double quote opened here and not closed on the same line", comment: "Parse error")
                                         : NSLocalizedString("single quote opened here and not closed on the same line", comment: "Parse error"), at: v)
                }
                value = text((v + 1)..<close)
                range = v..<(close + 1)
                var j = close + 1
                while j < end, isSpace(b[j]) { j += 1 }
                if j < end {
                    guard isComment(b[j]) else {
                        throw error(NSLocalizedString("only a ';' or '#' comment may follow the quotes", comment: "Parse error"), at: j)
                    }
                    commentEnd = comment(j..<end)
                }
            } else {
                var c = end
                if v < end, b[v] == SEMICOLON {
                    c = v
                } else if v < end {
                    var j = v + 1
                    while j < end {
                        if isComment(b[j]), isSpace(b[j - 1]) { c = j; break }
                        j += 1
                    }
                }
                let r = trimmedRange(v..<c)
                // empty value: its place is right after the separator
                range = r.isEmpty ? afterSep..<afterSep : r
                value = text(r)
                if c < end { commentEnd = comment(c..<end) }
            }

            // repeated key, array
            var s = sections[current]
            let isArray = isPHPArray || INIReader.repeatableKeys.contains(key)
            if isArray, let entryIndex = s.arrays[key] {
                var e = entries[entryIndex]
                guard case .array(var items) = e.value else { continue }
                items.append(.text(value))
                e.value = .array(items)
                e.position.items.append(Position(range: range))
                e.position.range = e.position.range.lowerBound..<end
                e.lastLine = lineNumber
                entries[entryIndex] = e
                s.table[key] = e.value
            } else {
                // `x` and `x[]` collide too: PHP would keep only one of them
                let baseName = isPHPArray ? String(key.dropLast(2)) : key
                if let l = s.lineOfKey[baseName] {
                    let message = s.header == nil
                        ? String(format: NSLocalizedString("the key '%@' already appeared on line %ld before the first section; repeated keys are not accepted (for an array, use '%@[]' on every line)", comment: "Parse error; %1$@ = key, %2$ld = line, %3$@ = key"), baseName, l, baseName)
                        : String(format: NSLocalizedString("the key '%@' already appeared on line %ld in section [%@]; repeated keys are not accepted (for an array, use '%@[]' on every line)", comment: "Parse error; %1$@ = key, %2$ld = line, %3$@ = section, %4$@ = key"), baseName, l, s.name, baseName)
                    throw error(message, at: rawKeyRange.lowerBound)
                }
                let path: ValuePath = [.key(s.name), .key(key)]
                let entry: Entry
                if isArray {
                    // the array spans the items' whole lines: that way lines can be added and removed
                    entry = Entry(path: path, writtenKey: key, value: .array([.text(value)]),
                                      position: Position(range: p..<end, items: [Position(range: range)]),
                                      keyRange: rawKeyRange, line: lineNumber, lastLine: lineNumber,
                                      commentAbove: above, trailingComment: commentEnd, section: s.header)
                    s.arrays[key] = entries.count
                } else {
                    entry = Entry(path: path, writtenKey: key, value: .text(value),
                                      position: Position(range: range), keyRange: rawKeyRange,
                                      line: lineNumber, lastLine: lineNumber,
                                      commentAbove: above, trailingComment: commentEnd, section: s.header)
                }
                s.lineOfKey[baseName] = lineNumber
                s.table[key] = entry.value
                entries.append(entry)
            }
            sections[current] = s
            above.removeAll()
        }

        var root = Table()
        for s in sections where s.header != nil || !s.table.pairs.isEmpty {
            root[s.name] = .table(s.table)
        }
        var newline = "\n"
        if let i = b.firstIndex(of: LF), i > 0, b[i - 1] == CR { newline = "\r\n" }
        return ConfDocument(format: .ini, bytes: b, root: .table(root), entries: entries, headers: headers,
                             lineBreak: newline, hasBOM: start == 3)
    }
}
