import Foundation
import Testing
@testable import ConfCore
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func k(_ c: String) -> ValuePath { [.key(c)] }

/// Applies one change to a .env and returns the new text.
private func swap(_ text: String, _ key: String, _ v: String) throws -> String {
    s(try Writer.apply(b(text), changes: [k(key): .value(.text(v))], format: .env))
}

private func values(_ doc: ConfDocument) -> [String: String] {
    var r: [String: String] = [:]
    for e in doc.entries { if case .text(let t) = e.value { r[e.writtenKey] = t } }
    return r
}

enum EnvFixtures {
    static let folder = Suite.folder.appendingPathComponent("env")
    static let all: [String] = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasSuffix(".env") }.sorted() ?? []
    static func bytes(_ name: String) -> [UInt8] {
        Array(try! Data(contentsOf: folder.appendingPathComponent(name)))
    }
}

private let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

// MARK: - Reading rules

@Test func envHasFixtures() {
    #expect(EnvFixtures.all == ["basic.env", "bom.env", "crlf.env", "quotes.env"])
}

@Test func envBasicRules() throws {
    let doc = try EnvReader.parse(EnvFixtures.bytes("basic.env"))
    let v = values(doc)
    #expect(v["APP_NAME"] == "Konfig")
    #expect(v["APP_PORT"] == "8080", "export in front")
    #expect(v["INDENTED"] == "yes")
    #expect(v["SPACES_AROUND_EQUALS"] == "value with spaces", "leading/trailing spaces do not count")
    #expect(v["EMPTY"] == "")
    #expect(v["EMPTY_WITH_COMMENT"] == "")
    #expect(v["WITH_COMMENT"] == "abc")
    #expect(v["ATTACHED_HASH"] == "abc", "unquoted, # starts a comment even when attached (like dotenv)")
    #expect(v["LOG_LEVEL"] == "info")
    #expect(v["mode.dot-and-dash_1"] == "ok")
    #expect(v["export"] == "variable named export")
    #expect(v["URL"] == "postgres://u:p@localhost:5432/db?ssl=true&x=1")
    #expect(v["EQUALS_IN_VALUE"] == "a=b=c")
    #expect(v["APOSTROPHE_IN_MIDDLE"] == "it's")
    #expect(doc.entries.count == 14)
    #expect(doc.headers.isEmpty)
    #expect(doc.lineBreak == "\n" && !doc.hasBOM)

    let e = doc.entry(k("APP_NAME"))!
    #expect(e.commentAbove == ["App name"], "a blank line separates the file comment")
    #expect(doc.entry(k("WITH_COMMENT"))?.trailingComment == "comment at the end")
    #expect(doc.entry(k("ATTACHED_HASH"))?.trailingComment == "def")
    #expect(doc.entry(k("APP_PORT"))?.commentAbove == [])
    #expect(doc.entry(k("APP_PORT"))?.writtenKey == "APP_PORT")
    #expect(doc.text(doc.entry(k("SPACES_AROUND_EQUALS"))!.range) == "value with spaces")
}

@Test func envQuoteRules() throws {
    let doc = try EnvReader.parse(EnvFixtures.bytes("quotes.env"))
    let v = values(doc)
    #expect(v["SINGLE"] == #"literal \n no escape"#)
    #expect(v["SINGLE_WITH_HASH"] == "a # b")
    #expect(doc.entry(k("SINGLE_WITH_HASH"))?.trailingComment == "comment after")
    #expect(v["DOUBLE"] == "line1\nline2")
    #expect(v["DOUBLE_ESCAPES"] == "quotes \" and backslash \\ and cr \r end")
    #expect(v["UNKNOWN_BACKSLASH"] == #"c:\folder\data"#, "a backslash that is not an escape stays")
    #expect(v["EXPANSION"] == "${HOME}/bin and $USER", "no expansion")
    #expect(v["EXPANSION_UNQUOTED"] == "${HOME}/bin")
    #expect(v["HASH_INSIDE"] == "password#123")
    #expect(v["EMPTY_DOUBLE"] == "" && v["EMPTY_SINGLE"] == "")
    #expect(v["SPACES_INSIDE"] == "  with spaces  ")
    #expect(v["ACCENTS"] == "ação 😀")
    #expect(v["MULTI_LINE"] == "first\nsecond\nthird")
    #expect(v["MULTI_SINGLE"] == "-----BEGIN-----\nabc\n-----END-----")
    #expect(v["BACKTICK"] == "`text`", "a backtick is not a quote")
    #expect(v["AFTER"] == "end")
    let multi = doc.entry(k("MULTI_LINE"))!
    #expect(multi.lastLine == multi.line + 2)
    #expect(doc.entry(k("AFTER"))?.line == 20)
}

