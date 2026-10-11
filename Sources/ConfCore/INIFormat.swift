import Foundation

/// Writes INI values mimicking the style of the old value.
///
/// - Unquoted stays unquoted if the text fits (`fitsUnquoted`); otherwise, double
///   quotes (or single, if the text has `"`).
/// - Double quotes stay double and single stay single, unless the text
///   contains that quote (there are no escapes): then the other one, or none if it fits.
/// - An empty old value in `key =` (space before the `=`) gets a space after the `=`.
/// - Arrays `key[] = …`: changed items are replaced in place; an extra item is a
///   new line right after the array's last one, copying its start (`key[] = `);
///   a removed item is its line going away.
public enum INIFormat {
    public static func value(_ v: Value, old: Value? = nil, position: Position? = nil, source: [UInt8] = [],
                             newline: String = "\n") -> String {
        switch v {
        case .array(let items):
            guard case .array(let olds)? = old, let pos = position, pos.items.count == olds.count,
                  !olds.isEmpty else {
                return items.map { value($0) }.joined(separator: ", ")
            }
            return array(items, olds: olds, pos: pos, source: source, newline: newline)
        default:
            return text(textOf(v), source: source, range: position?.range)
        }
    }

    static func textOf(_ v: Value) -> String {
        switch v {
        case .text(let t): return t
        case .integer(let n): return String(n)
        case .decimal(let d): return TOMLFormat.decimal(d)
        case .boolean(let b): return b ? "true" : "false"
        case .dateTime(let dh): return dh.iso
        case .array, .table, .null: return ""   // rejected earlier by `Format.problem`
        }
    }

    /// Fits unquoted (and reads back the same, including by PHP, which cuts at `;`)?
    public static func fitsUnquoted(_ s: String) -> Bool {
        let us = Array(s.unicodeScalars)
        guard let first = us.first else { return true }
        if first == " " || first == "\t" || us.last == " " || us.last == "\t" { return false }
        if first == "\"" || first == "'" || first == "#" { return false }
        for (i, u) in us.enumerated() {
            if u.value < 0x20 && u != "\t" || u.value == 0x7F { return false }
            if u == ";" { return false }
            if u == "#" && i > 0 && (us[i - 1] == " " || us[i - 1] == "\t") { return false }
        }
        return true
    }

