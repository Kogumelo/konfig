import Foundation

/// What to write in place of a value.
public enum NewValue: Hashable, Sendable {
    /// New value, written in the style of the old value.
    case value(Value)
    /// Raw text of the value in the file's format (for example `[1, "a"]`), written as is after validation.
    case raw(String)
}

public struct SaveError: Error, Sendable, LocalizedError, CustomStringConvertible {
    public var message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Replaces in the original text only the spans of the changed values.
public enum Writer {
    /// Returns the new text. With no effective changes, returns exactly the same bytes.
    ///
    /// Before returning, re-parses the result with the format's reader and checks that the values
    /// are the expected ones; if not, throws and nothing should be saved.
    public static func apply(_ original: [UInt8], changes: [ValuePath: NewValue],
                               format: Format = .toml) throws -> [UInt8] {
        if changes.isEmpty { return original }
        let doc: ConfDocument
        do { doc = try format.parse(original) } catch {
            throw SaveError(String(format: NSLocalizedString("the current file is not valid %@ (%@); edit it in Text mode", comment: "Save error; %1$@ = format name, %2$@ = parse error"), format.name, "\(error)"))
        }
        return try apply(doc, changes: changes)
    }

    public static func apply(_ doc: ConfDocument, changes: [ValuePath: NewValue]) throws -> [UInt8] {
        let format = doc.format
        var replacements: [(Range<Int>, [UInt8])] = []
        var expected = doc.rootValue
        for (path, updated) in changes {
            guard let e = doc.entry(path) else {
                throw SaveError(String(format: NSLocalizedString("the key '%@' no longer exists in the file", comment: "Save error; %@ = key path"), path.text))
            }
            let oldText = Array(doc.bytes[e.range])
            let replacementValue: Value
            let newText: [UInt8]
            switch updated {
            case .raw(let s):
                do { replacementValue = try format.parseValue(s) } catch {
                    throw SaveError(String(format: NSLocalizedString("value of '%@' is not valid %@: %@", comment: "Save error; %1$@ = key path, %2$@ = format name, %3$@ = parse error"), path.text, format.name, "\(error)"))
                }
                newText = Array(format.adjustRaw(s, position: e.position, source: doc.bytes).utf8)
                if newText == oldText { continue }
            case .value(let v):
                if v == e.value { continue }
                if let p = format.problem(v) { throw SaveError(String(format: NSLocalizedString("'%@': %@", comment: "Save error; %1$@ = key path, %2$@ = problem description"), path.text, p)) }
                replacementValue = v
                newText = Array(format.write(v, old: e.value, position: e.position, source: doc.bytes,
                                                   newline: doc.lineBreak).utf8)
            }
            replacements.append((e.range, newText))
            guard let t = expected.replacing(path, by: replacementValue) else {
                throw SaveError(String(format: NSLocalizedString("could not locate '%@'", comment: "Save error; %@ = key path"), path.text))
            }
            expected = t
        }
        if replacements.isEmpty { return doc.bytes }
        // Overlapping spans (in INI, a `key[]` array with another key between its
        // items): apply one change at a time, re-parsing the file between them.
        let ordered = replacements.map(\.0).sorted { $0.lowerBound < $1.lowerBound }
        if zip(ordered, ordered.dropFirst()).contains(where: { $0.upperBound > $1.lowerBound }) {
            var current = doc
            for (path, updated) in changes.sorted(by: { $0.key.text < $1.key.text }) {
                let r = try apply(current, changes: [path: updated])
                do { current = try format.parse(r) } catch {
                    throw SaveError(String(format: NSLocalizedString("the result would not be valid %@ (%@); nothing was saved", comment: "Save error; %1$@ = format name, %2$@ = parse error"), format.name, "\(error)"))
                }
            }
            guard current.rootValue == expected else {
                throw SaveError(NSLocalizedString("the re-parsed result does not match the requested values; nothing was saved", comment: "Save error"))
            }
            return current.bytes
        }
        var r = doc.bytes
        for (range, updated) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            r.replaceSubrange(range, with: updated)
        }
        let reparsed: ConfDocument
        do { reparsed = try format.parse(r) } catch {
            throw SaveError(String(format: NSLocalizedString("the result would not be valid %@ (%@); nothing was saved", comment: "Save error; %1$@ = format name, %2$@ = parse error"), format.name, "\(error)"))
        }
        // Plain JSON stays plain: a raw value with a comment or trailing comma would turn it into JSONC.
        if format == .json && !doc.usesJSONCExtensions && reparsed.usesJSONCExtensions {
            throw SaveError(NSLocalizedString("the result would have a comment or trailing comma, which this file's plain JSON does not have; nothing was saved", comment: "Save error"))
        }
        guard reparsed.rootValue == expected else {
            throw SaveError(NSLocalizedString("the re-parsed result does not match the requested values; nothing was saved", comment: "Save error"))
        }
        return r
    }
}

