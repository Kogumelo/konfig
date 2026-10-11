import Foundation

/// Which control the screen uses for a value.
public enum FieldKind: Hashable, Sendable {
    case text
    case integer
    case decimal
    case boolean
    /// Text with options taken from an `a | b | c` comment.
    case choice([String])
    case date(DateTime.Kind)
    /// List of simple values, all of the same type (tags).
    case array(ValueKind)
    /// Raw text of the value, in the file's format (mixed arrays, inline tables, `null`…).
    case raw

    public var name: String {
        switch self {
        case .text: return NSLocalizedString("text", comment: "Field kind")
        case .integer: return NSLocalizedString("integer", comment: "Field kind")
        case .decimal: return NSLocalizedString("decimal", comment: "Field kind")
        case .boolean: return NSLocalizedString("yes/no", comment: "Field kind")
        case .choice: return NSLocalizedString("choice", comment: "Field kind")
        case .date(let t):
            switch t {
            case .withOffset: return NSLocalizedString("date-time with offset", comment: "Field kind")
            case .local: return NSLocalizedString("local date-time", comment: "Field kind")
            case .date: return NSLocalizedString("date", comment: "Field kind")
            case .time: return NSLocalizedString("time", comment: "Field kind")
            }
        case .array(let t): return String(format: NSLocalizedString("list of %@", comment: "Field kind; %@ = plural kind of the items, e.g. integers"), FieldKind.plural(t))
        case .raw: return NSLocalizedString("raw text", comment: "Field kind")
        }
    }

    /// Name for the screen; raw text takes the format's name ("TOML", "JSON").
    public func name(at format: Format) -> String {
        if case .raw = self { return format.name }
        return name
    }

    static func plural(_ t: ValueKind) -> String {
        switch t {
        case .text: return NSLocalizedString("texts", comment: "Plural kind, used in list of %@")
        case .integer: return NSLocalizedString("integers", comment: "Plural kind, used in list of %@")
        case .decimal: return NSLocalizedString("decimals", comment: "Plural kind, used in list of %@")
        case .boolean: return NSLocalizedString("yes/no", comment: "Field kind")
        case .dateTime, .localDateTime: return NSLocalizedString("date-times", comment: "Plural kind, used in list of %@")
        case .date: return NSLocalizedString("dates", comment: "Plural kind, used in list of %@")
        case .time: return NSLocalizedString("times", comment: "Plural kind, used in list of %@")
        case .array: return NSLocalizedString("lists", comment: "Plural kind, used in list of %@")
        case .table: return NSLocalizedString("tables", comment: "Plural kind, used in list of %@")
        case .null: return NSLocalizedString("nulls", comment: "Plural kind, used in list of %@")
        }
    }
}

/// A field on the screen, bound to a `key = value` line.
public struct Field: Identifiable, Sendable {
    public var id: String { path.text }
    public var path: ValuePath
    /// The key as written on the line.
    public var label: String
    public var kind: FieldKind
    public var value: Value
    /// Text of the value as it is in the file.
    public var originalText: String
    /// Comments above and at the end of the line, for help.
    public var help: String?
    public var line: Int
}

/// A section on the screen: the root, a `[table]` or an item of an `[[array]]`
/// (in JSON: a nested object or an object inside an array; in .env, only the root;
/// in INI, the "General" section and each `[section]`).
public struct FormSection: Identifiable, Sendable {
    /// Stable while the file's structure doesn't change: `rootID` or the header's path.
    public var id: String
    /// Id of the section with the root's own keys. Starts with a control character so it never
    /// collides with the path of a real table named `root`.
    public static let rootID = "\u{1}root"
    public var title: String
    /// How it appears in the file: `[server]`, `[[tasks]]` or "keys outside any table".
    public var subtitle: String
    /// For `[[array]]` items: the array's name (groups them in the sidebar).
    public var group: String?
    /// Position (starting at 0) and total of items in the `[[array]]`.
    public var itemIndex: Int?
    public var totalItems: Int?
    public var path: ValuePath
    public var fields: [Field]
    public var help: String?
}

