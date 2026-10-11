import Foundation

/// State of an open file: bytes on disk, base text and pending changes.
///
/// The base text starts equal to the disk and only changes when Text mode applies a
/// new text. Changes made in the form stay in `changes` and only become
/// bytes in `result()`, which replaces only the spans of the changed values.
public struct EditSession: Sendable {
    public let format: Format
    public private(set) var disk: [UInt8]
    public private(set) var base: [UInt8]
    public private(set) var changes: [ValuePath: NewValue] = [:]
    /// Parse of the base text (`nil` if it isn't valid in the format).
    public private(set) var document: ConfDocument?
    public private(set) var error: ParseError?

    public init(_ bytes: [UInt8], format: Format = .toml) {
        self.format = format
        disk = bytes
        base = bytes
        reparseBase()
    }

    private mutating func reparseBase() {
        do { document = try format.parse(base); error = nil } catch { document = nil; self.error = error }
    }

    /// Snapshot for undoing large operations (applying Text mode).
    public struct Snapshot: Sendable {
        var base: [UInt8]
        var changes: [ValuePath: NewValue]
    }

    public var snapshot: Snapshot { Snapshot(base: base, changes: changes) }

    public mutating func restore(_ snap: Snapshot) {
        let baseChanged = snap.base != base
        base = snap.base
        changes = snap.changes
        if baseChanged { reparseBase() }
    }

    /// Effective value (changed or original) of an entry.
    public func value(_ c: ValuePath) -> Value? {
        switch changes[c] {
        case .value(let v)?: return v
        case .raw(let s)?: return try? format.parseValue(s)
        case nil: return document?.entry(c)?.value
        }
    }

    /// Effective value as a `NewValue`, to store for undo.
    public func effective(_ c: ValuePath) -> NewValue? {
        if let change = changes[c] { return change }
        return document?.entry(c).map { .value($0.value) }
    }

    public func isChanged(_ c: ValuePath) -> Bool { changes[c] != nil }

    /// Sets the value of an entry. If equal to the base text's, the change goes away.
    public mutating func assign(_ c: ValuePath, _ updated: NewValue) throws {
        guard let doc = document, let e = doc.entry(c) else {
            throw SaveError(String(format: NSLocalizedString("the key '%@' does not exist in the file", comment: "Save error; %@ = key path"), c.text))
        }
        switch updated {
        case .value(let v):
            if let p = format.problem(v) { throw SaveError(p) }
            if v == e.value { changes[c] = nil } else { changes[c] = updated }
        case .raw(let s):
            do { _ = try format.parseValue(s) } catch {
                throw SaveError(String(format: NSLocalizedString("invalid value: %@", comment: "Save error; %@ = parse error"), "\(error)"))
            }
            if Array(s.utf8) == Array(doc.bytes[e.range]) { changes[c] = nil } else { changes[c] = updated }
        }
    }

    /// Bytes to write. Without changes, it is exactly the base text.
    public func result() throws -> [UInt8] {
        guard !changes.isEmpty else { return base }
        guard let doc = document else { throw SaveError(String(format: NSLocalizedString("the file is not valid %@", comment: "Save error; %@ = format name, e.g. TOML"), format.name)) }
        return try Writer.apply(doc, changes: changes)
    }

    /// Is anything different from the disk?
    public var hasChanges: Bool {
        guard let r = try? result() else { return true }
        return r != disk
    }

    /// The file is valid, but uses something outside the subset the form edits
    /// (`ParseError.outsideSubset`): it can only be edited as text.
    public var textOnly: Bool { document == nil && error?.outsideSubset == true }

    /// Replaces the whole text (Text mode). Only accepts text valid in the format; a text outside
    /// the form's subset is also accepted (it stays in Text mode only, saved as is).
    public mutating func replaceText(_ updated: [UInt8]) throws(ParseError) {
        do { _ = try format.parse(updated) } catch where error.outsideSubset {}
        base = updated
        changes = [:]
        reparseBase()
    }

    /// After saving: the disk becomes what was written. If something changed during
    /// the save (background autosave), those changes stay pending.
    public mutating func saved(_ bytes: [UInt8]) {
        disk = bytes
        guard (try? result()) == bytes else { return }
        if bytes != base {
            base = bytes
            reparseBase()
        }
        changes = [:]
    }
}


// MARK: - Line diff

/// A changed span between two texts.
public struct Hunk: Sendable, Identifiable, Hashable {
    public var id: Int { lineAfter * 100_000 + lineBefore }
    /// First line (starting at 1) of the span in the old and in the new text.
    public var lineBefore: Int
    public var lineAfter: Int
    public var removed: [String]
    public var added: [String]
}

public enum Diff {
    static func split(_ b: [UInt8]) -> [String] {
        if b.isEmpty { return [] }
        var lines = b.split(separator: 0x0A, omittingEmptySubsequences: false).map { l -> String in
            var l = l
            if l.last == 0x0D { l = l.dropLast() }
            return String(decoding: l, as: UTF8.self)
        }
        if b.last == 0x0A { lines.removeLast() }
        return lines
    }

    /// Differing spans between `before` and `after`, line by line.
    public static func lines(_ before: [UInt8], _ after: [UInt8]) -> [Hunk] {
        if before == after { return [] }
        let old = split(before), new = split(after)
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var endOld = old.count, endNew = new.count
        while endOld > start, endNew > start, old[endOld - 1] == new[endNew - 1] { endOld -= 1; endNew -= 1 }
        let midOld = Array(old[start..<endOld]), midNew = Array(new[start..<endNew])
        if midOld.isEmpty && midNew.isEmpty {
            // only the line ending changed (CRLF × LF, BOM): show the first line
            return [Hunk(lineBefore: 1, lineAfter: 1, removed: Array(old.prefix(1)), added: Array(new.prefix(1)))]
        }
        guard midOld.count * midNew.count <= 4_000_000 else {
            return [Hunk(lineBefore: start + 1, lineAfter: start + 1, removed: midOld, added: midNew)]
        }
        // longest common subsequence
        let n = midOld.count, m = midNew.count
        var t = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i][j] = midOld[i] == midNew[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var r: [Hunk] = []
        var i = 0, j = 0
        var current: Hunk? = nil
        func close() { if let x = current { r.append(x); current = nil } }
        while i < n || j < m {
            if i < n, j < m, midOld[i] == midNew[j] {
                close(); i += 1; j += 1
            } else if j < m, i == n || t[i][j + 1] >= t[i + 1][j] {
                if current == nil { current = Hunk(lineBefore: start + i + 1, lineAfter: start + j + 1, removed: [], added: []) }
                current!.added.append(midNew[j]); j += 1
            } else {
                if current == nil { current = Hunk(lineBefore: start + i + 1, lineAfter: start + j + 1, removed: [], added: []) }
                current!.removed.append(midOld[i]); i += 1
            }
        }
        close()
        return r
    }
}