@Test func envCRLFAndBOM() throws {
    let crlf = try EnvReader.parse(EnvFixtures.bytes("crlf.env"))
    #expect(crlf.lineBreak == "\r\n")
    #expect(values(crlf) == ["A": "1", "B": "two\nparts", "C": "three", "MULTI": "x\ny", "D": "4"])
    #expect(crlf.entry(k("B"))?.commentAbove == ["help for B"])
    #expect(crlf.entry(k("B"))?.trailingComment == "end")
    #expect(crlf.entry(k("A"))?.commentAbove == ["comment"])
    let bom = try EnvReader.parse(EnvFixtures.bytes("bom.env"))
    #expect(bom.hasBOM)
    #expect(values(bom) == ["NAME": "ação", "EMPTY": "", "LAST": "no final newline"])
    #expect(bom.entry(k("NAME"))?.commentAbove == ["with BOM"])
}

@Test func envChoiceFromComment() throws {
    let doc = try EnvReader.parse(EnvFixtures.bytes("basic.env"))
    let sections = Fields.sections(doc)
    #expect(sections.count == 1)
    #expect(sections[0].title == "Variables")
    let fields = Dictionary(uniqueKeysWithValues: sections[0].fields.map { ($0.id, $0) })
    #expect(fields["LOG_LEVEL"]?.kind == .choice(["debug", "info", "warning", "error"]))
    #expect(fields["LOG_LEVEL"]?.help == "log level\ndebug | info | warning | error")
    #expect(fields["APP_PORT"]?.kind == .text, "in .env everything is text")
}

@Test(arguments: [
    ("A", 1, 2, "missing '='"),
    ("=1", 1, 1, "a variable name"),
    ("A 1", 1, 3, "expected '='"),
    ("A=1\nB=\"open\nC=3\n", 2, 3, "never closed"),
    ("A='x\n", 1, 3, "never closed"),
    ("A=\"x\" y\n", 1, 7, "may follow the quotes"),
    ("A=1\n\nA=2\n", 3, 1, "line 1"),
    ("export A\n", 1, 9, "missing '='"),
    ("A=1\rB=2\n", 1, 4, "lone CR"),
    ("ÇÃO=1\n", 1, 1, "a variable name"),
])
func envErrorsWithLineAndColumn(_ testCase: (String, Int, Int, String)) {
    do {
        let doc = try EnvReader.parse(testCase.0)
        Issue.record("accepted \(testCase.0.debugDescription): \(values(doc))")
    } catch {
        #expect(error.line == testCase.1 && error.column == testCase.2, "\(testCase.0.debugDescription): \(error)")
        #expect(error.message.contains(testCase.3), "\(error)")
        #expect(error.format == .env)
    }
}

@Test func envInvalidUTF8() {
    #expect(throws: ParseError.self) { try EnvReader.parse([0x41, 0x3D, 0xE7, 0x0A]) }
}

@Test func envParseValue() throws {
    #expect(try EnvReader.parseValue("abc") == .text("abc"))
    #expect(try EnvReader.parseValue(#""a\nb""#) == .text("a\nb"))
    #expect(try EnvReader.parseValue("'x y'") == .text("x y"))
    #expect(throws: ParseError.self) { try EnvReader.parseValue("abc # x") }
    #expect(throws: ParseError.self) { try EnvReader.parseValue("\"abc") }
}

// MARK: - Format from the file name

