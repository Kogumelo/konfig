import Foundation

/// The file's preamble comment: the comment lines before the first line with content
/// that are not attached to any field (a block right above the first key or section,
/// with no blank line in between, is already its help; in JSON nothing attaches to `{`).
///
/// The text has one line for each line of the file, from the first to the last comment
/// line: without the marker (`#`, `;`, `//`) and one space after it, keeping the
/// indentation that follows; blank lines and empty comments become empty lines.
public struct Preamble: Sendable, Equatable {
    public var text: String
    /// Lines of the file (starting at 0, not counting the BOM) taken by the comment.
    public var lines: Range<Int>

    static func markers(_ f: Format) -> [String] {
        switch f {
        case .toml, .yaml, .env: return ["#"]
        case .ini: return [";", "#"]
        case .json, .json5: return ["//"]
        }
    }

    /// Raw lines (with the `\r` of CRLF, if any) and the BOM separately.
    static func split(_ bytes: [UInt8]) -> (bom: [UInt8], lines: [[UInt8]]) {
        let bom: [UInt8] = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? [0xEF, 0xBB, 0xBF] : []
        let lines = bytes.dropFirst(bom.count).split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
        return (bom, lines)
    }

    static func trimmed(_ l: [UInt8]) -> String {
        String(decoding: l, as: UTF8.self).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\r")))
    }

    /// A file line as it appears in the comment text (`nil` if it has content).
    static func visibleText(_ l: [UInt8], _ markers: [String]) -> String? {
        let t = trimmed(l)
        if t.isEmpty { return "" }
        guard let m = markers.first(where: { t.hasPrefix($0) }) else { return nil }
        var rest = t.dropFirst(m.count)
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    public static func parse(_ bytes: [UInt8], format: Format) -> Preamble? {
        let markers = markers(format)
        let lines = split(bytes).lines
        var visible: [String] = []
        var lastBlock: Int? = nil   // where the current comment block starts
        var attached = false
        for l in lines {
            guard let v = visibleText(l, markers) else {
                attached = lastBlock != nil && !format.isJSON
                break
            }
            if trimmed(l).isEmpty { lastBlock = nil } else if lastBlock == nil { lastBlock = visible.count }
            visible.append(v)
        }
        // the block right above the first key or section is its help
        if attached, let b = lastBlock { visible.removeSubrange(b...) }
        // from the first to the last comment line (blank ones at the ends are left out)
        guard let end = visible.indices.last(where: { !trimmed(lines[$0]).isEmpty }),
              let start = visible.indices.first(where: { !trimmed(lines[$0]).isEmpty }) else { return nil }
        return Preamble(text: visible[start...end].joined(separator: "\n"), lines: start..<(end + 1))
    }

    /// The file's bytes with the preamble comment replaced by `updated`. Only the lines that
    /// changed are rewritten (unchanged ones stay byte for byte as they were), using the
    /// marker of the comment's first line and the file's line break. Empty text deletes
    /// the comment and the blank lines after it. `nil` if there is no comment.
    public static func replace(_ bytes: [UInt8], format: Format, by updated: String) -> [UInt8]? {
        guard let a = parse(bytes, format: format) else { return nil }
        var (bom, lines) = split(bytes)
        var newOnes = updated.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
        while newOnes.last?.isEmpty == true { newOnes.removeLast() }
        while newOnes.first?.isEmpty == true { newOnes.removeFirst() }
        let oldPrefs = a.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if newOnes == oldPrefs { return bytes }

        if newOnes.isEmpty {
            var end = a.lines.upperBound
            while end < lines.count - 1, trimmed(lines[end]).isEmpty { end += 1 }
            lines.removeSubrange(a.lines.lowerBound..<end)
            return bom + Array(lines.joined(separator: [0x0A]))
        }

        let firstOne = trimmed(lines[a.lines.lowerBound])
        let marker = markers(format).first { firstOne.hasPrefix($0) } ?? "#"
        let cr: [UInt8] = lines[a.lines.lowerBound].last == 0x0D ? [0x0D] : []
        // longest common subsequence: an unchanged line stays as it was in the file (marker,
        // spaces, blank line between blocks); a new line gets the marker
        let originals = Array(lines[a.lines])
        let n = oldPrefs.count, m = newOnes.count
        var t = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i][j] = oldPrefs[i] == newOnes[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var mid: [[UInt8]] = []
        var i = 0, j = 0
        while j < m {
            if i < n, oldPrefs[i] == newOnes[j] {
                mid.append(originals[i]); i += 1; j += 1
            } else if i < n, t[i + 1][j] >= t[i][j + 1] {
                i += 1
            } else {
                mid.append(Array((newOnes[j].isEmpty ? marker : marker + " " + newOnes[j]).utf8) + cr); j += 1
            }
        }
        lines.replaceSubrange(a.lines, with: mid)
        return bom + Array(lines.joined(separator: [0x0A]))
    }
}
