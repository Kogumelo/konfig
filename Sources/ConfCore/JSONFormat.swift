import Foundation

/// Writes JSON values imitating the style of an old value.
///
/// - Text: the unchanged runs at the start and end are copied byte for byte from the
///   original (escapes included); only the new middle is written, with the original's
///   escaping habits (`\/`, `\u00e9` for non-ASCII, hex digit case).
/// - Number: a decimal stays decimal, with an exponent if it had one (`1.5e3`, same
///   letter `e`/`E` and the `+`), and at least the same digits after the point.
/// - JSON5 (`json5: true`): single quotes stay single; a hexadecimal integer stays
///   hexadecimal (same case and width); `+`, `.5` and `5.` are kept;
///   infinity and NaN become `Infinity` and `NaN`.
public enum JSONFormat {
    public static func value(_ v: Value, old: Value? = nil, position: Position? = nil, source: [UInt8] = [],
                             newline: String = "\n", json5: Bool = false) -> String {
        let original: ArraySlice<UInt8>? = position.map { source[$0.range] }
        let style = original.map { String(decoding: $0, as: UTF8.self) }
        switch v {
        case .text(let s):
            if case .text? = old { return text(s, original: original, source: source, json5: json5) }
            return text(s, original: nil, source: source, json5: json5)
        case .integer(let n):
            if json5, case .integer? = old { return integerJSON5(n, style: style) }
            return String(n)
        case .decimal(let d):
            let e: String?
            switch old { case .decimal?, .integer?: e = style; default: e = nil }
            return json5 ? decimalJSON5(d, style: e) : decimal(d, style: e)
        case .boolean(let b): return b ? "true" : "false"
        case .null: return "null"
        case .dateTime(let dh): return text(dh.iso, original: nil, source: [])
        case .array(let items):
            return TOMLFormat.array(items, old: old, position: position, source: source, newline: newline,
                                  write: { v, a, p in value(v, old: a, position: p, source: source, newline: newline, json5: json5) },
                                  hasComment: { $0.contains("//") || $0.contains("/*") },
                                  withoutComments: withoutComments)
        case .table(let t):
            if t.pairs.isEmpty { return "{}" }
            return "{" + t.pairs.map { text($0.key, original: nil, source: []) + ": " + value($0.value, json5: json5) }
                .joined(separator: ", ") + "}"
        }
    }

    /// The text without `//` and `/* */` comments (used only in the gaps between items).
    static func withoutComments(_ s: String) -> String {
        let u = Array(s.utf8)
        var r: [UInt8] = []
        var i = 0
        while i < u.count {
            if u[i] == 0x2F, i + 1 < u.count, u[i + 1] == 0x2F {
                while i < u.count, u[i] != 0x0A { i += 1 }
            } else if u[i] == 0x2F, i + 1 < u.count, u[i + 1] == 0x2A {
                i += 2
                while i + 1 < u.count, !(u[i] == 0x2A && u[i + 1] == 0x2F) { i += 1 }
                i += 2
            } else {
                r.append(u[i]); i += 1
            }
        }
        return String(decoding: r, as: UTF8.self)
    }

    // MARK: Strings

    struct Style {
        var escapeSlash = false
        var escapeNonASCII = false
        var hexUppercase = true
        /// The string's quote: `"` or, in JSON5, `'`.
        var quote = "\""
    }

    /// A character of the original string: the scalar and the exact bytes that wrote it.
    struct Piece {
        var scalar: Unicode.Scalar
        var bytes: ArraySlice<UInt8>
    }