@Test func formatFromName() {
    #expect(Format(fileName: ".env") == .env)
    #expect(Format(fileName: ".env.local") == .env)
    #expect(Format(fileName: ".env.production") == .env)
    #expect(Format(fileName: "production.env") == .env)
    #expect(Format(fileName: "PRODUCTION.ENV") == .env)
    #expect(Format(fileName: "config.toml") == .toml)
    #expect(Format(fileName: "tsconfig.json") == .json)
    #expect(Format(fileName: "a.jsonc") == .json)
    #expect(Format(fileName: "environment.txt") == nil)
    #expect(Format(fileName: "readme") == nil)
    #expect(Format(fileName: ".envrc") == nil)
}

/// What macOS returns for `.env` names: that is why the format comes from the name, not just the extension.
@Test func systemExtensionForEnvFiles() throws {
    #expect(URL(fileURLWithPath: "/tmp/.env").pathExtension == "")
    #expect(URL(fileURLWithPath: "/tmp/.env.local").pathExtension == "local")
    #expect(URL(fileURLWithPath: "/tmp/production.env").pathExtension == "env")
    #if os(macOS)
    // File type the system assigns (with Konfig not registered): `.env` is generic "data".
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("konfig-env-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var kinds: [String: String] = [:]
    for n in [".env", ".env.local", "production.env"] {
        let u = folder.appendingPathComponent(n)
        try Data("A=1\n".utf8).write(to: u)
        kinds[n] = try u.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier ?? "-"
    }
    #expect(kinds[".env"] == "public.data", "\(kinds)")
    #expect(kinds[".env.local"]?.hasPrefix("dyn.") == true || kinds[".env.local"] == "br.com.kogut.konfig.env",
            "\(kinds)")
    #endif
}

// MARK: - Saving: quotes and style

@Test func envSaveKeepsQuotes() throws {
    // unquoted stays unquoted when it fits
    #expect(try swap("A=1\n", "A", "2") == "A=2\n")
    #expect(try swap("A=x # c\n", "A", "y") == "A=y # c\n")
    // does not fit unquoted: double quotes
    #expect(try swap("A=x # c\n", "A", "with space") == "A=\"with space\" # c\n")
    #expect(try swap("A=x\n", "A", "a#b") == "A=\"a#b\"\n")
    #expect(try swap("A=x\n", "A", "say \"hi\"") == #"A="say \"hi\"""# + "\n")
    #expect(try swap("A=x\n", "A", "it's") == "A=\"it's\"\n")
    #expect(try swap("A=x\n", "A", "a\nb") == #"A="a\nb""# + "\n")
    // empty
    #expect(try swap("A=\n", "A", "v") == "A=v\n")
    #expect(try swap("A=   # c\n", "A", "v") == "A=v   # c\n")
    #expect(try swap("A=x # c\n", "A", "") == "A= # c\n")
    #expect(try swap("A=x\n", "A", "") == "A=\n")
    // single stays single; if it does not fit ('), it becomes double
    #expect(try swap("A='x'\n", "A", "y z") == "A='y z'\n")
    #expect(try swap("A='x'\n", "A", "a\\nb") == "A='a\\nb'\n")
    #expect(try swap("A='x'\n", "A", "it's") == "A=\"it's\"\n")
    #expect(try swap("A='x'\n", "A", "a\nb") == #"A="a\nb""# + "\n")
    // multi-line single quotes stay multi-line, with the file's line break
    #expect(try swap("A='x\r\ny'\r\n", "A", "x\ny\nz") == "A='x\r\ny\r\nz'\r\n")
    // double stays double, escaping only what is needed
    #expect(try swap("A=\"x\"\n", "A", "y") == "A=\"y\"\n")
    #expect(try swap("A=\"x\"\n", "A", "c:\\dir") == #"A="c:\\dir""# + "\n")
    // double: matching start and end copied from the original (escapes and unknown backslashes included)
    #expect(try swap(#"A="a\nb end\"""# + "\n", "A", "a\nb middle end\"") == #"A="a\nb middle end\"""# + "\n")
    #expect(try swap(#"A="c:\folder""# + "\n", "A", #"c:\other"#) == #"A="c:\\other""# + "\n")
    // export and comment stay
    #expect(try swap("export A=1 # c\n", "A", "2") == "export A=2 # c\n")
}

