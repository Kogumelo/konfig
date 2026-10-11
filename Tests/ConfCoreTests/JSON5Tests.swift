import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func k(_ parts: String...) -> ValuePath { parts.map { .key($0) } }

/// Applies one change to a JSON5 text and returns the new text.
private func swap5(_ text: String, _ path: ValuePath, _ v: Value) throws -> String {
    s(try Writer.apply(b(text), changes: [path: .value(v)], format: .json5))
}

/// Cases from the official json5/json5-tests suite, copied into `Fixtures/json5`.
/// By its rule: `.json` and `.json5` are valid; `.js` and `.txt` are invalid.
enum JSON5Suite {
    static let folder = Suite.folder.appendingPathComponent("json5")

    static let all: [String] = ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? [])
        .filter { ["json", "json5", "js", "txt"].contains(($0 as NSString).pathExtension) && $0 != "SOURCE.txt" }
        .sorted()
    static let valids = all.filter { $0.hasSuffix(".json") || $0.hasSuffix(".json5") }
    static let invalids = all.filter { $0.hasSuffix(".js") || $0.hasSuffix(".txt") }

    static func bytes(_ testCase: String) -> [UInt8] {
        Array(try! Data(contentsOf: folder.appendingPathComponent(testCase)))
    }
}

// MARK: - Conformance (json5-tests)

@Test func json5SuiteHasTheCases() {
    #expect(JSON5Suite.valids.count == 83)
    #expect(JSON5Suite.invalids.count == 31)
}

@Test(arguments: JSON5Suite.valids)
func json5Valid(_ testCase: String) throws {
    let bytes = JSON5Suite.bytes(testCase)
    let doc: ConfDocument
    do { doc = try JSONReader.parseJSON5(bytes) } catch {
        Issue.record("rejected a valid case: \(error)")
        return
    }
    #expect(doc.format == .json5 && doc.formatName == "JSON5")
    // the `.json` files are plain JSON: the same value the JSON reader and JSONSerialization read
    if testCase.hasSuffix(".json") {
        let json = try JSONReader.parse(bytes)
        #expect(json.rootValue == doc.rootValue)
        if testCase != "objects/duplicate-keys.json",
           let expected = try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) {
            let d = CompareJSON.value(doc.rootValue, expected, "$")
            #expect(d.isEmpty, "\(d.prefix(5).joined(separator: "\n"))")
        }
    }
}

@Test(arguments: JSON5Suite.invalids)
func json5Invalid(_ testCase: String) {
    do {
        let doc = try JSONReader.parseJSON5(JSON5Suite.bytes(testCase))
        Issue.record("accepted an invalid case: \(doc.rootValue)")
    } catch {
        #expect(error.line >= 1 && error.column >= 1)
        #expect(error.format == .json5)
    }
}

/// The value read from some `.json5` cases, checked by hand (the system cannot read JSON5).
@Test func json5SuiteValues() throws {
    func v(_ testCase: String) throws -> Value { try JSONReader.parseJSON5(JSON5Suite.bytes(testCase)).rootValue }
    #expect(try v("numbers/hexadecimal.json5") == .integer(0xC8))
    #expect(try v("numbers/negative-hexadecimal.json5") == .integer(-0xC8))
    #expect(try v("numbers/hexadecimal-with-integer-exponent.json5") == .integer(0xC8E4))
    #expect(try v("numbers/infinity.json5") == .decimal(.infinity))
    #expect(try v("numbers/negative-infinity.json5") == .decimal(-.infinity))
    #expect(try v("numbers/nan.json5") == .decimal(.nan))
    #expect(try v("numbers/float-leading-decimal-point.json5") == .decimal(0.5))
    #expect(try v("numbers/float-trailing-decimal-point.json5") == .decimal(5))
    #expect(try v("numbers/positive-integer.json5") == .integer(15))
    #expect(try v("numbers/negative-zero-float-leading-decimal-point.json5") == .decimal(-0.0))
    #expect(try v("strings/multi-line-string.json5") == .text("hello world"))
    #expect(try v("strings/escaped-single-quoted-string.json5") == .text("I can't wait"))
    #expect(try v("new-lines/escaped-cr.json5") == .table(Table(pairs: [.init(key: "a", value: .text("line 1 line 2"))])))
    #expect(try v("todo/unicode-escaped-unquoted-key.json5")
            == .table(Table(pairs: [.init(key: "sigΣma", value: .text("the sum of all things"))])))
    let readme = try JSONReader.parseJSON5(JSON5Suite.bytes("misc/readme-example.json5"))
    #expect(readme.root["hex"] == .integer(0xDEADBEEF))
    #expect(readme.root["half"] == .decimal(0.5))
    #expect(readme.root["delta"] == .integer(10))
    #expect(readme.root["to"] == .decimal(.infinity))
    #expect(readme.root["this"] == .text("is a multi-line string"))
    #expect(readme.entry(k("here"))?.trailingComment == "inline comment")
    #expect(readme.entry(k("to"))?.trailingComment == "and beyond!")
}

