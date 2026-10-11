import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func k(_ parts: String...) -> ValuePath { parts.map { .key($0) } }

/// Our own JSONC files (there is no official suite), in `Fixtures/jsonc`, plus the examples.
enum JSONCCases {
    static let folder = Suite.folder.appendingPathComponent("jsonc")
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static let fixtures: [String] = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasSuffix(".jsonc") }.sorted() ?? []
    static let examples = ["examples/config.jsonc", "examples/settings.jsonc"]
    static let all = fixtures + examples

    static func bytes(_ testCase: String) -> [UInt8] {
        let u = testCase.hasPrefix("examples/") ? root.appendingPathComponent(testCase) : folder.appendingPathComponent(testCase)
        return Array(try! Data(contentsOf: u))
    }
}

@Test func jsoncCasesPresent() {
    #expect(JSONCCases.fixtures == [
        "bom-crlf.jsonc", "bom.jsonc", "comments-in-every-position.jsonc", "crlf.jsonc",
        "slashes-inside-strings.jsonc", "trailing-comma.jsonc",
    ])
}

@Test(arguments: JSONCCases.all)
func jsoncNoChangeSameBytes(_ testCase: String) throws {
    let bytes = JSONCCases.bytes(testCase)
    var ed = EditSession(bytes, format: .json)
    #expect(ed.document?.usesJSONCExtensions == true, "\(ed.error.map { "\($0)" } ?? "")")
    // plain JSON rejects; JSONC accepts
    #expect(throws: ParseError.self) { try JSONReader.parse(bytes, strict: true) }
    #expect(try ed.result() == bytes)
    for e in ed.document?.entries ?? [] { try ed.assign(e.path, .value(e.value)) }
    #expect(ed.changes.isEmpty)
    #expect(try ed.result() == bytes)
}

@Test(arguments: JSONCCases.all)
func jsoncChangeEachValue(_ testCase: String) throws {
    let bytes = JSONCCases.bytes(testCase)
    let doc = try JSONReader.parse(bytes)
    #expect(!doc.entries.isEmpty)
    for e in doc.entries {
        guard let updated = mutated(e.value), Format.json.problem(updated) == nil else { continue }
        let output = try Writer.apply(doc, changes: [e.path: .value(updated)])
        #expect(onlyTheHunkChanged(bytes, output, e.range), "\(testCase) \(e.path.text)")
        let reparsed = try JSONReader.parse(output)
        #expect(reparsed.rootValue.value(at: e.path) == updated, "\(testCase) \(e.path.text)")
        #expect(reparsed.usesJSONCExtensions && reparsed.hasBOM == doc.hasBOM && reparsed.lineBreak == doc.lineBreak)
    }
}

// MARK: - Comments in every position

@Test func jsoncCommentsInEveryPosition() throws {
    let doc = try JSONReader.parse(JSONCCases.bytes("comments-in-every-position.jsonc"))
    let pure = try JSONReader.parse("""
        {"a": 1, "b": 2, "c": 3, "d": "x", "e": [1, 2, 3], "f": {}, "g": [], "h": {"i": true}}
        """, strict: true)
    #expect(doc.rootValue == pure.rootValue)
    #expect(doc.entry(k("a"))?.commentAbove == ["above the key"])
    #expect(doc.entry(k("a"))?.trailingComment == "end of line, after the comma")
    #expect(doc.entry(k("c"))?.trailingComment == "after the value, before the comma")
    #expect(doc.entry(k("d"))?.commentAbove == ["block", "of several", "lines"])
    #expect(doc.entry(k("e"))?.trailingComment == nil || doc.entry(k("e"))?.trailingComment == "after the [")
    #expect(doc.entry(k("h", "i"))?.commentAbove == ["nested"])
    #expect(doc.entry(k("h", "i"))?.trailingComment == "end")
    // changing "b", surrounded by comments on both sides, does not touch them
    let output = s(try Writer.apply(doc, changes: [k("b"): .value(.integer(20))]))
    #expect(output.contains(#""b" /* between key and colon */ : /* between colon and value */ 20,"#))
    // and the array, when its item count changes, is rewritten (comments inside it are lost, as in TOML)
    let l = s(try Writer.apply(doc, changes: [k("e"): .value(.array([.integer(1), .integer(2)]))]))
    #expect(l.contains("\"e\": [\n    1,\n    2\n  ],\n  \"f\""))
}

@Test func jsoncTrailingCommaKept() throws {
    let original = JSONCCases.bytes("trailing-comma.jsonc")
    var ed = EditSession(original, format: .json)
    try ed.assign(k("list"), .value(.array([.integer(1), .integer(2)])))
    try ed.assign(k("multiLineList"), .value(.array([.text("a"), .text("b"), .text("c")])))
    try ed.assign(k("multiLineObject", "y"), .value(.array([.boolean(true)])))
    try ed.assign(k("withComment"), .value(.array([.integer(10), .integer(25)])))
    let r = s(try ed.result())
    #expect(r.contains(#""list": [1, 2,],"#))
    #expect(r.contains("\"multiLineList\": [\n    \"a\",\n    \"b\",\n    \"c\",\n  ],"))
    #expect(r.contains(#""y": [true,],"#))
    // same count: the comments inside the array stay
    #expect(r.contains("10, // ten\n    25, /* twenty */\n  ],"))
    // no trailing comma in the original: none appears
    let withoutComma = #"{"l": [1, 2]}"#
    #expect(s(try Writer.apply(b(withoutComma), changes: [k("l"): .value(.array([.integer(3)]))], format: .json))
            == #"{"l": [3]}"#)
}

