import Foundation

/// Writes YAML values imitating the style of the old value.
///
/// - Text: unquoted stays unquoted when it fits (`fitsUnquoted`); single quotes
///   stay single (no line breaks or control characters); double quotes stay double;
///   a `|`/`>` block stays a block, with the same indentation and the chomping indicator
///   (`-`, `+`) the new text calls for. When the style doesn't fit, double quotes.
/// - **Protective quotes**: a text that a YAML 1.1 reader (PyYAML, Go's `yaml` v2,
///   Ruby…) would take as yes/no, number, date or null (`no`, `on`, `1e3`, `010`,
///   `2024-01-01`, `null`…) goes in quotes, even if in YAML 1.2 it is already text.
/// - Number: integer in the same base (`0x`, `0o`) and with the `+`; decimal with exponent and
///   digits like the original; `.inf`/`.nan` in the same case. Booleans and null also in the same case.
/// - Block sequence: changed items are replaced in place; an extra item is a new line
///   (`- value`) after the last one, with its indentation; a removed item is its line taken out.
/// - Flow sequence (`[a, b]`): as in TOML and JSON (`TOMLFormat.array`).
public enum YAMLFormat {
    public static func value(_ v: Value, old: Value? = nil, position: Position? = nil, source: [UInt8] = [],
                             newline: String = "\n") -> String {
        let r = write(v, old: old, position: position, source: source, newline: newline, flow: false)
        if let pos = position, pos.range.isEmpty, !r.isEmpty { return emptyPrefix(pos.range.lowerBound, source) + r }
        return r
    }

    /// Raw text of a field, adjusted to its place: a space after an empty `key:` and, in a
    /// block sequence (which starts at the beginning of the line), the first line's indentation.
    public static func raw(_ s: String, position: Position, source: [UInt8]) -> String {
        let iv = position.range
        if iv.isEmpty {
            if !s.isEmpty, !s.hasPrefix(" ") { return emptyPrefix(iv.lowerBound, source) + s }
            return s
        }
        if iv.lowerBound == 0 || source[iv.lowerBound - 1] == 0x0A, source[iv.lowerBound] == 0x20, !s.hasPrefix(" ") {
            let indent = source[iv].prefix { $0 == 0x20 }.count
            return String(repeating: " ", count: indent) + s
        }
        return s
    }

    /// What goes before a value written in the empty spot of a null value: a space after
    /// `key:`, `-` and `---`; `: ` after a key without a value inside `{ }` (`{a, b}`).
    static func emptyPrefix(_ off: Int, _ source: [UInt8]) -> String {
        guard off > 0, off <= source.count else { return "" }
        switch source[off - 1] {
        case 0x3A, 0x2D, 0x3F: return " "
        case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5B, 0x7B: return ""
        default: return ": "
        }
    }

    /// Indentation of the map or sequence containing the value that starts at `off` (the key's
    /// column in `key: |`, the `-`'s in `- |`; −1 at the root). Used with the indentation indicator (`|2`).
    static func parentIndent(_ off: Int, _ source: [UInt8]) -> Int {
        var ls = off
        while ls > 0, source[ls - 1] != 0x0A { ls -= 1 }
        var i = ls
        if source[i...].starts(with: [0xEF, 0xBB, 0xBF]) { i += 3 }
        let base = i
        while i < off, source[i] == 0x20 { i += 1 }
        if source[i..<off].starts(with: Array("---".utf8)) { return -1 }
        var dash = -1
        while i < off, source[i] == 0x2D, i + 1 < source.count, source[i + 1] == 0x20 || source[i + 1] == 0x09 {
            dash = i - base
            i += 1
            while i < off, source[i] == 0x20 || source[i] == 0x09 { i += 1 }
        }
        return i == off ? dash : i - base
    }