// MARK: - Round trip

private let json5Specials: [String: [UInt8]] = [
    "example": exampleJSON5Bytes(),
    "styles": b("""
    {
      // unquoted, single-quoted and double-quoted keys
      unquoted: 'single', 'single': "double", "double": 'it\\'s',
      $id_1: 0xff, b: 0XAB, c: -0x10, d: +7, e: .5, f: 5., g: +1.5e3, h: -.25, i: 5.e2,
      j: Infinity, k: -Infinity, l: +Infinity, m: NaN, n: -NaN,
      o: 'continues \\
    on the next line', p: '\\x41\\v\\0\\a', q: [1, 'two', 0x3,],
    }
    """),
    "crlf-bom": [0xEF, 0xBB, 0xBF] + b("{\r\n  // c\r\n  a: 'x\\\r\ny',\r\n  b: [\r\n    0x1,\r\n    .5,\r\n  ],\r\n}\r\n"),
    "cr": b("{\r  a: 1, // c\r  b: 'x\\\ry',\r}\r"),
    "whitespace": b("{\u{0B}a\u{0C}:\u{A0}1,\u{FEFF}b\u{2028}:\u{2029}2\u{3000}}"),
]

private func exampleJSON5Bytes() -> [UInt8] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    return Array(try! Data(contentsOf: root.appendingPathComponent("examples/config.json5")))
}

private let roundTripCases5 = JSON5Suite.valids + Array(json5Specials.keys).sorted()

@Test(arguments: roundTripCases5)
func json5NoChangeSameBytes(_ testCase: String) throws {
    let bytes = json5Specials[testCase] ?? JSON5Suite.bytes(testCase)
    var ed = EditSession(bytes, format: .json5)
    #expect(ed.document != nil, "\(ed.error.map { "\($0)" } ?? "")")
    #expect(try ed.result() == bytes)
    for e in ed.document?.entries ?? [] { try ed.assign(e.path, .value(e.value)) }
    #expect(ed.changes.isEmpty)
    #expect(try ed.result() == bytes)
    #expect(!ed.hasChanges)
}