    /// Splits a valid JSON (or JSON5) string, with its quotes, into units. In JSON5,
    /// a line continuation (`\` + line break) is not a character: it sticks to the next unit
    /// (or to the previous one, at the end of the string), to be copied along when that unit is unchanged.
    static func pieces(_ o: ArraySlice<UInt8>) -> [Piece]? {
        guard o.count >= 2, o.first == 0x22 || o.first == 0x27, o.last == o.first else { return nil }
        var r: [Piece] = []
        var i = o.startIndex + 1
        let end = o.endIndex - 1
        /// Start of a line continuation not yet attached to a unit.
        var continuation: Int? = nil
        func put(_ u: Unicode.Scalar, _ len: Int) {
            r.append(Piece(scalar: u, bytes: o[(continuation ?? i)..<(i + len)]))
            continuation = nil
        }
        func hex(_ k: Int) -> UInt32? {
            guard k + 4 <= end else { return nil }
            return UInt32(String(decoding: o[k..<(k + 4)], as: UTF8.self), radix: 16)
        }
        while i < end {
            let c = o[i]
            if c == 0x5C {
                guard i + 1 < end else { return nil }
                let e = o[i + 1]
                var v: UInt32
                var len = 2
                // line continuation (JSON5): `\` + LF, CR, CRLF, U+2028 or U+2029
                var counter = 0
                if e == 0x0A { counter = 2 } else if e == 0x0D { counter = i + 2 < end && o[i + 2] == 0x0A ? 3 : 2 }
                else if e == 0xE2, i + 3 < end, o[i + 2] == 0x80, o[i + 3] == 0xA8 || o[i + 3] == 0xA9 { counter = 4 }
                if counter > 0 {
                    if continuation == nil { continuation = i }
                    i += counter
                    continue
                }
                switch e {
                case 0x22: v = 0x22
                case 0x27: v = 0x27
                case 0x76: v = 0x0B
                case 0x30: v = 0
                case 0x78:
                    guard i + 4 <= end, let x = UInt32(String(decoding: o[(i + 2)..<(i + 4)], as: UTF8.self), radix: 16)
                    else { return nil }
                    v = x; len = 4
                case 0x5C: v = 0x5C
                case 0x2F: v = 0x2F
                case 0x62: v = 0x08
                case 0x66: v = 0x0C
                case 0x6E: v = 0x0A
                case 0x72: v = 0x0D
                case 0x74: v = 0x09
                case 0x75:
                    guard let a = hex(i + 2) else { return nil }
                    v = a; len = 6
                    if a >= 0xD800 && a <= 0xDBFF {
                        guard i + 12 <= end, o[i + 6] == 0x5C, o[i + 7] == 0x75, let bx = hex(i + 8) else { return nil }
                        v = 0x10000 + ((a - 0xD800) << 10) + (bx - 0xDC00); len = 12
                    }
                default:
                    // JSON5: any other escaped character stands for itself (`\a` is `a`)
                    let t = e < 0x80 ? 1 : e < 0xE0 ? 2 : e < 0xF0 ? 3 : 4
                    guard i + 1 + t <= end, let s = String(bytes: o[(i + 1)..<(i + 1 + t)], encoding: .utf8)?
                        .unicodeScalars.first else { return nil }
                    v = s.value; len = 1 + t
                }
                guard let u = Unicode.Scalar(v) else { return nil }
                put(u, len)
                i += len
            } else {
                let len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4
                guard i + len <= end, let s = String(bytes: o[i..<(i + len)], encoding: .utf8)?.unicodeScalars.first
                else { return nil }
                put(s, len)
                i += len
            }
        }
        if continuation != nil, let u = r.last {
            // continuation right before the closing quote: goes with the last unit
            r[r.count - 1].bytes = o[u.bytes.startIndex..<end]
        }
        return r
    }

    static func style(_ us: [Piece], source: [UInt8]) -> Style {
        var e = Style()
        var sawNonASCII = false, sawUpper = false, sawLower = false
        for u in us {
            if u.bytes.first == 0x5C {
                if u.bytes.count == 2, u.bytes.last == 0x2F { e.escapeSlash = true }
                if u.bytes.count >= 6, u.bytes[u.bytes.startIndex + 1] == 0x75 {
                    for h in u.bytes where (0x41...0x46).contains(h) { sawUpper = true }
                    for h in u.bytes where (0x61...0x66).contains(h) { sawLower = true }
                    if u.scalar.value >= 0x80 { e.escapeNonASCII = true }
                }
            } else if u.scalar.value >= 0x80 {
                sawNonASCII = true
            }
        }
        if sawNonASCII { e.escapeNonASCII = false }
        if sawLower && !sawUpper { e.hexUppercase = false }
        if !sawNonASCII && !e.escapeNonASCII {
            // the string says nothing: follow the file's habit (ASCII only and with \u for non-ASCII)
            let body = source.starts(with: [0xEF, 0xBB, 0xBF]) ? source.dropFirst(3) : source[...]
            if !body.contains(where: { $0 >= 0x80 }), usesNonASCIIEscape(body) { e.escapeNonASCII = true }
        }
        return e
    }

