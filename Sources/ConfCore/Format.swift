import Foundation

/// File formats the core can read and write.
///
/// Each format has its own reader (which keeps the byte range of every value)
/// and its own way of writing a new value mimicking the style of the old one; the rest
/// (editing, saving only the changed spans, on-screen fields) is shared.
public enum Format: String, Sendable, Hashable, CaseIterable {
    case toml
    /// JSON (RFC 8259) and JSONC (JSON with `//` and `/* */` comments and trailing comma).
    case json
    /// JSON5 (spec.json5.org): unquoted keys, single quotes, hexadecimal, `Infinity`, `NaN`…
    case json5
    /// Environment variables `KEY=value` (`.env`, `.env.local`, `production.env`).
    case env
    /// INI in the dialect described in `INIReader` (`.ini`, `.editorconfig`).
    case ini
    /// YAML 1.2, in the config-file subset described in `YAMLReader` (`.yaml`, `.yml`).
    case yaml

    /// Format from the file extension (without the dot, any case).
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "toml": self = .toml
        case "json", "jsonc": self = .json
        case "json5": self = .json5
        case "env": self = .env
        case "ini", "editorconfig": self = .ini
        case "yaml", "yml": self = .yaml
        default: return nil
        }
    }

    /// Format from the file name. First the extension; then the `.env` names,
    /// which often have no extension the system recognizes: macOS gives
    /// an empty `pathExtension` for `.env` and `local` for `.env.local`.
    public init?(fileName: String) {
        let n = fileName.lowercased()
        let ext = (n as NSString).pathExtension
        if n.hasPrefix(".") && !n.dropFirst().contains(".") {
            // `.env`, `.toml`: the whole name is the "extension" (`pathExtension` is empty)
            if let f = Format(fileExtension: String(n.dropFirst())) { self = f; return }
        }
        if let f = Format(fileExtension: ext), !(n.hasPrefix(".env.") && f != .env) {
            self = f
            return
        }
        if n == ".env" || n.hasPrefix(".env.") || n.hasSuffix(".env") {
            self = .env
            return
        }
        return nil
    }

    /// JSON, JSONC or JSON5: objects become sections, arrays of objects become groups.
    public var isJSON: Bool { self == .json || self == .json5 }

    public var name: String {
        switch self {
        case .toml: return "TOML"
        case .json: return "JSON"
        case .json5: return "JSON5"
        case .env: return ".env"
        case .ini: return "INI"
        case .yaml: return "YAML"
        }
    }

    /// Parses a whole file. JSON also accepts comments and trailing comma (JSONC).
    public func parse(_ bytes: [UInt8]) throws(ParseError) -> ConfDocument {
        switch self {
        case .toml: return try TOMLReader.parse(bytes)
        case .json: return try JSONReader.parse(bytes)
        case .json5: return try JSONReader.parseJSON5(bytes)
        case .env: return try EnvReader.parse(bytes)
        case .ini: return try INIReader.parse(bytes)
        case .yaml: return try YAMLReader.parse(bytes)
        }
    }

    /// Parses a standalone value, such as `[1, 2]` or `"abc"`.
    public func parseValue(_ text: String) throws(ParseError) -> Value {
        switch self {
        case .toml: return try TOMLReader.parseValue(text)
        case .json: return try JSONReader.parseValue(text)
        case .json5: return try JSONReader.parseValueJSON5(text)
        case .env: return try EnvReader.parseValue(text)
        case .ini: return try INIReader.parseValue(text)
        case .yaml: return try YAMLReader.parseValue(text)
        }
    }

    /// Writes a value mimicking the style of the old value (quotes, escapes, base, number shape…).
    public func write(_ v: Value, old: Value? = nil, position: Position? = nil, source: [UInt8] = [],
                         newline: String = "\n") -> String {
        switch self {
        case .toml: return TOMLFormat.value(v, old: old, position: position, source: source, newline: newline)
        case .json: return JSONFormat.value(v, old: old, position: position, source: source, newline: newline)
        case .json5:
            return JSONFormat.value(v, old: old, position: position, source: source, newline: newline, json5: true)
        case .env: return EnvFormat.value(v, position: position, source: source, newline: newline)
        case .ini: return INIFormat.value(v, old: old, position: position, source: source, newline: newline)
        case .yaml: return YAMLFormat.value(v, old: old, position: position, source: source, newline: newline)
        }
    }

    /// Raw text typed for a value, adjusted to the place it will go (in YAML: the space
    /// after an empty `key:` and the indentation of a block list). In the other formats, the text itself.
    public func adjustRaw(_ s: String, position: Position, source: [UInt8]) -> String {
        self == .yaml ? YAMLFormat.raw(s, position: position, source: source) : s
    }

    /// Reason the value cannot be written in this format, or `nil` if it can.
    public func problem(_ v: Value) -> String? {
        switch self {
        case .toml:
            if case .null = v { return NSLocalizedString("TOML has no null value", comment: "Value problem") }
        case .json:
            switch v {
            case .decimal(let d) where !d.isFinite: return String(format: NSLocalizedString("JSON does not accept %@", comment: "Value problem; %@ = number such as inf or nan"), TOMLFormat.decimal(d))
            case .dateTime: return String(format: NSLocalizedString("%@ has no date type", comment: "Value problem; %@ = format name"), "JSON")
            default: break
            }
        case .json5:
            if case .dateTime = v { return String(format: NSLocalizedString("%@ has no date type", comment: "Value problem; %@ = format name"), "JSON5") }
        case .env:
            if case .text = v { return nil }
            return NSLocalizedString("in .env every value is text", comment: "Value problem")
        case .ini:
            switch v {
            case .text(let s): return INIFormat.problem(s)
            case .array(let l):
                if l.isEmpty { return NSLocalizedString("an array 'key[]' needs at least one item; to delete it, use Text mode", comment: "Value problem (INI)") }
                for item in l {
                    guard case .text(let s) = item else { return NSLocalizedString("in INI every array item is text", comment: "Value problem") }
                    if let p = INIFormat.problem(s) { return p }
                }
                return nil
            default: return NSLocalizedString("in INI every value is text", comment: "Value problem")
            }
        case .yaml:
            if case .dateTime = v { return NSLocalizedString("YAML (core schema 1.2) has no date type; save it as text", comment: "Value problem") }
        }
        switch v {
        case .array(let l): return l.lazy.compactMap { problem($0) }.first
        case .table(let t): return t.pairs.lazy.compactMap { problem($0.value) }.first
        default: return nil
        }
    }
}