@Test(arguments: roundTripCases5)
func json5ChangeEachValue(_ testCase: String) throws {
    let bytes = json5Specials[testCase] ?? JSON5Suite.bytes(testCase)
    let doc = try JSONReader.parseJSON5(bytes)
    for e in doc.entries {
        guard let updated = mutated(e.value), Format.json5.problem(updated) == nil else { continue }
        let output = try Writer.apply(doc, changes: [e.path: .value(updated)])
        #expect(onlyTheHunkChanged(bytes, output, e.range), "\(testCase) \(e.path.text)")
        let reparsed = try JSONReader.parseJSON5(output)
        #expect(reparsed.rootValue.value(at: e.path) == updated, "\(testCase) \(e.path.text)")
        #expect(reparsed.hasBOM == doc.hasBOM && reparsed.lineBreak == doc.lineBreak)
        // the value's style is kept
        let before = s(Array(bytes[e.range]))
        let after = s(Array(output[e.range.lowerBound..<(output.count - (bytes.count - e.range.upperBound))]))
        if case .text = e.value { #expect(before.first == after.first, "\(testCase): quotes \(before) → \(after)") }
        if case .integer = e.value, before.lowercased().contains("0x") {
            #expect(after.lowercased().contains("0x"), "\(testCase): hexadecimal \(before) → \(after)")
        }
    }
}

// MARK: - Style of each value on save

@Test func json5StringKeepsQuotes() throws {
    let t = "{a: 'one', b: \"two\", c: 'it\\'s', d: 'x\\\nend'}"
    #expect(try swap5(t, k("a"), .text("o'k \"yes\"")) == "{a: 'o\\'k \"yes\"', b: \"two\", c: 'it\\'s', d: 'x\\\nend'}")
    #expect(try swap5(t, k("b"), .text("it's")) == "{a: 'one', b: \"it's\", c: 'it\\'s', d: 'x\\\nend'}")
    #expect(try swap5(t, k("c"), .text("it's ok")) == "{a: 'one', b: \"two\", c: 'it\\'s ok', d: 'x\\\nend'}")
    // the line continuation stays where it was when the rest of the string does not change
    #expect(try swap5(t, k("d"), .text("xend!")) == "{a: 'one', b: \"two\", c: 'it\\'s', d: 'x\\\nend!'}")
    // escapes that only JSON5 has are copied as they were
    #expect(try swap5("{p: '\\x41\\v-'}", k("p"), .text("A\u{0B}+")) == "{p: '\\x41\\v+'}")
}

@Test func json5NumberKeepsShape() throws {
    let t = "{a: 0xff, b: 0X1F, c: 0x00FF, d: +7, e: .5, f: 5., g: +1.5e3, h: Infinity, i: NaN, j: 3}"
    #expect(try swap5(t, k("a"), .integer(4096)).contains("a: 0x1000,"))
    #expect(try swap5(t, k("a"), .integer(-1)).contains("a: -0x01,"))
    #expect(try swap5(t, k("b"), .integer(171)).contains("b: 0XAB,"))
    #expect(try swap5(t, k("c"), .integer(10)).contains("c: 0x000A,"))
    #expect(try swap5(t, k("d"), .integer(8)).contains("d: +8,"))
    #expect(try swap5(t, k("d"), .integer(-8)).contains("d: -8,"))
    #expect(try swap5(t, k("e"), .decimal(0.25)).contains("e: .25,"))
    #expect(try swap5(t, k("e"), .decimal(1.25)).contains("e: 1.25,"))
    #expect(try swap5(t, k("f"), .decimal(6)).contains("f: 6.,"))
    #expect(try swap5(t, k("f"), .decimal(6.5)).contains("f: 6.5,"))
    #expect(try swap5(t, k("g"), .decimal(2000)).contains("g: +2.0e3,"))
    #expect(try swap5(t, k("h"), .decimal(-.infinity)).contains("h: -Infinity,"))
    #expect(try swap5(t, k("h"), .decimal(2.5)).contains("h: 2.5,"))
    #expect(try swap5(t, k("i"), .decimal(.nan)) == t)
    #expect(try swap5(t, k("j"), .decimal(.nan)).contains("j: NaN}"))
    // JSON5 accepts infinity and NaN; JSON does not
    #expect(Format.json5.problem(.decimal(.infinity)) == nil)
    #expect(Format.json.problem(.decimal(.infinity)) != nil)
}

@Test func json5ArrayWithTrailingComma() throws {
    let t = "{\n  l: [\n    0x1, // one\n    'a',\n  ],\n}\n"
    // same count: only the item changes, the comment stays
    #expect(try swap5(t, k("l"), .array([.integer(2), .text("a")])) == "{\n  l: [\n    0x2, // one\n    'a',\n  ],\n}\n")
    // more items: rewritten with the first item's indentation and the trailing comma; each item in the old one's style
    #expect(try swap5(t, k("l"), .array([.integer(1), .text("a"), .text("b")]))
            == "{\n  l: [\n    0x1,\n    'a',\n    'b',\n  ],\n}\n")
}

// MARK: - Reading

