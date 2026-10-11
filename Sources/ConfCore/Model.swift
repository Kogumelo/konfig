import Foundation

// MARK: - Paths

/// One step in the path to a value: a key name or a position in an `[[array of tables]]`.
public enum PathSegment: Hashable, Sendable, CustomStringConvertible {
    case key(String)
    case index(Int)

    public var description: String {
        switch self {
        case .key(let k): return PathSegment.formattedKey(k)
        case .index(let i): return "[\(i)]"
        }
    }

    /// Key name as written in TOML: unquoted when it is a bare key.
    public static func formattedKey(_ k: String) -> String {
        if !k.isEmpty, k.utf8.allSatisfy(isBareKeyChar) { return k }
        return TOMLFormat.basicString(k)
    }
}

/// Full path of a value, for example `tasks[0].name`.
public typealias ValuePath = [PathSegment]

extension Array where Element == PathSegment {
    /// Readable form: `server.ports`, `tasks[1].cron`.
    public var text: String {
        var s = ""
        for seg in self {
            switch seg {
            case .key:
                if !s.isEmpty { s += "." }
                s += seg.description
            case .index:
                s += seg.description
            }
        }
        return s
    }
}

@inline(__always)
func isBareKeyChar(_ c: UInt8) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D
}

// MARK: - Dates

/// The four TOML date/time types in a single structure.
public struct DateTime: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// `1979-05-27T07:32:00Z` or with `-03:00`
        case withOffset
        /// `1979-05-27T07:32:00`
        case local
        /// `1979-05-27`
        case date
        /// `07:32:00`
        case time
    }

    public var kind: Kind
    public var year = 0, month = 1, day = 1
    public var hour = 0, minute = 0, second = 0
    /// Fraction of a second in nanoseconds.
    public var nanos = 0
    /// How many fraction digits the text had (0 = none). Used only for writing.
    public var fractionDigits = 0
    /// Offset in minutes for `withOffset`; 0 with `Z`.
    public var offsetMinutes = 0
    /// `true` when the offset was written as `Z` (not `+00:00`).
    public var offsetIsZ = true

    public init(kind: Kind) { self.kind = kind }

    public var hasDate: Bool { kind != .time }
    public var hasTime: Bool { kind != .date }

    /// Text in RFC 3339 (the same format TOML writes), with `T` between date and time.
    public var iso: String { text(separator: "T", lowercaseZ: false) }

    public func text(separator: Character, lowercaseZ: Bool) -> String {
        var s = ""
        if hasDate {
            s += pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
        }
        if hasTime {
            if hasDate { s.append(separator) }
            s += pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2)
            // Keeps the original's digits, but never fewer than the value needs.
            var needed = 0
            if nanos > 0 {
                var t = pad(nanos, 9)
                while t.hasSuffix("0") { t.removeLast() }
                needed = t.count
            }
            let places = min(9, max(fractionDigits, needed))
            if places > 0 { s += "." + pad(nanos, 9).prefix(places) }
        }
        if kind == .withOffset {
            if offsetIsZ && offsetMinutes == 0 {
                s += lowercaseZ ? "z" : "Z"
            } else {
                let m = abs(offsetMinutes)
                s += (offsetMinutes < 0 ? "-" : "+") + pad(m / 60, 2) + ":" + pad(m % 60, 2)
            }
        }
        return s
    }

    private func pad(_ n: Int, _ w: Int) -> String {
        let s = String(n)
        return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
    }
}

// MARK: - Values

public enum ValueKind: String, Sendable {
    case text, integer, decimal, boolean, dateTime, localDateTime, date, time, array, table, null

    /// Short localized name for the UI.
    public var name: String {
        switch self {
        case .text: return NSLocalizedString("text", comment: "Value kind name")
        case .integer: return NSLocalizedString("integer", comment: "Value kind name")
        case .decimal: return NSLocalizedString("decimal", comment: "Value kind name")
        case .boolean: return NSLocalizedString("yes/no", comment: "Value kind name")
        case .dateTime: return NSLocalizedString("date-time with offset", comment: "Value kind name")
        case .localDateTime: return NSLocalizedString("local date-time", comment: "Value kind name")
        case .date: return NSLocalizedString("date", comment: "Value kind name")
        case .time: return NSLocalizedString("time", comment: "Value kind name")
        case .array: return NSLocalizedString("array", comment: "Value kind name")
        case .table: return NSLocalizedString("table", comment: "Value kind name")
        case .null: return NSLocalizedString("null", comment: "Value kind name")
        }
    }
}