    static func write(_ v: Value, old: Value?, position: Position?, source: [UInt8], newline: String,
                         flow: Bool) -> String {
        let o: ArraySlice<UInt8> = position.map { source[$0.range] } ?? []
        let style = String(decoding: o, as: UTF8.self)
        switch v {
        case .text(let s):
            return text(s, original: o, position: position, source: source, newline: newline, flow: flow)
        case .integer(let n):
            if case .integer? = old, o.first.map({ $0 == 0x2B || ($0 >= 0x30 && $0 <= 0x39) }) == true {
                return TOMLFormat.integer(n, style: style)
            }
            return String(n)
        case .decimal(let d):
            let e = old?.kind == .decimal ? style : ""
            if d.isNaN { return box(".nan", like: e) }
            if d.isInfinite { return (d < 0 ? "-" : (e.hasPrefix("+") ? "+" : "")) + box(".inf", like: e) }
            switch old {
            case .decimal?, .integer?:
                if o.first.map({ $0 == 0x2B || $0 == 0x2D || $0 == 0x2E || ($0 >= 0x30 && $0 <= 0x39) }) == true,
                   !style.lowercased().contains("inf"), !style.lowercased().contains("nan") {
                    return JSONFormat.decimalJSON5(d, style: style)
                }
            default: break
            }
            return JSONFormat.decimal(d, style: nil)
        case .boolean(let b):
            if case .boolean? = old { return box(b ? "true" : "false", like: style) }
            return b ? "true" : "false"
        case .null:
            if case .null? = old, ["~", "null", "Null", "NULL"].contains(style) { return style }
            return "null"
        case .dateTime(let dh):
            return double(dh.iso)                                           // rejected earlier by `Format.problem`
        case .array(let items):
            if case .array(let olds)? = old, let pos = position, pos.items.count == olds.count {
                let first = o.first { $0 != 0x20 && $0 != 0x09 }
                if first == 0x5B {
                    return TOMLFormat.array(items, old: old, position: position, source: source, newline: newline,
                                          write: { v, a, p in
                                              write(v, old: a, position: p, source: source, newline: newline, flow: true)
                                          },
                                          hasComment: { $0.contains("#") },
                                          withoutComments: { s in
                                              s.split(separator: "\n", omittingEmptySubsequences: false)
                                                  .map { l in l.firstIndex(of: "#").map { l[..<$0] } ?? l }
                                                  .joined(separator: "\n")
                                          })
                }
                if first == 0x2D, !olds.isEmpty {
                    return blockSeq(items, olds: olds, pos: pos, source: source, newline: newline)
                }
            }
            return "[" + items.map { write($0, old: nil, position: nil, source: [], newline: newline, flow: true) }
                .joined(separator: ", ") + "]"
        case .table(let t):
            if t.pairs.isEmpty { return "{}" }
            return "{" + t.pairs.map { p in
                (fitsUnquoted(p.key, flow: true) ? p.key : double(p.key)) + ": "
                    + write(p.value, old: nil, position: nil, source: [], newline: newline, flow: true)
            }.joined(separator: ", ") + "}"
        }
    }