@Test func envOnlyTextIsAccepted() {
    var ed = EditSession(b("A=1\n"), format: .env)
    #expect(throws: SaveError.self) { try ed.assign(k("A"), .value(.integer(2))) }
    #expect(throws: SaveError.self) { try ed.assign(k("A"), .value(.null)) }
    #expect(throws: SaveError.self) { try ed.assign(k("A"), .raw("x # y")) }
}

@Test func envSessionReplaceText() throws {
    var ed = EditSession(b("A=1\n"), format: .env)
    #expect(throws: ParseError.self) { try ed.replaceText(b("A=1\nB\n")) }
    try ed.replaceText(b("A=1\nB=2\n"))
    #expect(ed.document?.entries.count == 2)
}

// MARK: - Round trip and "only the hunk" (the same tests as TOML in WriterTests)

private let envSpecials: [String: [UInt8]] = [
    "empty": [],
    "comments-only": b("# nothing\n\n# here\n"),
    "no-final-newline": b("A=1\nB='two'"),
    "crlf-bom-quotes": [0xEF, 0xBB, 0xBF] + b("# c\r\nA=\"x\\ny\" # z\r\n\r\nexport B='q'\r\nC=\r\n"),
    "indented": b("  A = 1\n\tB=\t\"2\"\t# c\n"),
]

private func envCase(_ name: String) -> [UInt8] {
    if let x = envSpecials[name] { return x }
    if name == "examples/.env" { return Array(try! Data(contentsOf: projectRoot.appendingPathComponent(name))) }
    return EnvFixtures.bytes(name)
}

private let envCases = EnvFixtures.all + Array(envSpecials.keys).sorted() + ["examples/.env"]

@Test(arguments: envCases)
func envNoChangeSameBytes(_ testCase: String) throws {
    let original = envCase(testCase)
    var ed = EditSession(original, format: .env)
    #expect(ed.error == nil, "\(String(describing: ed.error))")
    #expect(try ed.result() == original)
    #expect(!ed.hasChanges)
    for e in ed.document?.entries ?? [] {
        try ed.assign(e.path, .value(e.value))
        try ed.assign(e.path, .raw(ed.document!.text(e.range)))
    }
    #expect(ed.changes.isEmpty)
    #expect(try ed.result() == original)
}