/// An already-interpreted value (TOML or JSON). `null` only exists in JSON.
public indirect enum Value: Sendable, Hashable {
    case text(String)
    case integer(Int64)
    case decimal(Double)
    case boolean(Bool)
    case dateTime(DateTime)
    case array([Value])
    case table(Table)
    /// JSON `null`.
    case null

    public var kind: ValueKind {
        switch self {
        case .text: return .text
        case .integer: return .integer
        case .decimal: return .decimal
        case .boolean: return .boolean
        case .dateTime(let d):
            switch d.kind {
            case .withOffset: return .dateTime
            case .local: return .localDateTime
            case .date: return .date
            case .time: return .time
            }
        case .array: return .array
        case .table: return .table
        case .null: return .null
        }
    }

    // Strict equality: strings compared scalar by scalar (TOML does not
    // normalize Unicode) and `nan` equal to `nan`.
    public static func == (a: Value, b: Value) -> Bool {
        switch (a, b) {
        case (.text(let x), .text(let y)): return x.unicodeScalars.elementsEqual(y.unicodeScalars)
        case (.integer(let x), .integer(let y)): return x == y
        case (.decimal(let x), .decimal(let y)): return (x.isNaN && y.isNaN) || (x == y && x.sign == y.sign)
        case (.boolean(let x), .boolean(let y)): return x == y
        case (.dateTime(let x), .dateTime(let y)): return x.equivalent(y)
        case (.array(let x), .array(let y)): return x == y
        case (.table(let x), .table(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public func hash(into h: inout Hasher) {
        switch self {
        case .text(let s): h.combine(0); for u in s.unicodeScalars { h.combine(u.value) }
        case .integer(let n): h.combine(1); h.combine(n)
        case .decimal(let d): h.combine(2); if d.isNaN { h.combine(-1) } else { h.combine(d.bitPattern) }
        case .boolean(let b): h.combine(3); h.combine(b)
        case .dateTime(let d): h.combine(4); h.combine(d.iso)
        case .array(let l): h.combine(5); h.combine(l)
        case .table(let t): h.combine(6); h.combine(t)
        case .null: h.combine(7)
        }
    }
}

extension DateTime {
    /// Same instant/value, ignoring only writing details (fraction digits, `Z` × `+00:00`).
    public func equivalent(_ o: DateTime) -> Bool {
        kind == o.kind && year == o.year && month == o.month && day == o.day && hour == o.hour
            && minute == o.minute && second == o.second && nanos == o.nanos && offsetMinutes == o.offsetMinutes
    }
}

/// Table with key order preserved.
public struct Table: Sendable, Hashable {
    public struct Pair: Sendable, Hashable {
        public var key: String
        public var value: Value
        public init(key: String, value: Value) { self.key = key; self.value = value }
        public static func == (a: Pair, b: Pair) -> Bool {
            a.key.unicodeScalars.elementsEqual(b.key.unicodeScalars) && a.value == b.value
        }
        public func hash(into h: inout Hasher) {
            for u in key.unicodeScalars { h.combine(u.value) }
            h.combine(value)
        }
    }

    public var pairs: [Pair]

    public init(pairs: [Pair] = []) { self.pairs = pairs }

    public subscript(key: String) -> Value? {
        get { pairs.first { $0.key.unicodeScalars.elementsEqual(key.unicodeScalars) }?.value }
        set {
            if let i = pairs.firstIndex(where: { $0.key.unicodeScalars.elementsEqual(key.unicodeScalars) }) {
                if let v = newValue { pairs[i].value = v } else { pairs.remove(at: i) }
            } else if let v = newValue {
                pairs.append(Pair(key: key, value: v))
            }
        }
    }

    // Equality regardless of order (order is a writing detail).
    public static func == (a: Table, b: Table) -> Bool {
        guard a.pairs.count == b.pairs.count else { return false }
        for p in a.pairs {
            guard let v = b[p.key], v == p.value else { return false }
        }
        return true
    }

    public func hash(into h: inout Hasher) { h.combine(pairs.count) }

    /// Value at the given path (keys and `[[array]]` indices).
    public func value(at path: ValuePath) -> Value? { Value.table(self).value(at: path) }

    /// Copy with the value at the path replaced. Returns `nil` if the path does not exist.
    public func replacing(_ path: ValuePath, by updated: Value) -> Table? {
        guard case .table(let t)? = Value.table(self).replacing(path, by: updated) else { return nil }
        return t
    }
}

extension Value {
    /// Value at the given path; an empty path is the value itself.
    public func value(at path: ValuePath) -> Value? {
        var current = self
        for seg in path {
            switch (seg, current) {
            case (.key(let k), .table(let t)):
                guard let v = t[k] else { return nil }
                current = v
            case (.index(let i), .array(let l)):
                guard l.indices.contains(i) else { return nil }
                current = l[i]
            default:
                return nil
            }
        }
        return current
    }

    /// Copy with the value at the path replaced (an empty path replaces the whole value).
    /// Returns `nil` if the path does not exist.
    public func replacing(_ path: ValuePath, by updated: Value) -> Value? {
        Value.swap(self, path[...], updated)
    }

    private static func swap(_ current: Value, _ rest: ArraySlice<PathSegment>, _ updated: Value) -> Value? {
        guard let seg = rest.first else { return updated }
        switch (seg, current) {
        case (.key(let k), .table(var t)):
            guard let v = t[k], let n = swap(v, rest.dropFirst(), updated) else { return nil }
            t[k] = n
            return .table(t)
        case (.index(let i), .array(var l)):
            guard l.indices.contains(i), let n = swap(l[i], rest.dropFirst(), updated) else { return nil }
            l[i] = n
            return .array(l)
        default:
            return nil
        }
    }
}

// MARK: - Positions in the text

/// Where a value is in the original text. For arrays, also keeps the position of each item.
public struct Position: Sendable, Hashable {
    /// UTF-8 byte range of the value, counted from the start of the file (BOM included).
    public var range: Range<Int>
    /// Items of an array, in order (empty for the other kinds).
    public var items: [Position]

    public init(range: Range<Int>, items: [Position] = []) {
        self.range = range
        self.items = items
    }
}

/// A `key = value` line of the file.
public struct Entry: Sendable {
    /// Full path, with indices for `[[array]]` items.
    public var path: ValuePath
    /// The key as it appears on the line (may have dots: `apple.color`).
    public var writtenKey: String
    public var value: Value
    public var kind: ValueKind { value.kind }
    /// Position of the value (and of the items, if it is an array).
    public var position: Position
    /// UTF-8 byte range of the value in the original text.
    public var range: Range<Int> { position.range }
    /// Byte range of the key.
    public var keyRange: Range<Int>
    /// Line (starting at 1) where the key is.
    public var line: Int
    /// Line where the value ends (arrays and multiline strings span more than one).
    public var lastLine: Int
    /// Comment lines right above, without the `#` and without surrounding spaces.
    public var commentAbove: [String]
    /// Comment at the end of the line, if any.
    public var trailingComment: String?
    /// Index in `ConfDocument.headers` of the section the line is in (`nil` = root).
    public var section: Int?
}

/// A section of the file: in TOML, a `[table]` or `[[array of tables]]` header;
/// in JSON, a nested `{…}` object or an object inside an array of objects.
public struct SectionHeader: Sendable {
    /// Concrete path of the table (with index for `[[array]]` items).
    public var path: ValuePath
    /// Header names, without indices.
    public var names: [String]
    public var isArrayOfTables: Bool
    /// Byte range of the whole header, brackets included (in JSON, the `{…}` object).
    public var range: Range<Int>
    public var line: Int
    public var commentAbove: [String]
    public var trailingComment: String?
}

/// Result of parsing a file (TOML or JSON).
public struct ConfDocument: Sendable {
    public var format: Format
    /// Bytes exactly as they were read.
    public var bytes: [UInt8]
    /// The value of the whole file: in TOML always a table; in JSON, any value.
    public var rootValue: Value
    /// Each `key = value` (in JSON, each object member that is not a section), in file order.
    public var entries: [Entry]
    /// Each section (TOML header or JSON object), in file order.
    public var headers: [SectionHeader]
    /// `"\r\n"` if the first line break of the file is CRLF; otherwise `"\n"`.
    public var lineBreak: String
    public var hasBOM: Bool
    /// JSON with comments or trailing comma (JSONC). Always `false` in TOML.
    public var usesJSONCExtensions = false

    public init(format: Format = .toml, bytes: [UInt8], root: Value, entries: [Entry], headers: [SectionHeader],
                lineBreak: String, hasBOM: Bool, usesJSONCExtensions: Bool = false) {
        self.format = format
        self.bytes = bytes
        self.rootValue = root
        self.entries = entries
        self.headers = headers
        self.lineBreak = lineBreak
        self.hasBOM = hasBOM
        self.usesJSONCExtensions = usesJSONCExtensions
    }

    public init(bytes: [UInt8], root: Table, entries: [Entry], headers: [SectionHeader],
                lineBreak: String, hasBOM: Bool) {
        self.init(format: .toml, bytes: bytes, root: .table(root), entries: entries, headers: headers,
                  lineBreak: lineBreak, hasBOM: hasBOM)
    }

    /// The root as a table (empty when a JSON root is not an object).
    public var root: Table {
        if case .table(let t) = rootValue { return t }
        return Table()
    }

    /// Format name as shown on screen: "TOML", "JSON" or "JSONC".
    public var formatName: String { usesJSONCExtensions ? "JSONC" : format.name }

    /// Entry by exact path.
    public func entry(_ path: ValuePath) -> Entry? {
        entries.first { $0.path == path }
    }

    /// Original text of a range.
    public func text(_ r: Range<Int>) -> String {
        String(decoding: bytes[r], as: UTF8.self)
    }
}


/// Parse error with position (line and column start at 1; column counts characters).
public struct ParseError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public var message: String
    public var line: Int
    public var column: Int
    /// Byte offset in the text.
    public var offset: Int
    public var format: Format = .toml
    /// The file uses something the reader recognizes but does not interpret (in YAML: anchors,
    /// tags, multiple documents…). Not a syntax error: the file can be edited
    /// as text, just not through the form.
    public var outsideSubset = false

    public var description: String {
        String(format: NSLocalizedString("line %ld, column %ld: %@", comment: "Parse error position; %ld = line, %ld = column, %@ = message"), line, column, message)
    }
    public var errorDescription: String? {
        outsideSubset
            ? String(format: NSLocalizedString("%@ outside the subset supported by the form, at %@", comment: "Parse error; %@ = format name, %@ = position and message"), format.name, description)
            : String(format: NSLocalizedString("invalid %@ at %@", comment: "Parse error; %@ = format name, %@ = position and message"), format.name, description)
    }
}