    static func usesNonASCIIEscape(_ f: ArraySlice<UInt8>) -> Bool {
        var i = f.startIndex
        while i + 5 < f.endIndex {
            if f[i] == 0x5C, f[i + 1] == 0x75 {
                let h = String(decoding: f[(i + 2)..<(i + 6)], as: UTF8.self)
                if let v = UInt32(h, radix: 16), v >= 0x80 { return true }
                i += 6
            } else if f[i] == 0x5C {
                i += 2
            } else {
                i += 1
            }
        }
        return false
    }

    /// Quoted string. With the original, copies from it the start and end that did not change.
    /// In JSON5, single quotes stay single.
    public static func text(_ s: String, original: ArraySlice<UInt8>?, source: [UInt8] = [],
                             json5: Bool = false) -> String {
        let newItems = Array(s.unicodeScalars)
        guard let o = original, let us = pieces(o) else { return "\"" + escape(newItems[...], Style()) + "\"" }
        var e = style(us, source: source)
        let quote = json5 && o.first == 0x27 ? "'" : "\""
        e.quote = quote
        var start = 0
        while start < us.count, start < newItems.count, us[start].scalar == newItems[start] { start += 1 }
        var oldEnd = us.count, newEnd = newItems.count
        while oldEnd > start, newEnd > start, us[oldEnd - 1].scalar == newItems[newEnd - 1] { oldEnd -= 1; newEnd -= 1 }
        var r = quote
        for u in us[..<start] { r += String(decoding: u.bytes, as: UTF8.self) }
        r += escape(newItems[start..<newEnd], e)
        for u in us[oldEnd...] { r += String(decoding: u.bytes, as: UTF8.self) }
        return r + quote
    }

    static func escape(_ us: ArraySlice<Unicode.Scalar>, _ e: Style) -> String {
        func u4(_ v: UInt32) -> String {
            let h = String(v, radix: 16, uppercase: e.hexUppercase)
            return "\\u" + String(repeating: "0", count: max(0, 4 - h.count)) + h
        }
        var r = ""
        for u in us {
            switch u {
            case "\"": r += e.quote == "\"" ? "\\\"" : "\""
            case "'": r += e.quote == "'" ? "\\'" : "'"
            case "\\": r += "\\\\"
            case "/": r += e.escapeSlash ? "\\/" : "/"
            case "\u{08}": r += "\\b"
            case "\u{0C}": r += "\\f"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default:
                if u.value < 0x20 {
                    r += u4(u.value)
                } else if u.value >= 0x80 && e.escapeNonASCII {
                    if u.value > 0xFFFF {
                        let v = u.value - 0x10000
                        r += u4(0xD800 + (v >> 10)) + u4(0xDC00 + (v & 0x3FF))
                    } else {
                        r += u4(u.value)
                    }
                } else {
                    r.unicodeScalars.append(u)
                }
            }
        }
        return r
    }

    // MARK: Numbers

    /// JSON5 integer in the original's form: hexadecimal (`0x`/`0X`, digit case and
    /// width) or decimal, with the `+` if it had one.
    public static func integerJSON5(_ n: Int64, style a: String?) -> String {
        var a = Substring(a ?? "")
        let plus = a.hasPrefix("+")
        if a.hasPrefix("+") || a.hasPrefix("-") { a = a.dropFirst() }
        let signText = n < 0 ? "-" : (plus ? "+" : "")
        guard a.hasPrefix("0x") || a.hasPrefix("0X") else { return signText + String(n.magnitude) }
        let digits = a.dropFirst(2)
        let upper = digits.contains { "ABCDEF".contains($0) } || !digits.contains { "abcdef".contains($0) }
            && a.hasPrefix("0X")
        var h = String(n.magnitude, radix: 16, uppercase: upper)
        if h.count < digits.count { h = String(repeating: "0", count: digits.count - h.count) + h }
        return signText + a.prefix(2) + h
    }