@Test(arguments: envCases)
func envChangeEachValue(_ testCase: String) throws {
    let original = envCase(testCase)
    let doc = try EnvReader.parse(original)
    for e in doc.entries {
        guard case .text(let t) = e.value else { Issue.record("value that is not text"); continue }
        // three changes: fits unquoted, needs quotes, and multiple lines
        for updated in [t + "x", t + " x'\"#$\\", "line1\nline2" + t] {
            let output: [UInt8]
            do { output = try Writer.apply(original, changes: [e.path: .value(.text(updated))], format: .env) } catch {
                Issue.record("\(testCase) \(e.writtenKey): \(error)")
                continue
            }
            #expect(onlyTheHunkChanged(original, output, e.range), "\(testCase) \(e.writtenKey): changed outside the hunk")
            let reparsed = try EnvReader.parse(output)
            #expect(reparsed.root == doc.root.replacing(e.path, by: .text(updated))!, "\(testCase) \(e.writtenKey)")
            #expect(reparsed.entries.map(\.trailingComment) == doc.entries.map(\.trailingComment))
            #expect(reparsed.hasBOM == doc.hasBOM && reparsed.lineBreak == doc.lineBreak)
            // the quote style is kept when the value fits in it
            let before = doc.bytes[e.range].first, after = reparsed.entry(e.path).map { reparsed.bytes[$0.range].first }
            if updated == t + "x", before == 0x22 || before == 0x27 { #expect(after == before, "\(testCase) \(e.writtenKey)") }
        }
    }
}

// MARK: - Example

@Test func exampleEnv() throws {
    let original = Array(try Data(contentsOf: projectRoot.appendingPathComponent("examples/.env")))
    let doc = try EnvReader.parse(original)
    let fields = Dictionary(uniqueKeysWithValues: Fields.sections(doc).flatMap(\.fields).map { ($0.id, $0) })
    #expect(fields["LOG_LEVEL"]?.kind == .choice(["debug", "info", "warning", "error"]))
    #expect(fields["DATABASE_DRIVER"]?.kind == .choice(["firebird", "postgres"]))
    #expect(fields["APP_TITLE"]?.help == "Name shown at the top")
    #expect(fields["DATABASE_POOL"]?.help == "simultaneous connections")
    #expect(fields["BACKUP_DESTINATION"]?.value == .text("${HOME}/backup"))

    var ed = EditSession(original, format: .env)
    try ed.assign(k("DATABASE_POOL"), .value(.text("20")))
    try ed.assign(k("LOG_LEVEL"), .value(.text("warning")))
    try ed.assign(k("APP_TITLE"), .value(.text("Kogumelo Dashboard 2")))
    try ed.assign(k("DATABASE_PASSWORD"), .value(.text("new password")))
    let r = s(try ed.result())
    #expect(r == s(original).replacingOccurrences(of: "DATABASE_POOL=12 ", with: "DATABASE_POOL=20 ")
        .replacingOccurrences(of: "LOG_LEVEL=info", with: "LOG_LEVEL=warning")
        .replacingOccurrences(of: "\"Kogumelo Dashboard\"", with: "\"Kogumelo Dashboard 2\"")
        .replacingOccurrences(of: "\"change#this password\"", with: "\"new password\""))
    #expect(Diff.lines(original, b(r)).count == 4)
}

// MARK: - JSON: assorted indentation (round-trip criterion)

@Test(arguments: [
    "{\n  \"a\": 1,\n  \"b\": [1, 2],\n  \"c\": {\"d\": \"x\"}\n}\n",
    "{\n    \"a\": 1,\n    \"b\": [\n        1,\n        2\n    ],\n    \"c\": {\n        \"d\": \"x\"\n    }\n}\n",
    "{\n\t\"a\": 1,\n\t\"b\": [\n\t\t1,\n\t\t2\n\t],\n\t\"c\": {\n\t\t\"d\": \"x\"\n\t}\n}",
    "{\"a\":1,\"b\":[1,2],\"c\":{\"d\":\"x\"}}",
    "{\r\n    \"a\": 1,\r\n    \"b\": [\r\n        1,\r\n        2\r\n    ],\r\n    \"c\": {\"d\": \"x\"}\r\n}\r\n",
])
func jsonIndentRoundTrip(_ text: String) throws {
    let original = b(text)
    let ed = EditSession(original, format: .json)
    #expect(try ed.result() == original)
    let doc = try JSONReader.parse(original)
    for e in doc.entries {
        guard let updated = mutated(e.value), Format.json.problem(updated) == nil else { continue }
        let output = try Writer.apply(doc, changes: [e.path: .value(updated)])
        #expect(onlyTheHunkChanged(original, output, e.range), "\(e.path.text)")
        #expect(try JSONReader.parse(output).rootValue.value(at: e.path) == updated)
    }
}

@Test func exampleJSON() throws {
    let original = Array(try Data(contentsOf: projectRoot.appendingPathComponent("examples/config.json")))
    let doc = try JSONReader.parse(original, strict: true)
    #expect(doc.formatName == "JSON")
    var ed = EditSession(original, format: .json)
    try ed.assign([.key("database"), .key("pool")], .value(.integer(20)))
    try ed.assign([.key("database"), .key("factor")], .value(.decimal(2)))
    try ed.assign([.key("database"), .key("limit")], .value(.decimal(2500)))
    let r = s(try ed.result())
    #expect(r == s(original).replacingOccurrences(of: "\"pool\": 12,", with: "\"pool\": 20,")
        .replacingOccurrences(of: "\"factor\": 1.50,", with: "\"factor\": 2.00,")
        .replacingOccurrences(of: "\"limit\": 1e3,", with: "\"limit\": 2.5e3,"))
}