@Test func json5KeysAndComments() throws {
    let t = """
    {
      // debug | info | error
      level: 'info',
      $port: 8080, // HTTP port
      'with space': true,
      ümlåût: 1,
      \\u0061b: 2,
    }
    """
    let doc = try JSONReader.parseJSON5(t)
    #expect(doc.root.pairs.map(\.key) == ["level", "$port", "with space", "ümlåût", "ab"])
    let fields = Dictionary(uniqueKeysWithValues: Fields.sections(doc).flatMap(\.fields).map { ($0.path, $0) })
    #expect(fields[k("level")]?.kind == .choice(["debug", "info", "error"]))
    #expect(fields[k("$port")]?.help == "HTTP port")
}

@Test func json5Errors() {
    for t in ["{1a: 1}", "{a-b: 1}", "[010]", "[0x]", "['a\nb']", "['\\1']", "[.]", "[+]", "{a: 1,,}", "[,]", "{'a' 1}"] {
        #expect(throws: ParseError.self, "\(t.debugDescription)") { try JSONReader.parseJSON5(t) }
    }
    // JSON and JSONC still reject what is JSON5-only
    for t in ["{a: 1}", "['x']", "[0x1]", "[Infinity]", "[.5]", "[+1]"] {
        #expect(throws: ParseError.self, "\(t.debugDescription)") { try JSONReader.parse(t) }
    }
    do {
        _ = try JSONReader.parseJSON5("{\n  a: 1,\n  b c\n}")
        Issue.record("should have been rejected")
    } catch {
        #expect(error.line == 3 && error.column == 5)
        #expect(error.localizedDescription.hasPrefix("invalid JSON5"))
    }
}

@Test func json5FormatFromExtension() {
    #expect(Format(fileExtension: "json5") == .json5)
    #expect(Format(fileName: "config.JSON5") == .json5)
    #expect(Format(fileName: "settings.jsonc") == .json)
    #expect(Format.json5.isJSON && Format.json.isJSON && !Format.toml.isJSON)
}

// MARK: - examples/config.json5

@Test func exampleJSON5() throws {
    let original = exampleJSON5Bytes()
    let doc = try JSONReader.parseJSON5(original)
    let sections = Fields.sections(doc)
    #expect(sections.map(\.title) == ["Root", "server", "database", "backup", "tasks[0].environment", "clean-logs"])
    let fields = Dictionary(uniqueKeysWithValues: sections.flatMap(\.fields).map { ($0.id, $0) })
    #expect(fields["server.log_level"]?.kind == .choice(["debug", "info", "warning", "error"]))
    #expect(fields["database.driver"]?.kind == .choice(["firebird", "postgres"]))
    #expect(fields["server.permissions"]?.kind == .integer)
    #expect(fields["database.row_limit"]?.kind == .decimal)
    #expect(fields["description"]?.value == .text("Dashboard for the Kogumelo and LanceWeb systems"))
    #expect(fields["title"]?.help == "Name shown at the top")

    var ed = EditSession(original, format: .json5)
    try ed.assign(k("database", "pool"), .value(.integer(20)))
    try ed.assign(k("database", "factor"), .value(.decimal(2.25)))
    try ed.assign(k("server", "permissions"), .value(.integer(0o750)))
    try ed.assign(k("server", "timeout"), .value(.decimal(0.75)))
    try ed.assign(k("server", "log_level"), .value(.text("warning")))
    try ed.assign([.key("tasks"), .index(0), .key("environment"), .key("DESTINATION")], .value(.text("/srv/backup")))
    let r = s(try ed.result())
    #expect(r == s(original)
        .replacingOccurrences(of: "pool: 12,", with: "pool: 20,")
        .replacingOccurrences(of: "factor: +1.50,", with: "factor: +2.25,")
        .replacingOccurrences(of: "permissions: 0x1ED,", with: "permissions: 0x1E8,")
        .replacingOccurrences(of: "timeout: .5,", with: "timeout: .75,")
        .replacingOccurrences(of: "log_level: 'info',", with: "log_level: 'warning',")
        .replacingOccurrences(of: "DESTINATION: '/mnt/backup'", with: "DESTINATION: '/srv/backup'"))
    // the neighbouring comments are still there
    #expect(r.contains("pool: 20, // simultaneous connections\n"))
    #expect(r.contains("// debug | info | warning | error\n    log_level: 'warning',"))
}