    /// `true` → `True`/`TRUE` if the original was like that (same for `.inf`, `.nan`).
    static func box(_ s: String, like style: String) -> String {
        let letters = style.filter(\.isLetter)
        guard let firstOne = letters.first else { return s }
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return s.uppercased() }
        if firstOne.isUppercase {
            guard let i = s.firstIndex(where: \.isLetter) else { return s }
            var r = s
            r.replaceSubrange(i...i, with: String(s[i]).uppercased())
            if s.hasSuffix("nan") { r = String(r.dropLast(1)) + "N" }      // .NaN
            return r
        }
        return s
    }

    // MARK: Strings

    static func text(_ s: String, original o: ArraySlice<UInt8>, position: Position?, source: [UInt8], newline: String,
                      flow: Bool) -> String {
        switch o.first {
        case 0x7C?, 0x3E?:                                                   // | >
            if let pos = position, let r = block(s, pos: pos, source: source, newline: newline) { return r }
            return double(s)
        case 0x27?:
            return fitsInSingleQuotes(s) ? single(s) : double(s)
        case 0x22?:
            return double(s)
        default:
            return fitsUnquoted(s, flow: flow) ? s : double(s)
        }
    }

    /// Fits unquoted and is read back as the same text — by a YAML 1.1 reader too?
    public static func fitsUnquoted(_ s: String, flow: Bool = false) -> Bool {
        let us = Array(s.unicodeScalars)
        guard let first = us.first, let last = us.last else { return false }
        if s.hasPrefix("---") || s.hasPrefix("...") { return false }
        if first == " " || first == "\t" || last == " " || last == "\t" { return false }
        if "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(first) {
            // `-x` is fine; `- x`, `?`, `:` and the other indicators are not
            guard first == "-", us.count > 1, us[1] != " ", us[1] != "\t", !(flow && ",[]{}".unicodeScalars.contains(us[1]))
            else { return false }
        }
        for (i, u) in us.enumerated() {
            if !isPrintable(u) || u == "\t" { return false }
            let nextOne: Unicode.Scalar? = i + 1 < us.count ? us[i + 1] : nil
            if u == ":" && (nextOne == nil || nextOne == " " || (flow && nextOne.map { ",[]{}".unicodeScalars.contains($0) } == true)) {
                return false
            }
            if u == "#" && i > 0 && (us[i - 1] == " " || us[i - 1] == "\t") { return false }
            if flow && ",[]{}".unicodeScalars.contains(u) { return false }
        }
        if case .text = YAMLReader.resolver(s) {} else { return false }
        return !ambiguousInYAML11(s)
    }

    /// Would a YAML 1.1 reader read this unquoted text as another type (yes/no, number,
    /// date, null) or as something special (`<<`, `=`)? When in doubt, yes: extra quotes change nothing.
    public static func ambiguousInYAML11(_ s: String) -> Bool {
        let l = s.lowercased()
        if ["y", "yes", "n", "no", "true", "false", "on", "off", "~", "null", "", "<<", "="].contains(l) { return true }
        if [".inf", "+.inf", "-.inf", ".nan"].contains(l) { return true }
        // numbers in any base, with `_`, sexagesimal (`1:30`), `1e3`, `010`, `.5`, `1.2.3`
        var t = Substring(l.replacingOccurrences(of: "_", with: ""))
        if t.hasPrefix("+") || t.hasPrefix("-") { t = t.dropFirst() }
        if let p = t.first, p.isASCII, p.isNumber || (p == "." && t.dropFirst().first.map { $0.isASCII && $0.isNumber } == true) {
            if t.allSatisfy({ "0123456789.:eE+-xXoObBabcdefABCDEF".contains($0) }) { return true }
        }
        // date (YAML 1.1 timestamp): 2024-01-31, 2024-1-5 10:00…
        let u = Array(l.utf8)
        if u.count >= 8, u[0...3].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), u[4] == 0x2D {
            return true
        }
        return false
    }

    static func isPrintable(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        if v == 0x09 { return true }
        if v < 0x20 || v == 0x7F { return false }
        if v >= 0x80 && v <= 0x9F { return false }
        if v == 0x2028 || v == 0x2029 || v == 0xFEFF || v == 0xFFFE || v == 0xFFFF { return false }
        return true
    }

    static func fitsInSingleQuotes(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { isPrintable($0) && $0 != "\t" }
    }

    static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public static func double(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x5C: r += "\\\\"
            case 0x22: r += "\\\""
            case 0x00: r += "\\0"
            case 0x07: r += "\\a"
            case 0x08: r += "\\b"
            case 0x09: r += "\\t"
            case 0x0A: r += "\\n"
            case 0x0B: r += "\\v"
            case 0x0C: r += "\\f"
            case 0x0D: r += "\\r"
            case 0x1B: r += "\\e"
            case 0x85: r += "\\N"
            case 0x2028: r += "\\L"
            case 0x2029: r += "\\P"
            default:
                if !isPrintable(u) {
                    r += u.value <= 0xFF ? String(format: "\\x%02X", u.value) : String(format: "\\u%04X", u.value)
                } else {
                    r.unicodeScalars.append(u)
                }
            }
        }
        return r + "\""
    }

    // MARK: `|` and `>` blocks

    /// Block text in the original's style (`|` or `>`, indentation, indentation indicator and the rest
    /// of the header line, comment included). `nil` if the text doesn't fit in a block.
    static func block(_ s: String, pos: Position, source: [UInt8], newline: String) -> String? {
        let iv = pos.range
        let o = Array(source[iv])
        // header: indicator, digit, chomping and the rest of the line
        var literal = o[0] == 0x7C
        var k = 1
        var digit: UInt8? = nil
        for _ in 0..<2 where k < o.count {
            if o[k] >= 0x31 && o[k] <= 0x39 { digit = o[k]; k += 1 }
            else if o[k] == 0x2B || o[k] == 0x2D { k += 1 }
        }
        var headerLineEnd = k
        while headerLineEnd < o.count, o[headerLineEnd] != 0x0A, o[headerLineEnd] != 0x0D { headerLineEnd += 1 }
        let headerRest = String(decoding: o[k..<headerLineEnd], as: UTF8.self)
        // content indentation: that of the first line with text; with none, the header line's + 2
        var indent: Int? = nil
        for l in o[headerLineEnd...].split(separator: 0x0A) {
            let e = l.prefix { $0 == 0x20 }.count
            if l.dropFirst(e).contains(where: { $0 != 0x0D }) { indent = e; break }
        }
        if let d = digit {
            indent = max(parentIndent(iv.lowerBound, source), 0) + Int(d - 0x30)
        }
        if indent == nil {
            var i = iv.lowerBound
            while i > 0, source[i - 1] != 0x0A { i -= 1 }
            indent = source[i...].prefix { $0 == 0x20 }.count + 2
        }
        let ind = String(repeating: " ", count: indent!)

        // does the text fit in a block?
        if s.unicodeScalars.contains(where: { !isPrintable($0) && $0 != "\n" }) { return nil }
        var body = Substring(s)
        var trailing = 0
        while body.hasSuffix("\n") { body = body.dropLast(); trailing += 1 }
        if body.isEmpty && trailing > 0 { return nil }
        let lines = body.isEmpty ? [] : body.split(separator: "\n", omittingEmptySubsequences: false)
        let firstWithText = lines.first { !$0.isEmpty }
        if let pl = firstWithText, pl.first == " " || pl.first == "\t", digit == nil { return nil }
        if indent == 0, lines.contains(where: { $0.hasPrefix("---") || $0.hasPrefix("...") }) { return nil }
        // lines starting with a space are not folded: in a `>` they only fit as `|`
        if !literal, lines.contains(where: { $0.first == " " || $0.first == "\t" }) { literal = true }
        let chomp = trailing == 0 ? "-" : trailing == 1 ? "" : "+"
        // with `+`, blank lines right after the value would be read as part of it
        if chomp == "+" || chomp == "" {
            var i = iv.upperBound
            if i < source.count {
                i += source[i] == 0x0D ? 2 : 1
                var j = i
                while j < source.count, source[j] == 0x20 || source[j] == 0x09 { j += 1 }
                if chomp == "+", j < source.count, source[j] == 0x0A || source[j] == 0x0D { return nil }
                if chomp == "+", j >= source.count, i < source.count { return nil }
            }
        }

        var r = (literal ? "|" : ">") + (digit.map { String(UnicodeScalar($0)) } ?? "") + chomp + headerRest
        var previousWithText = false
        for l in lines {
            if !literal, !l.isEmpty, previousWithText { r += newline }      // `>`: a line break becomes a blank line
            r += newline + (l.isEmpty ? "" : ind + l)
            if !l.isEmpty { previousWithText = true }
        }
        if chomp == "+" { r += String(repeating: newline, count: trailing - 1) }
        // at end of file without a line break, the value's final line break must be written
        if iv.upperBound >= source.count, trailing > 0 { r += newline }
        return r
    }

    // MARK: Block sequences

    static func blockSeq(_ newItems: [Value], olds: [Value], pos: Position, source: [UInt8], newline: String) -> String {
        let items = pos.items.map(\.range)
        func startOfLine(_ off: Int) -> Int {
            var i = off
            while i > 0, source[i - 1] != 0x0A { i -= 1 }
            return i
        }
        func endOfLine(_ off: Int) -> Int {
            var i = off
            while i < source.count, source[i] != 0x0A, source[i] != 0x0D { i += 1 }
            return i
        }
        func nextLine(_ off: Int) -> Int {
            var i = off
            while i < source.count, source[i] != 0x0A { i += 1 }
            return min(i + 1, source.count)
        }
        /// Position of item `k`'s `-`.
        func dash(_ k: Int) -> Int {
            var i = items[k].lowerBound
            while i > 0, source[i - 1] != 0x2D { i -= 1 }
            return i - 1
        }
        func itemEnd(_ k: Int) -> Int { endOfLine(max(items[k].upperBound, dash(k) + 1)) }
        func writeItem(_ v: Value, _ k: Int?) -> String {
            guard let k else { return write(v, old: nil, position: nil, source: [], newline: newline, flow: false) }
            return value(v, old: olds[k], position: pos.items[k], source: source, newline: newline)
        }
        let lo = pos.range.lowerBound
        // every item must start on its own line (only spaces before the `-`)
        let ownLines = olds.indices.allSatisfy { k in
            let t = dash(k)
            return startOfLine(t) >= lo && source[startOfLine(t)..<t].allSatisfy { $0 == 0x20 }
        }
        if newItems.isEmpty || !ownLines {
            // empty sequence (or compact items): flow style, at the first item's indentation
            let indent = String(decoding: source[lo..<dash(0)], as: UTF8.self)
            return indent + "[" + newItems.map { write($0, old: nil, position: nil, source: [], newline: newline, flow: true) }
                .joined(separator: ", ") + "]"
        }
        var edits: [(Range<Int>, String)] = []
        func stripLine(_ k: Int, keepsFollowing: Bool) {
            let ls = startOfLine(dash(k))
            if keepsFollowing {
                edits.append((ls..<nextLine(itemEnd(k)), ""))
            } else {
                var q = ls - 1
                if q > 0, source[q - 1] == 0x0D { q -= 1 }
                edits.append((q..<itemEnd(k), ""))
            }
        }
        if newItems.count < olds.count, let stays = INIFormat.subsequence(newItems, of: olds) {
            for k in olds.indices where !stays[k] {
                stripLine(k, keepsFollowing: stays[(k + 1)...].contains(true))
            }
        } else {
            let n = min(newItems.count, olds.count)
            for i in 0..<n where newItems[i] != olds[i] {
                let sameKind = newItems[i].kind == olds[i].kind || olds[i].kind == .null
                edits.append((items[i], writeItem(newItems[i], sameKind ? i : nil)))
            }
            if newItems.count > olds.count {
                // new lines after the last one, with its indentation and `- `; the style (quotes) of
                // the last item of the same kind, except a `|` block (which has its own lines and comment)
                let u = olds.count - 1
                let t = dash(u)
                let col = t - startOfLine(t)
                var sep = String(decoding: source[(t + 1)..<items[u].lowerBound], as: UTF8.self)
                if sep.isEmpty || sep.contains("\n") || sep.contains("\r") { sep = " " }
                var r = ""
                for v in newItems[olds.count...] {
                    var model: Int? = olds.lastIndex { $0.kind == v.kind }
                    if let m = model, [0x7C, 0x3E].contains(source[items[m]].first) { model = nil }
                    r += newline + String(repeating: " ", count: col) + "-" + sep + writeItem(v, model)
                        .drop { $0 == " " && sep.hasSuffix(" ") }
                }
                let end = itemEnd(u)
                edits.append((end..<end, r))
            } else {
                for k in n..<olds.count { stripLine(k, keepsFollowing: false) }
            }
        }
        // applies from end to start; adjacent removals are merged. A span outside the sequence
        // (shouldn't happen) makes the whole sequence be written in flow style.
        guard edits.allSatisfy({ $0.0.lowerBound >= lo && $0.0.upperBound <= pos.range.upperBound }) else {
            let indent = String(decoding: source[lo..<dash(0)].map { _ in 0x20 }, as: UTF8.self)
            return indent + "[" + newItems.map { write($0, old: nil, position: nil, source: [], newline: newline, flow: true) }
                .joined(separator: ", ") + "]"
        }
        var r = Array(source[pos.range])
        var doneRanges: [Range<Int>] = []
        for (span, updated) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            var f = span
            if updated.isEmpty, let lastOne = doneRanges.last, lastOne.lowerBound < f.upperBound {
                f = f.lowerBound..<lastOne.lowerBound
            }
            r.replaceSubrange((f.lowerBound - lo)..<(f.upperBound - lo), with: Array(updated.utf8))
            doneRanges.append(f)
        }
        return String(decoding: r, as: UTF8.self)
    }
}