    /// Reason the text cannot be written in INI (no escapes, single line only).
    static func problem(_ s: String) -> String? {
        if s.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }) {
            return NSLocalizedString("INI has no multi-line values or control characters", comment: "Save error")
        }
        if !fitsUnquoted(s) && s.contains("\"") && s.contains("'") {
            return NSLocalizedString("the value needs quotes (it has ';', '#', leading/trailing spaces or starts with a quote) and contains both double and single quotes; INI has no escapes", comment: "Save error")
        }
        return nil
    }

    /// Text in the style of the original at `source[range]`.
    static func text(_ s: String, source: [UInt8], range: Range<Int>?) -> String {
        let original = range.map { source[$0] } ?? []
        let double = "\"" + s + "\"", single = "'" + s + "'"
        var r: String
        switch original.first {
        case 0x22?: r = !s.contains("\"") ? double : !s.contains("'") ? single : s
        case 0x27?: r = !s.contains("'") ? single : !s.contains("\"") ? double : s
        default: r = fitsUnquoted(s) ? s : !s.contains("\"") ? double : single
        }
        guard let iv = range, !r.isEmpty else { return r }
        let lb = iv.lowerBound, ub = iv.upperBound
        // empty `key =`: `key = new`, not `key =new`
        if original.isEmpty, lb >= 2, lb <= source.count, source[lb - 1] == 0x3D || source[lb - 1] == 0x3A,
           source[lb - 2] == 0x20 || source[lb - 2] == 0x09 {
            r = " " + r
        }
        // unquoted and stuck to a comment (`key =;c`): a space so the comment stays a comment
        if r.last != "\"" && r.last != "'", ub < source.count, source[ub] == 0x3B || source[ub] == 0x23 {
            r += " "
        }
        return r
    }

    // MARK: Arrays

    static func array(_ newItems: [Value], olds: [Value], pos: Position, source: [UInt8], newline: String) -> String {
        let items = pos.items.map(\.range)
        func startOfLine(_ off: Int) -> Int {
            var i = off
            while i > 0, source[i - 1] != 0x0A { i -= 1 }
            return i
        }
        func endOfContent(_ off: Int) -> Int {
            var i = off
            while i < source.count, source[i] != 0x0A { i += 1 }
            if i > off, i > 0, source[i - 1] == 0x0D { i -= 1 }
            return i
        }
        func nextLine(_ off: Int) -> Int {
            var i = off
            while i < source.count, source[i] != 0x0A { i += 1 }
            return min(i + 1, source.count)
        }
        var edits: [(Range<Int>, String)] = []

        /// Removes item `k`'s line. If no item after it remains, takes the line break
        /// before it (the array ends without its own break); otherwise, the one after.
        func stripLine(_ k: Int, keepsFollowing: Bool) {
            let lo = startOfLine(items[k].lowerBound)
            if keepsFollowing {
                edits.append((lo..<nextLine(items[k].lowerBound), ""))
            } else {
                var q = lo - 1
                if q > 0, source[q - 1] == 0x0D { q -= 1 }
                edits.append((q..<endOfContent(items[k].lowerBound), ""))
            }
        }

        if newItems.count < olds.count, let stays = subsequence(newItems, of: olds) {
            // removed items (the tag's × case): only each one's line goes away
            for k in olds.indices where !stays[k] {
                stripLine(k, keepsFollowing: stays[(k + 1)...].contains(true))
            }
        } else {
            let n = min(newItems.count, olds.count)
            for i in 0..<n where newItems[i] != olds[i] {
                edits.append((items[i], text(textOf(newItems[i]), source: source, range: items[i])))
            }
            if newItems.count > olds.count {
                // new lines right after the last one, with its start (indent, key, separator)
                let last = items[items.count - 1]
                let prefix = String(decoding: source[startOfLine(last.lowerBound)..<last.lowerBound], as: UTF8.self)
                var r = ""
                for v in newItems[olds.count...] {
                    var t = text(textOf(v), source: source, range: last)
                    // the space before a stuck-on comment doesn't apply here: the new line has no comment
                    if t.hasSuffix(" "), last.upperBound < source.count, source[last.upperBound] == 0x3B || source[last.upperBound] == 0x23 {
                        t.removeLast()
                    }
                    r += newline + prefix + t
                }
                edits.append((pos.range.upperBound..<pos.range.upperBound, r))
            } else {
                for k in n..<olds.count { stripLine(k, keepsFollowing: false) }
            }
        }

        // apply from end to start; adjacent removals merge
        var r = Array(source[pos.range])
        let base = pos.range.lowerBound
        var doneRanges: [Range<Int>] = []
        for (span, updated) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            var span = span
            if updated.isEmpty, let lastOne = doneRanges.last, lastOne.lowerBound < span.upperBound {
                span = span.lowerBound..<lastOne.lowerBound   // already partly removed
            }
            r.replaceSubrange((span.lowerBound - base)..<(span.upperBound - base), with: Array(updated.utf8))
            doneRanges.append(span)
        }
        return String(decoding: r, as: UTF8.self)
    }

    /// For each item of `olds`, whether it stays in `newItems` (which must be `olds` minus
    /// some items, in the same order). `nil` if it isn't.
    static func subsequence(_ newItems: [Value], of olds: [Value]) -> [Bool]? {
        var stays = [Bool](repeating: false, count: olds.count)
        var j = 0
        for (k, v) in olds.enumerated() where j < newItems.count && newItems[j] == v {
            stays[k] = true
            j += 1
        }
        return j == newItems.count ? stays : nil
    }
}