    /// JSON5 decimal in the original's form: `Infinity`/`NaN`, `+` if it had one, `.5` without
    /// the zero and `5.` without fraction digits, when the new value fits that form.
    public static func decimalJSON5(_ d: Double, style a: String?) -> String {
        var a = Substring(a ?? "")
        let plus = a.hasPrefix("+")
        if a.hasPrefix("+") || a.hasPrefix("-") { a = a.dropFirst() }
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : (plus ? "+Infinity" : "Infinity") }
        let isNumeric = a.first.map { $0.isNumber || $0 == "." } ?? false
        let expPos = a.firstIndex { $0 == "e" || $0 == "E" }
        let mantissa = expPos.map { a[..<$0] } ?? a
        let dotAtStart = isNumeric && mantissa.hasPrefix(".")
        let dotAtEnd = isNumeric && mantissa.hasSuffix(".")
        // style normalized for JSON: `.5` → `0.5`, `5.` → `5.0`, hexadecimal ignored
        var normal: String? = nil
        if isNumeric && !a.hasPrefix("0x") && !a.hasPrefix("0X") {
            normal = (dotAtStart ? "0" : "") + mantissa + (dotAtEnd ? "0" : "") + (expPos.map { String(a[$0...]) } ?? "")
        }
        var r = decimal(d, style: normal)
        let neg = r.hasPrefix("-")
        if neg { r.removeFirst() }
        let e = r.firstIndex { $0 == "e" || $0 == "E" }
        var m = String(e.map { r[..<$0] } ?? r[...])
        let rest = e.map { String(r[$0...]) } ?? ""
        if dotAtStart, m.hasPrefix("0.") { m.removeFirst() }
        if dotAtEnd, let p = m.firstIndex(of: "."), m[m.index(after: p)...].allSatisfy({ $0 == "0" }) {
            m = String(m[...p])
        }
        return (neg ? "-" : (plus ? "+" : "")) + m + rest
    }

    /// Decimal in the original's form: with or without exponent, (at least) the same digits after the point.
    /// Always with a point or exponent, so it is still read as a decimal.
    public static func decimal(_ d: Double, style a: String?) -> String {
        guard d.isFinite else { return TOMLFormat.decimal(d) }
        let a = a ?? ""
        let expPos = a.firstIndex { $0 == "e" || $0 == "E" }
        let letterE: String = expPos.map { String(a[$0]) } ?? "e"
        let mantissa = expPos.map { a[..<$0] } ?? a[...]
        let places = mantissa.firstIndex(of: ".").map { mantissa.distance(from: $0, to: mantissa.endIndex) - 1 } ?? 0
        let plusInExponent = expPos.map { a[a.index(after: $0)...].hasPrefix("+") } ?? false

        // significant digits (D) and exponent (E): |d| = D × 10^E
        let (digits, exponent) = decompose(d.magnitude)
        let signText = d.sign == .minus ? "-" : ""
        let useExponent = expPos != nil || exponent + digits.count > 21 || exponent + digits.count < -6

        if useExponent {
            let e10 = exponent + digits.count - 1
            var frac = String(digits.dropFirst())
            let minimum = expPos != nil ? places : 0
            if frac.count < minimum { frac += String(repeating: "0", count: minimum - frac.count) }
            let m = String(digits.prefix(1)) + (frac.isEmpty ? "" : "." + frac)
            let expSign = e10 < 0 ? "-" : (plusInExponent ? "+" : "")
            return signText + m + letterE + expSign + String(abs(e10))
        }
        var whole: String, frac: String
        if exponent >= 0 {
            whole = digits + String(repeating: "0", count: exponent)
            frac = ""
        } else if digits.count > -exponent {
            whole = String(digits.dropLast(-exponent))
            frac = String(digits.suffix(-exponent))
        } else {
            whole = "0"
            frac = String(repeating: "0", count: -exponent - digits.count) + digits
        }
        let minimum = max(1, places)
        if frac.count < minimum { frac += String(repeating: "0", count: minimum - frac.count) }
        return signText + whole + "." + frac
    }

    /// Shortest digit sequence that represents `d` (≥ 0), with the decimal exponent.
    static func decompose(_ d: Double) -> (String, Int) {
        if d == 0 { return ("0", 0) }
        let s = "\(d)"   // shortest form that reads back as the same Double: "1.5", "1e-05", "1.2345e+20"
        var mant = Substring(s), exp = 0
        if let i = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mant = s[..<i]
            exp = Int(s[s.index(after: i)...]) ?? 0
        }
        var digitStr = mant.replacingOccurrences(of: ".", with: "")
        if let dot = mant.firstIndex(of: ".") {
            exp -= mant.distance(from: dot, to: mant.endIndex) - 1
        }
        while digitStr.count > 1, digitStr.hasPrefix("0") { digitStr.removeFirst() }
        while digitStr.count > 1, digitStr.hasSuffix("0") { digitStr.removeLast(); exp += 1 }
        return (digitStr, exp)
    }
}