@Test func jsoncSlashesInsideStrings() throws {
    let doc = try JSONReader.parse(JSONCCases.bytes("slashes-inside-strings.jsonc"))
    #expect(doc.root["url"] == .text("http://example.com/a"))
    #expect(doc.root["open"] == .text("/* this is not a comment"))
    #expect(doc.root["close"] == .text("nor this */"))
    #expect(doc.root["double"] == .text("// nor this"))
    #expect(doc.root["quotes"] == .text("end with \\\" and // after"))
    #expect(doc.root["trailingBackslash"] == .text("c:\\folder\\"))
    #expect(doc.root["glob"] == .text("src/**/*.ts"))
    #expect(doc.entry(k("url"))?.trailingComment == "the URL has // and is not a comment")
    #expect(doc.entry(k("quotes"))?.trailingComment == "a real comment")
    #expect(doc.entry(k("trailingBackslash"))?.trailingComment == "text ending in a backslash")
    #expect(doc.entry(k("open"))?.trailingComment == nil)
}

@Test func jsoncCRLFAndBOM() throws {
    for testCase in ["crlf.jsonc", "bom.jsonc", "bom-crlf.jsonc"] {
        let original = JSONCCases.bytes(testCase)
        let doc = try JSONReader.parse(original)
        #expect(doc.hasBOM == testCase.hasPrefix("bom"), "\(testCase)")
        #expect(doc.lineBreak == (testCase.contains("crlf") ? "\r\n" : "\n"), "\(testCase)")
    }
    // an array that grows in a CRLF file: the new line breaks are CRLF too
    let crlf = JSONCCases.bytes("crlf.jsonc")
    let r = s(try Writer.apply(crlf, changes: [k("b"): .value(.array([.integer(1), .integer(2), .integer(3)]))],
                                 format: .json))
    #expect(r.contains("\"b\": [\r\n    1,\r\n    2,\r\n    3,\r\n  ],\r\n"))
    #expect(!r.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    // the BOM stays
    let bom = JSONCCases.bytes("bom.jsonc")
    let rb = try Writer.apply(bom, changes: [k("name"): .value(.text("Joana"))], format: .json)
    #expect(rb.starts(with: [0xEF, 0xBB, 0xBF]))
    #expect(s(rb).contains("\"name\": \"Joana\", /* accent */"))
}

// MARK: - examples/settings.jsonc

@Test func exampleSettingsJSONC() throws {
    let original = JSONCCases.bytes("examples/settings.jsonc")
    let doc = try JSONReader.parse(original)
    let sections = Fields.sections(doc)
    // keys containing a dot are shown in quotes, so they are not mistaken for a path
    #expect(sections.map(\.title) == ["Root", #""files.exclude""#, #""files.associations""#, #""[python]""#,
                                     #""[markdown]""#, #""terminal.integrated.env.osx""#])
    let fields = Dictionary(uniqueKeysWithValues: sections.flatMap(\.fields).map { ($0.path, $0) })
    #expect(fields[k("editor.wordWrap")]?.kind == .choice(["off", "on", "wordWrapColumn", "bounded"]))
    #expect(fields[k("editor.renderWhitespace")]?.kind == .choice(["none", "boundary", "selection", "trailing", "all"]))
    #expect(fields[k("files.autoSave")]?.kind == .choice(["off", "afterDelay", "onFocusChange", "onWindowChange"]))
    #expect(fields[k("editor.tabSize")]?.help == "spaces per tab")
    #expect(fields[k("editor.rulers")]?.kind == .array(.integer))

    var ed = EditSession(original, format: .json)
    try ed.assign(k("editor.fontSize"), .value(.integer(16)))
    try ed.assign(k("editor.wordWrap"), .value(.text("on")))
    try ed.assign(k("[python]", "editor.tabSize"), .value(.integer(2)))
    let r = s(try ed.result())
    #expect(r == s(original)
        .replacingOccurrences(of: "\"editor.fontSize\": 14,", with: "\"editor.fontSize\": 16,")
        .replacingOccurrences(of: "\"editor.wordWrap\": \"off\",", with: "\"editor.wordWrap\": \"on\",")
        .replacingOccurrences(of: "\"editor.tabSize\": 4,", with: "\"editor.tabSize\": 2,"))
    #expect(r.contains("// off | on | wordWrapColumn | bounded\n  \"editor.wordWrap\": \"on\","))
}