/// Writes TOML values mimicking the style of an old value.
public enum TOMLFormat {
    public static func value(_ v: Value, old: Value? = nil, position: Position? = nil, source: [UInt8] = [],
                             newline: String = "\n") -> String {
        let a: String? = position.map { String(decoding: source[$0.range], as: UTF8.self) }
        switch v {
        case .text(let s): return text(s, style: a, newline: newline)
        case .integer(let n): return integer(n, style: a)
        case .decimal(let d): return decimal(d)
        case .boolean(let b): return b ? "true" : "false"
        case .dateTime(let dh): return dateTime(dh, style: a)
        case .array(let items): return array(items, old: old, position: position, source: source, newline: newline)
        case .table(let t): return inlineTable(t)
        case .null: return "null"
        }
    }

    // MARK: Strings

    public static func basicString(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": r += "\\\\"
            case "\"": r += "\\\""
            case "\u{08}": r += "\\b"
            case "\t": r += "\\t"
            case "\n": r += "\\n"
            case "\u{0C}": r += "\\f"
            case "\r": r += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F { r += String(format: "\\u%04X", u.value) }
                else { r.unicodeScalars.append(u) }
            }
        }
        return r + "\""
    }

    static func hasControl(_ s: String, allowingNewline: Bool) -> Bool {
        s.unicodeScalars.contains { u in
            if u == "\t" { return false }
            if u == "\n" && allowingNewline { return false }
            return u.value < 0x20 || u.value == 0x7F
        }
    }

    /// Text in the same kind of quotes as the original; if it doesn't fit, falls back to basic quotes.
    public static func text(_ s: String, style a: String?, newline: String = "\n") -> String {
        let a = a ?? ""
        let leadingNewline = a.dropFirst(3).hasPrefix("\n") || a.dropFirst(3).hasPrefix("\r\n") || s.hasPrefix("\n")
        if a.hasPrefix("'''") {
            if !s.contains("'''") && !s.hasSuffix("'") && !hasControl(s, allowingNewline: true) {
                return "'''" + (leadingNewline ? newline : "") + s.replacingOccurrences(of: "\n", with: newline) + "'''"
            }
            return multilineBasicString(s, leadingNewline: leadingNewline, newline: newline)
        }
        if a.hasPrefix("\"\"\"") {
            return multilineBasicString(s, leadingNewline: leadingNewline, newline: newline)
        }
        if a.hasPrefix("'") && !s.contains("'") && !hasControl(s, allowingNewline: false) {
            return "'" + s + "'"
        }
        return basicString(s)
    }

    static func multilineBasicString(_ s: String, leadingNewline: Bool, newline: String) -> String {
        var r = "\"\"\"" + (leadingNewline ? newline : "")
        let us = Array(s.unicodeScalars)
        for (i, u) in us.enumerated() {
            switch u {
            case "\\": r += "\\\\"
            case "\"":
                // never leaves two consecutive unescaped quotes, nor a quote before the closing delimiter
                let next = i + 1 < us.count ? us[i + 1] : nil
                r += (next == "\"" || next == nil) ? "\\\"" : "\""
            case "\n": r += newline
            case "\t": r += "\t"
            case "\r": r += "\\r"
            case "\u{08}": r += "\\b"
            case "\u{0C}": r += "\\f"
            default:
                if u.value < 0x20 || u.value == 0x7F { r += String(format: "\\u%04X", u.value) }
                else { r.unicodeScalars.append(u) }
            }
        }
        return r + "\"\"\""
    }

    // MARK: Numbers

    /// Integer in the same base, with the same `_` grouping and the same width (hex/octal/binary).
    public static func integer(_ n: Int64, style a: String?) -> String {
        let a = a ?? ""
        var base = 10, prefix = "", uppercaseDigits = false
        if a.hasPrefix("0x") { base = 16; prefix = "0x"; uppercaseDigits = a.dropFirst(2).contains { "ABCDEF".contains($0) } }
        else if a.hasPrefix("0o") { base = 8; prefix = "0o" }
        else if a.hasPrefix("0b") { base = 2; prefix = "0b" }
        if n < 0 && base != 10 { base = 10; prefix = "" }
        var digitStr = String(n.magnitude, radix: base, uppercase: uppercaseDigits)
        if base != 10 {
            let width = a.dropFirst(2).filter { $0 != "_" }.count
            if digitStr.count < width { digitStr = String(repeating: "0", count: width - digitStr.count) + digitStr }
        }
        if let lastOne = a.lastIndex(of: "_") {
            let group = a.distance(from: a.index(after: lastOne), to: a.endIndex)
            if group > 0 {
                var parts: [Substring] = []
                var end = digitStr.endIndex
                while end > digitStr.startIndex {
                    let lo = digitStr.index(end, offsetBy: -group, limitedBy: digitStr.startIndex) ?? digitStr.startIndex
                    parts.insert(digitStr[lo..<end], at: 0)
                    end = lo
                }
                digitStr = parts.joined(separator: "_")
            }
        }
        let signText = n < 0 ? "-" : (a.hasPrefix("+") && base == 10 ? "+" : "")
        return signText + prefix + digitStr
    }

    public static func decimal(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        var s = "\(d)"
        if !s.contains(".") && !s.contains("e") { s += ".0" }
        return s
    }

    public static func dateTime(_ dh: DateTime, style a: String?) -> String {
        var sep: Character = "T"
        if let a, a.count > 10 {
            let c = a[a.index(a.startIndex, offsetBy: 10)]
            if c == " " || c == "t" { sep = c }
        }
        return dh.text(separator: sep, lowercaseZ: a?.hasSuffix("z") ?? false)
    }

    // MARK: Arrays and tables

    public static func inlineTable(_ t: Table) -> String {
        if t.pairs.isEmpty { return "{}" }
        return "{ " + t.pairs.map { PathSegment.formattedKey($0.key) + " = " + value($0.value) }.joined(separator: ", ") + " }"
    }

    static func array(_ items: [Value], old: Value?, position: Position?, source: [UInt8], newline: String) -> String {
        array(items, old: old, position: position, source: source, newline: newline,
              write: { v, a, p in value(v, old: a, position: p, source: source, newline: newline) },
              hasComment: { $0.contains("#") },
              withoutComments: { s in
                  s.split(separator: "\n", omittingEmptySubsequences: false)
                      .map { l in l.firstIndex(of: "#").map { l[..<$0] } ?? l }
                      .joined(separator: "\n")
              })
    }

    /// Array in the style of the old one, shared by TOML and JSON. `write` writes an item
    /// (with the old item and its position, if any); `hasComment` and
    /// `withoutComments` recognize comments between the items.
    static func array(_ items: [Value], old: Value?, position: Position?, source: [UInt8], newline: String,
                      write: (Value, Value?, Position?) -> String,
                      hasComment: (String) -> Bool,
                      withoutComments: (String) -> String) -> String {
        guard case .array(let olds)? = old, let pos = position, pos.items.count == olds.count,
              pos.range.count >= 2 else {
            return "[" + items.map { write($0, nil, nil) }.joined(separator: ", ") + "]"
        }
        func txt(_ r: Range<Int>) -> String { String(decoding: source[r], as: UTF8.self) }
        // "\r\n" is a single Character in Swift: look for the break by bytes
        func hasNewline(_ s: String) -> Bool { s.utf8.contains(0x0A) }

        // Same number of items: replace only the items that changed, preserving everything else.
        if items.count == olds.count {
            var r = ""
            var cursor = pos.range.lowerBound
            for i in items.indices where items[i] != olds[i] {
                let ip = pos.items[i]
                r += txt(cursor..<ip.range.lowerBound)
                r += write(items[i], olds[i], ip)
                cursor = ip.range.upperBound
            }
            return r + txt(cursor..<pos.range.upperBound)
        }

        // Each new item copies the style of the old item at the same position, or of the first one of the same kind.
        let written: [String] = items.enumerated().map { i, v in
            if i < olds.count, olds[i].kind == v.kind {
                return write(v, olds[i], pos.items[i])
            }
            if let j = olds.firstIndex(where: { $0.kind == v.kind }), v.kind != .array {
                return write(v, olds[j], pos.items[j])
            }
            return write(v, nil, nil)
        }

        let lo = pos.range.lowerBound, end = pos.range.upperBound
        guard let first = pos.items.first, let last = pos.items.last else {
            // empty old array: keep what was between the brackets if it is only spaces
            let inside = txt((lo + 1)..<(end - 1))
            if written.isEmpty { return txt(pos.range) }
            let pad = inside.allSatisfy { $0 == " " } && !inside.isEmpty ? " " : ""
            return "[" + pad + written.joined(separator: ", ") + pad + "]"
        }
        if written.isEmpty { return "[]" }

        let before = txt((lo + 1)..<first.range.lowerBound)
        let after = txt(last.range.upperBound..<(end - 1))
        let trailingComma = withoutComments(after).contains(",")
        var between: [String] = []
        for k in 1..<pos.items.count {
            between.append(txt(pos.items[k - 1].range.upperBound..<pos.items[k].range.lowerBound))
        }
        let multiLine = ([before, after] + between).contains(where: hasNewline)

        if !multiLine {
            let opens = before.allSatisfy { $0 == " " || $0 == "\t" } ? before : ""
            var sep = ", "
            if let e = between.first, !hasComment(e), !hasNewline(e) { sep = e }
            var closes = after
            if let v = closes.lastIndex(of: ",") { closes = String(closes[closes.index(after: v)...]) }
            if !closes.allSatisfy({ $0 == " " || $0 == "\t" }) { closes = "" }
            return "[" + opens + written.joined(separator: sep) + (trailingComma ? "," : "") + closes + "]"
        }

        // Multi-line: indent of the first item, trailing comma if there was one, `]` where it was.
        func lineIndent(_ off: Int) -> String? {
            var i = off
            while i > 0, source[i - 1] == 0x20 || source[i - 1] == 0x09 { i -= 1 }
            guard i == 0 || source[i - 1] == 0x0A else { return nil }
            return txt(i..<off)
        }
        let firstOnBracketLine = !hasNewline(before)
        var indent = "    "
        if !firstOnBracketLine, let r = lineIndent(first.range.lowerBound) {
            indent = r
        } else if pos.items.count > 1, let r = lineIndent(pos.items[1].range.lowerBound) {
            indent = r
        }
        var r = "["
        if firstOnBracketLine {
            r += before.allSatisfy({ $0 == " " || $0 == "\t" }) ? before : ""
        } else {
            r += newline + indent
        }
        r += written[0]
        for e in written.dropFirst() { r += "," + newline + indent + e }
        if trailingComma { r += "," }
        if hasNewline(after) {
            let closesIndent = String(decoding: after.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).last ?? [], as: UTF8.self)
            r += newline + (closesIndent.allSatisfy { $0 == " " || $0 == "\t" } ? closesIndent : "")
        }
        return r + "]"
    }
}