public enum Fields {
    /// Builds the sections in file order.
    public static func sections(_ doc: ConfDocument) -> [FormSection] {
        // YAML is organized like JSON: maps become sections and arrays of maps, groups
        let json = doc.format.isJSON || doc.format == .yaml
        var bySection: [Int: [Field]] = [:]
        var root: [Field] = []
        for e in doc.entries {
            let c = field(e, doc: doc)
            if let s = e.section { bySection[s, default: []].append(c) } else { root.append(c) }
        }
        var r: [FormSection] = []
        if !root.isEmpty || doc.headers.isEmpty {
            var sub = NSLocalizedString("keys outside any table", comment: "Root section subtitle (TOML)")
            if json { if case .table = doc.rootValue { sub = NSLocalizedString("keys of the root object", comment: "Root section subtitle (JSON)") } else { sub = NSLocalizedString("the file's root value", comment: "Root section subtitle (JSON/YAML, root is not an object)") } }
            var title = NSLocalizedString("Root", comment: "Root section title")
            if doc.format == .env { title = NSLocalizedString("Variables", comment: "Root section title (.env)"); sub = NSLocalizedString("KEY=value (all values are text)", comment: "Root section subtitle (.env)") }
            if doc.format == .ini { title = NSLocalizedString("General", comment: "Root section title (INI)"); sub = NSLocalizedString("keys before the first section", comment: "Root section subtitle (INI)") }
            if doc.format == .yaml {
                if case .table = doc.rootValue { sub = NSLocalizedString("keys of the root map", comment: "Root section subtitle (YAML)") } else { sub = NSLocalizedString("the file's root value", comment: "Root section subtitle (JSON/YAML, root is not an object)") }
            }
            r.append(FormSection(id: FormSection.rootID, title: title, subtitle: sub, path: [], fields: root))
        }
        // total of items per array of tables (same path without the final index)
        var totals: [ValuePath: Int] = [:]
        for c in doc.headers where c.isArrayOfTables { totals[Array(c.path.dropLast()), default: 0] += 1 }

        for (i, c) in doc.headers.enumerated() {
            var name = c.names.map(PathSegment.formattedKey).joined(separator: ".")
            var subtitle = c.isArrayOfTables ? "[[\(name)]]" : "[\(name)]"
            if json {
                // in JSON the path has the array indices: `tasks[0].environment`
                let array = c.isArrayOfTables ? Array(c.path.dropLast()) : c.path
                name = array.isEmpty ? NSLocalizedString("(root)", comment: "Section title for an array at the root of a JSON/YAML file") : array.text
                let key: String
                switch array.last { case .key(let k)?: key = TOMLFormat.basicString(k) + ": "; default: key = "" }
                subtitle = c.isArrayOfTables ? key + "[ { … } ]" : key + "{ … }"
                if doc.format == .yaml {
                    let k: String
                    switch array.last { case .key(let x)?: k = x + ":"; default: k = "" }
                    subtitle = c.isArrayOfTables ? (k.isEmpty ? "- …" : k + " - …") : k + " …"
                }
            }
            if doc.format == .ini {
                // the name as written between the brackets (dots and spaces are literal)
                name = c.names.first ?? ""
                subtitle = "[\(name)]"
            }
            let fields = bySection[i] ?? []
            var s = FormSection(id: c.path.text, title: name, subtitle: subtitle, path: c.path, fields: fields)
            let help = (c.commentAbove + [c.trailingComment].compactMap { $0 }).filter { !$0.isEmpty }
            s.help = help.isEmpty ? nil : help.joined(separator: "\n")
            if c.isArrayOfTables, case .index(let k)? = c.path.last {
                s.group = name
                s.itemIndex = k
                s.totalItems = totals[Array(c.path.dropLast())]
                s.title = itemName(fields) ?? String(format: NSLocalizedString("item %ld", comment: "Title of an array-of-tables item without a name; %ld = position starting at 1"), k + 1)
            }
            r.append(s)
        }
        return r
    }

    /// Text of the file's preamble comment (see `Preamble`), or `nil` if there is none.
    public static func preambleComment(_ doc: ConfDocument) -> String? {
        Preamble.parse(doc.bytes, format: doc.format)?.text
    }

    /// Friendly name for an `[[array]]` item: value of `nome`, `name`, `titulo`, `title` or `id`.
    static func itemName(_ fields: [Field]) -> String? {
        for k in ["nome", "name", "titulo", "title", "id", "rotulo", "label"] {
            if let c = fields.first(where: { $0.label == k }) {
                switch c.value {
                case .text(let s) where !s.isEmpty: return s
                case .integer(let n): return "\(k) \(n)"
                default: break
                }
            }
        }
        return nil
    }

    public static func field(_ e: Entry, doc: ConfDocument) -> Field {
        let comments = (e.commentAbove + [e.trailingComment].compactMap { $0 }).filter { !$0.isEmpty }
        return Field(path: e.path, label: e.writtenKey, kind: kind(e), value: e.value,
                     originalText: doc.text(e.range),
                     help: comments.isEmpty ? nil : comments.joined(separator: "\n"),
                     line: e.line)
    }

    public static func kind(_ e: Entry) -> FieldKind {
        switch e.value {
        case .text(let s):
            for c in [e.trailingComment].compactMap({ $0 }) + e.commentAbove.reversed() {
                if var opts = options(c) {
                    if !opts.contains(s) { opts.insert(s, at: 0) }
                    return .choice(opts)
                }
            }
            return .text
        case .integer: return .integer
        case .decimal: return .decimal
        case .boolean: return .boolean
        case .dateTime(let d): return .date(d.kind)
        case .array(let items):
            guard let t = items.first?.kind, t != .array, t != .table,
                  items.allSatisfy({ $0.kind == t }) else { return .raw }
            // arrays with multi-line texts work better as raw text
            if items.contains(where: { if case .text(let s) = $0 { return s.contains("\n") }; return false }) {
                return .raw
            }
            return .array(t)
        case .table, .null: return .raw
        }
    }

    /// Reads `a | b | c` (with or without quotes around each option). Needs at least two options.
    public static func options(_ comment: String) -> [String]? {
        guard comment.contains("|") else { return nil }
        let parts = comment.split(separator: "|", omittingEmptySubsequences: false).map { p -> String in
            var s = p.trimmingCharacters(in: .whitespaces)
            if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
                s = String(s.dropFirst().dropLast())
            }
            return s
        }
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 40 }) else { return nil }
        return parts
    }
}
