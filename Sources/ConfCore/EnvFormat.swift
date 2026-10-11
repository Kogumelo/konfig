import Foundation

/// Writes `.env` values mimicking the style of the old value.
///
/// - Unquoted stays unquoted if it fits: empty, or without space, tab, `#`,
///   quotes (`"`, `'`, `` ` ``) and control characters. If it doesn't fit, double quotes.
/// - Single quotes stay single if the text has no `'` or CR, and a line break
///   only if the original already spanned several lines (written with the file's line break);
///   otherwise, double quotes.
/// - Double quotes stay double. The start and end that match the original are
///   copied byte for byte (escapes included); the new middle escapes only `\`, `"`,
///   line break (`\n`) and CR (`\r`).
public enum EnvFormat {
    public static func value(_ v: Value, position: Position? = nil, source: [UInt8] = [], newline: String = "\n") -> String {
        let s: String
        switch v {
        case .text(let t): s = t
        case .integer(let n): s = String(n)
        case .decimal(let d): s = TOMLFormat.decimal(d)
        case .boolean(let b): s = b ? "true" : "false"
        case .dateTime(let dh): s = dh.iso
        case .array, .table, .null: s = ""   // rejected earlier by `Format.problem`
        }
        return text(s, original: position.map { source[$0.range] }, newline: newline)
    }

    /// Fits unquoted (and reads back the same)?
    public static func fitsUnquoted(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            u.value >= 0x20 && u.value != 0x7F && u != " " && u != "#" && u != "\"" && u != "'" && u != "`"
        }
    }

    public static func text(_ s: String, original: ArraySlice<UInt8>?, newline: String = "\n") -> String {
        switch original?.first {
        case 0x27?:   // '
            let multiLine = original?.contains(0x0A) ?? false
            if !s.contains("'") && !s.unicodeScalars.contains("\r")
                && (multiLine || !s.unicodeScalars.contains("\n")) {
                return "'" + s.replacingOccurrences(of: "\n", with: newline) + "'"
            }
            return double(s, original: nil)
        case 0x22?:   // "
            return double(s, original: original)
        default:
            return fitsUnquoted(s) ? s : double(s, original: nil)
        }
    }

    /// One character of the original double-quoted text: the scalar and the bytes that wrote it.
    struct Piece {
        var scalar: Unicode.Scalar
        var bytes: ArraySlice<UInt8>
    }

    /// Splits a double-quoted value into units. `nil` if there is a backslash that is not
    /// an escape (`\x`): copying the start up to it could form a new escape with the middle.
    static func pieces(_ o: ArraySlice<UInt8>) -> [Piece]? {
        guard o.count >= 2, o.first == 0x22, o.last == 0x22 else { return nil }
        var r: [Piece] = []
        var i = o.startIndex + 1
        let end = o.endIndex - 1
        while i < end {
            let c = o[i]
            if c == 0x5C {
                guard i + 1 < end else { return nil }
                let v: Unicode.Scalar
                switch o[i + 1] {
                case 0x6E: v = "\n"
                case 0x72: v = "\r"
                case 0x22: v = "\""
                case 0x5C: v = "\\"
                default: return nil
                }
                r.append(Piece(scalar: v, bytes: o[i..<(i + 2)]))
                i += 2
            } else if c == 0x0D, i + 1 < end, o[i + 1] == 0x0A {
                r.append(Piece(scalar: "\n", bytes: o[i..<(i + 2)]))
                i += 2
            } else {
                let len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4
                guard i + len <= end, let u = String(bytes: o[i..<(i + len)], encoding: .utf8)?.unicodeScalars.first
                else { return nil }
                r.append(Piece(scalar: u, bytes: o[i..<(i + len)]))
                i += len
            }
        }
        return r
    }

    static func double(_ s: String, original: ArraySlice<UInt8>?) -> String {
        let newItems = Array(s.unicodeScalars)
        guard let o = original, let us = pieces(o) else { return "\"" + escape(newItems[...]) + "\"" }
        var lo = 0
        while lo < us.count, lo < newItems.count, us[lo].scalar == newItems[lo] { lo += 1 }
        var oldEnd = us.count, newEnd = newItems.count
        while oldEnd > lo, newEnd > lo, us[oldEnd - 1].scalar == newItems[newEnd - 1] { oldEnd -= 1; newEnd -= 1 }
        var r = [UInt8(0x22)]
        for u in us[..<lo] { r += u.bytes }
        r += Array(escape(newItems[lo..<newEnd]).utf8)
        for u in us[oldEnd...] { r += u.bytes }
        r.append(0x22)
        return String(decoding: r, as: UTF8.self)
    }

    static func escape(_ us: ArraySlice<Unicode.Scalar>) -> String {
        var r = ""
        for u in us {
            switch u {
            case "\\": r += "\\\\"
            case "\"": r += "\\\""
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            default: r.unicodeScalars.append(u)
            }
        }
        return r
    }
}
