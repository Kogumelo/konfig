import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func k(_ parts: String...) -> ValuePath { parts.map { .key($0) } }

/// Applies one change to a JSON text and returns the new text.
private func swap(_ text: String, _ path: ValuePath, _ v: Value) throws -> String {
    s(try Writer.apply(b(text), changes: [path: .value(v)], format: .json))
}

/// JSONTestSuite cases (nst/JSONTestSuite, `test_parsing`), copied into `Fixtures/JSONTestSuite`.
enum JSONSuite {
    static let folder = Suite.folder.appendingPathComponent("JSONTestSuite/test_parsing")

    static let all: [String] = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasSuffix(".json") }.sorted() ?? []
    static let y = all.filter { $0.hasPrefix("y_") }
    static let n = all.filter { $0.hasPrefix("n_") }
    static let i = all.filter { $0.hasPrefix("i_") }

    static func bytes(_ testCase: String) -> [UInt8] {
        Array(try! Data(contentsOf: folder.appendingPathComponent(testCase)))
    }

    /// `n_` cases rejected by plain JSON but accepted in JSONC: their only "error" is a
    /// comment or a trailing comma.
    static let nAcceptedInJSONC: Set<String> = [
        "n_array_extra_comma.json",                    // ["",]
        "n_array_number_and_comma.json",               // [1,]
        "n_object_trailing_comma.json",                // {"id":0,}
        "n_object_trailing_comment.json",              // {"a":"b"}/**/
        "n_object_trailing_comment_slash_open.json",   // {"a":"b"}//
        "n_structure_object_with_comment.json",        // {"a":/*comment*/"b"}
    ]

    /// What Konfig does with each `i_` case (the specification leaves it up to the reader).
    /// `true` = accepted. Documented in the README.
    static let casesI: [String: Bool] = [
        // out-of-range numbers: accepted; an integer that does not fit in 64 bits becomes an
        // approximate decimal, a huge exponent becomes infinity or zero. Rewritten only if edited.
        "i_number_double_huge_neg_exp.json": true,
        "i_number_huge_exp.json": true,
        "i_number_neg_int_huge_exp.json": true,
        "i_number_pos_double_huge_exp.json": true,
        "i_number_real_neg_overflow.json": true,
        "i_number_real_pos_overflow.json": true,
        "i_number_real_underflow.json": true,
        "i_number_too_big_neg_int.json": true,
        "i_number_too_big_pos_int.json": true,
        "i_number_very_big_negative_int.json": true,
        // UTF-8 BOM at the start: accepted and kept on save
        "i_structure_UTF-8_BOM_empty_object.json": true,
        // 500 nesting levels: rejected (the limit is 128, to protect the stack)
        "i_structure_500_nested_arrays.json": false,
        // unpaired surrogate \u escapes: rejected (they do not fit in valid Unicode text)
        "i_object_key_lone_2nd_surrogate.json": false,
        "i_string_1st_surrogate_but_2nd_missing.json": false,
        "i_string_1st_valid_surrogate_2nd_invalid.json": false,
        "i_string_incomplete_surrogate_and_escape_valid.json": false,
        "i_string_incomplete_surrogate_pair.json": false,
        "i_string_incomplete_surrogates_escape_valid.json": false,
        "i_string_invalid_lonely_surrogate.json": false,
        "i_string_invalid_surrogate.json": false,
        "i_string_inverted_surrogates_U+1D11E.json": false,
        "i_string_lone_second_surrogate.json": false,
        // bytes that are not valid UTF-8 (including ISO-8859-1 and UTF-16): rejected
        "i_string_UTF-16LE_with_BOM.json": false,
        "i_string_UTF-8_invalid_sequence.json": false,
        "i_string_UTF8_surrogate_U+D800.json": false,
        "i_string_invalid_utf-8.json": false,
        "i_string_iso_latin_1.json": false,
        "i_string_lone_utf8_continuation_byte.json": false,
        "i_string_not_in_unicode_range.json": false,
        "i_string_overlong_sequence_2_bytes.json": false,
        "i_string_overlong_sequence_6_bytes.json": false,
        "i_string_overlong_sequence_6_bytes_null.json": false,
        "i_string_truncated-utf-8.json": false,
        "i_string_utf16BE_no_BOM.json": false,
        "i_string_utf16LE_no_BOM.json": false,
    ]

    static func fixture(_ name: String) -> [UInt8] {
        Array(try! Data(contentsOf: Suite.folder.appendingPathComponent("json/" + name)))
    }
}

// MARK: - Conformance (JSONTestSuite)

@Test func jsonSuiteHasTheCases() {
    #expect(JSONSuite.y.count == 95)
    #expect(JSONSuite.n.count == 188)
    #expect(JSONSuite.i.count == 35)
    #expect(Set(JSONSuite.casesI.keys) == Set(JSONSuite.i), "every i_ case must be documented")
}

@Test(arguments: JSONSuite.y)
func jsonY(_ testCase: String) throws {
    let bytes = JSONSuite.bytes(testCase)
    let doc: ConfDocument
    do { doc = try JSONReader.parse(bytes, strict: true) } catch {
        Issue.record("rejected a valid case: \(error)")
        return
    }
    #expect(!doc.usesJSONCExtensions)
    // the same value the system's JSONSerialization reads — except for a repeated key:
    // it keeps the first; here the last one wins, as in JavaScript, Python and Go
    if testCase == "y_object_duplicated_key.json" {
        #expect(doc.rootValue == .table(Table(pairs: [.init(key: "a", value: .text("c"))])))
    } else if let expected = try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) {
        let d = CompareJSON.value(doc.rootValue, expected, "$")
        #expect(d.isEmpty, "\(d.prefix(5).joined(separator: "\n"))")
    }
    // and the JSONC reader (the default) accepts it the same way
    #expect(try JSONReader.parse(bytes).rootValue == doc.rootValue)
}

@Test(arguments: JSONSuite.n)
func jsonN(_ testCase: String) {
    let bytes = JSONSuite.bytes(testCase)
    do {
        let doc = try JSONReader.parse(bytes, strict: true)
        Issue.record("plain JSON accepted an invalid case: \(doc.rootValue)")
    } catch {
        #expect(error.line >= 1 && error.column >= 1)
    }
    let acceptedInJSONC = (try? JSONReader.parse(bytes)) != nil
    #expect(acceptedInJSONC == JSONSuite.nAcceptedInJSONC.contains(testCase),
            "JSONC \(acceptedInJSONC ? "accepted" : "rejected") \(testCase)")
}

@Test(arguments: JSONSuite.i)
func jsonI(_ testCase: String) {
    let accepted = (try? JSONReader.parse(JSONSuite.bytes(testCase), strict: true)) != nil
    #expect(accepted == JSONSuite.casesI[testCase], "\(testCase): \(accepted ? "accepted" : "rejected")")
}

/// Compares with what `JSONSerialization` read.
enum CompareJSON {
    static func value(_ v: Value, _ j: Any, _ place: String) -> [String] {
        switch (v, j) {
        case (.table(let t), let d as NSDictionary):
            var r: [String] = []
            if t.pairs.count != d.count { r.append("\(place): \(t.pairs.count) keys, expected \(d.count)") }
            for case let (k as String, x) in d {
                guard let y = t[k] else { r.append("\(place): missing \(k)"); continue }
                r += value(y, x, place + "." + k)
            }
            return r
        case (.array(let l), let a as NSArray):
            guard l.count == a.count else { return ["\(place): \(l.count) items, expected \(a.count)"] }
            return zip(l, a).enumerated().flatMap { i, p in value(p.0, p.1, "\(place)[\(i)]") }
        case (.text(let x), let y as String):
            return x.unicodeScalars.elementsEqual(y.unicodeScalars) ? [] : ["\(place): \(x.debugDescription) ≠ \(y.debugDescription)"]
        case (.null, is NSNull):
            return []
        case (.boolean(let x), _) where boolean(j) != nil:
            return x == boolean(j) ? [] : ["\(place): \(x) ≠ \(j)"]
        case (.integer(let x), _) where boolean(j) == nil && number(j) != nil:
            return Double(x) == number(j) ? [] : ["\(place): \(x) ≠ \(j)"]
        case (.decimal(let x), _) where boolean(j) == nil && number(j) != nil:
            // JSONSerialization converts through NSDecimalNumber and may be off in the last digit
            let y = number(j)!
            return x == y || abs(x - y) <= abs(x) * 1e-15 ? [] : ["\(place): \(x) ≠ \(j)"]
        default:
            return ["\(place): \(v) ≠ \(j)"]
        }
    }

    /// `true`/`false` from JSONSerialization (on the Mac, a CFBoolean; on Linux, an NSNumber of type "c" or a Bool).
    static func boolean(_ j: Any) -> Bool? {
        #if canImport(Darwin)
        if let n = j as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
        #else
        if let n = j as? NSNumber { return String(cString: n.objCType) == "c" ? n.boolValue : nil }
        return j as? Bool
        #endif
    }

    static func number(_ j: Any) -> Double? {
        if let n = j as? NSNumber { return n.doubleValue }
        if let i = j as? Int { return Double(i) }
        return j as? Double
    }
}

// MARK: - Round trip: opening and saving without changes is identical; a change touches only its hunk

private let jsonSpecials: [String: [UInt8]] = [
    "tsconfig": JSONSuite.fixture("tsconfig.json"),
    "crlf-bom": [0xEF, 0xBB, 0xBF] + b("{\r\n  // c\r\n  \"a\": 1,\r\n  \"b\": [\r\n    \"x\",\r\n    \"y\",\r\n  ],\r\n  \"c\": {\"d\": null}\r\n}\r\n"),
    "root-array": b("[\n  {\"name\": \"a\", \"n\": 1},\n  {\"name\": \"b\", \"n\": 2}\n]\n"),
    "root-scalar": b("  \"just some text\"  \n"),
    "escapes": b(#"{"url": "http:\/\/example.com\/a", "name": "José 😀", "t": "a\tb\nc"}"#),
    "numbers": b(#"{"a": 1.50, "b": 1.5e3, "c": 2E+10, "d": -0.0, "e": 0, "f": 12345678901234567890, "g": [1, 2.0, 3e1]}"#),
    "repeated-key": b(#"{"a": 1, "b": 2, "a": 3}"#),
]

@Test(arguments: JSONSuite.y + Array(jsonSpecials.keys).sorted())
func jsonNoChangeSameBytes(_ testCase: String) throws {
    let bytes = jsonSpecials[testCase] ?? JSONSuite.bytes(testCase)
    var ed = EditSession(bytes, format: .json)
    #expect(ed.document != nil)
    #expect(try ed.result() == bytes)
    // setting each field to its current value changes nothing
    for e in ed.document?.entries ?? [] { try ed.assign(e.path, .value(e.value)) }
    #expect(ed.changes.isEmpty)
    #expect(try ed.result() == bytes)
    #expect(!ed.hasChanges)
}

/// Checks that only the value's range changed: everything before and after is identical, byte for byte.
private func onlyTheHunkChangedJSON(_ before: [UInt8], _ after: [UInt8], _ r: Range<Int>) -> Bool {
    let suffix = before.count - r.upperBound
    guard after.count >= r.lowerBound + suffix else { return false }
    return after.prefix(r.lowerBound).elementsEqual(before.prefix(r.lowerBound))
        && after.suffix(suffix).elementsEqual(before.suffix(suffix))
}

@Test(arguments: JSONSuite.y + Array(jsonSpecials.keys).sorted())
func jsonChangeEachValue(_ testCase: String) throws {
    let bytes = jsonSpecials[testCase] ?? JSONSuite.bytes(testCase)
    let doc = try JSONReader.parse(bytes)
    for e in doc.entries {
        guard let updated = mutated(e.value), Format.json.problem(updated) == nil else { continue }
        let output = try Writer.apply(doc, changes: [e.path: .value(updated)])
        #expect(onlyTheHunkChangedJSON(bytes, output, e.range), "\(testCase) \(e.path.text)")
        let reparsed = try JSONReader.parse(output)
        #expect(reparsed.rootValue.value(at: e.path) == updated, "\(testCase) \(e.path.text)")
        #expect(reparsed.usesJSONCExtensions == doc.usesJSONCExtensions, "\(testCase): the dialect must not change")
        #expect(reparsed.hasBOM == doc.hasBOM && reparsed.lineBreak == doc.lineBreak)
    }
}

// MARK: - tsconfig.json with comments and trailing commas

@Test func tsconfigReadWithComments() throws {
    let doc = try JSONReader.parse(JSONSuite.fixture("tsconfig.json"))
    #expect(doc.usesJSONCExtensions)
    #expect(doc.formatName == "JSONC")
    #expect(throws: ParseError.self) { try JSONReader.parse(JSONSuite.fixture("tsconfig.json"), strict: true) }

    let sections = Fields.sections(doc)
    #expect(sections.map(\.title) == ["Root", "compilerOptions", "compilerOptions.paths"])
    #expect(sections[0].fields.map(\.label) == ["include", "exclude"])
    #expect(sections[1].help == "Visit https://aka.ms/tsconfig to read more about this file")
    #expect(sections[2].fields.map(\.label) == ["@/*", "~utils/*"])

    let fields = Dictionary(uniqueKeysWithValues: sections.flatMap(\.fields).map { ($0.id, $0) })
    let target = try #require(fields["compilerOptions.target"])
    #expect(target.kind == .choice(["es2017", "es2020", "es2022", "esnext"]))
    #expect(target.help == "Language and Environment\nes2017 | es2020 | es2022 | esnext")
    #expect(fields["compilerOptions.module"]?.help == "Modules")
    #expect(fields["compilerOptions.skipLibCheck"]?.help == "speeds up the build")
    #expect(fields["compilerOptions.lib"]?.kind == .array(.text))
    #expect(fields["compilerOptions.strict"]?.kind == .boolean)
    #expect(fields["compilerOptions.maxNodeModuleJsDepth"]?.kind == .integer)
    #expect(fields["include"]?.line == 30)
}

@Test func tsconfigChangeTouchesOnlyHunk() throws {
    let original = JSONSuite.fixture("tsconfig.json")
    var ed = EditSession(original, format: .json)
    try ed.assign(k("compilerOptions", "target"), .value(.text("esnext")))
    try ed.assign(k("compilerOptions", "strict"), .value(.boolean(false)))
    try ed.assign(k("include"), .value(.array([.text("src/**/*.ts"), .text("src/**/*.tsx"), .text("tests/**/*.ts")])))
    try ed.assign(k("compilerOptions", "paths", "@/*"), .value(.array([.text("./app/*")])))
    let output = try ed.result()
    let expected = s(original)
        .replacingOccurrences(of: #""target": "es2022""#, with: #""target": "esnext""#)
        .replacingOccurrences(of: #""strict": true"#, with: #""strict": false"#)
        .replacingOccurrences(of: "    \"src/**/*.tsx\",\n", with: "    \"src/**/*.tsx\",\n    \"tests/**/*.ts\",\n")
        .replacingOccurrences(of: #""@/*": ["./src/*"]"#, with: #""@/*": ["./app/*"]"#)
    #expect(s(output) == expected)
    let diffList = Diff.lines(original, output)
    #expect(diffList.count == 4)
    // the comments and trailing commas are still there
    #expect(s(output).contains("// es2017 | es2020 | es2022 | esnext"))
    #expect(s(output).contains("\"skipLibCheck\": true, // speeds up the build\n  },"))
}

@Test func tsconfigUndoRestoresOriginal() throws {
    let original = JSONSuite.fixture("tsconfig.json")
    var ed = EditSession(original, format: .json)
    try ed.assign(k("compilerOptions", "outDir"), .value(.text("./build")))
    #expect(ed.hasChanges)
    try ed.assign(k("compilerOptions", "outDir"), .value(.text("./dist")))
    #expect(!ed.hasChanges)
    #expect(try ed.result() == original)
}

// MARK: - Strings: quotes and escapes from the original

@Test func stringKeepsEscapes() throws {
    let t = #"{"url": "http:\/\/example.com\/a", "name": "José", "x": "Olá"}"#
    #expect(try swap(t, k("url"), .text("http://example.com/b/c")) == #"{"url": "http:\/\/example.com\/b\/c", "name": "José", "x": "Olá"}"#)
    #expect(try swap(t, k("name"), .text("José Ação")) == #"{"url": "http:\/\/example.com\/a", "name": "José Ação", "x": "Olá"}"#)
    #expect(try swap(t, k("x"), .text("Olá 😀")) == #"{"url": "http:\/\/example.com\/a", "name": "José", "x": "Olá 😀"}"#)
    // a string with no style hint, in a file that is ASCII-only and escapes non-ASCII
    #expect(try swap(#"{"a": "x", "b": "é"}"#, k("a"), .text("ç")) == #"{"a": "ç", "b": "é"}"#)
    // a file with literal accented characters: literal accented characters
    #expect(try swap(#"{"a": "x", "b": "é"}"#, k("a"), .text("ç")) == #"{"a": "ç", "b": "é"}"#)
    // quotes, backslash, line breaks and control characters are always escaped
    #expect(try swap(#"{"a": ""}"#, k("a"), .text("a\"b\\c\nd\u{1}")) == #"{"a": "a\"b\\c\nd\u0001"}"#)
    // an unchanged start and end stay as they were, even if written another way
    #expect(try swap(#"{"a": "ABC\tend"}"#, k("a"), .text("ABX\tend")) == #"{"a": "ABX\tend"}"#)
}

@Test func numberKeepsShape() throws {
    let t = #"{"a": 1.50, "b": 1.5e3, "c": 2E+10, "d": -0.5, "e": 7, "f": 1e-7}"#
    #expect(try swap(t, k("a"), .decimal(2.5)).contains(#""a": 2.50,"#))
    #expect(try swap(t, k("a"), .decimal(0.125)).contains(#""a": 0.125,"#))
    #expect(try swap(t, k("b"), .decimal(2000)).contains(#""b": 2.0e3,"#))
    #expect(try swap(t, k("b"), .decimal(0.00025)).contains(#""b": 2.5e-4,"#))
    #expect(try swap(t, k("c"), .decimal(3e12)).contains(#""c": 3E+12,"#))
    #expect(try swap(t, k("d"), .decimal(3)).contains(#""d": 3.0,"#))
    #expect(try swap(t, k("e"), .integer(-42)).contains(#""e": -42,"#))
    #expect(try swap(t, k("f"), .decimal(2e-7)).contains(#""f": 2e-7}"#))
    // a decimal always stays a decimal when read back
    #expect(JSONFormat.decimal(1e21, style: "0.5") == "1e21")
    #expect(JSONFormat.decimal(100, style: nil) == "100.0")
    #expect(JSONFormat.decimal(-0.0, style: nil) == "-0.0")
    // JSON has neither infinity nor NaN
    #expect(throws: SaveError.self) { try swap(t, k("a"), .decimal(.infinity)) }
}

// MARK: - Structure

@Test func repeatedKeyLastWins() throws {
    let t = #"{"a": 1, "b": 2, "a": 3}"#
    let doc = try JSONReader.parse(t)
    #expect(doc.root["a"] == .integer(3))
    #expect(doc.root.pairs.map(\.key) == ["a", "b"])
    #expect(doc.entries.map(\.path.text) == ["b", "a"])
    #expect(try swap(t, k("a"), .integer(9)) == #"{"a": 1, "b": 2, "a": 9}"#)
}

@Test func rootArrayOfObjectsBecomesSections() throws {
    let doc = try JSONReader.parse(jsonSpecials["root-array"]!)
    let sections = Fields.sections(doc)
    #expect(sections.map(\.title) == ["a", "b"])
    #expect(sections.map(\.group) == ["(root)", "(root)"])
    #expect(sections[1].fields.map(\.path.text) == ["[1].name", "[1].n"])
    #expect(s(try Writer.apply(doc, changes: [[.index(1), .key("n")]: .value(.integer(5))]))
            == "[\n  {\"name\": \"a\", \"n\": 1},\n  {\"name\": \"b\", \"n\": 5}\n]\n")
}

@Test func scalarRootIsEditable() throws {
    let t = "  \"just some text\"  \n"
    #expect(try swap(t, [], .text("other")) == "  \"other\"  \n")
    let doc = try JSONReader.parse(t)
    #expect(Fields.sections(doc).first?.fields.map(\.label) == ["(root)"])
}

@Test func nullAndRawInJSON() throws {
    let t = "{\n  \"a\": null,\n  \"b\": [1, \"x\"]\n}\n"
    var ed = EditSession(b(t), format: .json)
    let doc = try #require(ed.document)
    #expect(Fields.kind(doc.entry(k("a"))!) == .raw)
    #expect(Fields.kind(doc.entry(k("b"))!) == .raw)
    try ed.assign(k("a"), .raw(#"{"x": 1}"#))
    try ed.assign(k("b"), .raw("[\n    2\n  ]"))
    #expect(s(try ed.result()) == "{\n  \"a\": {\"x\": 1},\n  \"b\": [\n    2\n  ]\n}\n")
    #expect(throws: SaveError.self) { try ed.assign(k("a"), .raw("{x: 1}")) }
}

@Test func pureJSONStaysPure() throws {
    let t = "{\n  \"a\": [1, 2]\n}\n"
    // a raw value with a comment would turn the file into JSONC: rejected on save
    #expect(throws: SaveError.self) {
        try Writer.apply(b(t), changes: [k("a"): .raw("[1, 2, /* three */ 3]")], format: .json)
    }
    // already JSONC: allowed
    let c = "{\n  // c\n  \"a\": [1, 2]\n}\n"
    #expect(s(try Writer.apply(b(c), changes: [k("a"): .raw("[1, /* x */ 3]")], format: .json))
            == "{\n  // c\n  \"a\": [1, /* x */ 3]\n}\n")
}

@Test func multiLineArrayJSONC() throws {
    let t = "{\n  \"l\": [\n    1, // one\n    2,\n  ],\n}\n"
    // same number of items: only the item changes, the comment stays
    #expect(try swap(t, k("l"), .array([.integer(1), .integer(5)])) == "{\n  \"l\": [\n    1, // one\n    5,\n  ],\n}\n")
    // more items: rewritten with the first item's indentation and the trailing comma
    #expect(try swap(t, k("l"), .array([.integer(1), .integer(2), .integer(3)]))
            == "{\n  \"l\": [\n    1,\n    2,\n    3,\n  ],\n}\n")
    // no trailing comma in the original: none is added
    let p = "{\n  \"l\": [\n    1,\n    2\n  ]\n}\n"
    #expect(try swap(p, k("l"), .array([.integer(1)])) == "{\n  \"l\": [\n    1\n  ]\n}\n")
}

@Test func blockCommentAsHelpAndChoice() throws {
    let t = """
    {
      /* Log level
       * debug | info | error
       */
      "log": "info",

      // separated by a blank line: not the help of "b"

      "b": 1
    }
    """
    let doc = try JSONReader.parse(t)
    let e = try #require(doc.entry(k("log")))
    #expect(e.commentAbove == ["Log level", "debug | info | error"])
    #expect(Fields.kind(e) == .choice(["debug", "info", "error"]))
    #expect(doc.entry(k("b"))?.commentAbove == [])
}

@Test func errorsWithLineAndColumn() {
    do {
        _ = try JSONReader.parse("{\n  \"a\": 1,\n  \"b\" 2\n}")
        Issue.record("should have been rejected")
    } catch {
        #expect(error.line == 3 && error.column == 7)
        #expect(error.format == .json)
        #expect(error.localizedDescription.hasPrefix("invalid JSON"))
    }
    #expect(throws: ParseError.self) { try JSONReader.parse("{\"a\": 1,}", strict: true) }
    #expect(throws: ParseError.self) { try JSONReader.parse("{'a': 1}") }
    #expect(throws: ParseError.self) { try JSONReader.parse("/* no end") }
    #expect(throws: ParseError.self) { try JSONReader.parse("") }
}

@Test func sessionReplaceTextJSON() throws {
    var ed = EditSession(b("{\"a\": 1}"), format: .json)
    #expect(throws: ParseError.self) { try ed.replaceText(b("{\"a\": }")) }
    try ed.replaceText(b("{\"a\": 2, \"b\": true}"))
    #expect(ed.value(k("b")) == .boolean(true))
    #expect(ed.hasChanges)
}

@Test func formatFromExtension() {
    #expect(Format(fileExtension: "json") == .json)
    #expect(Format(fileExtension: "JSONC") == .json)
    #expect(Format(fileExtension: "toml") == .toml)
    #expect(Format(fileExtension: "yaml") == .yaml)
    #expect(Format(fileExtension: "xml") == nil)
}

// MARK: - examples/config.jsonc

@Test func exampleJSONC() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let original = Array(try Data(contentsOf: root.appendingPathComponent("examples/config.jsonc")))
    let doc = try JSONReader.parse(original)
    let sections = Fields.sections(doc)
    #expect(sections.map(\.title) == ["Root", "server", "database", "backup", "tasks[0].environment", "clean-logs"])
    #expect(sections.map(\.id) == [FormSection.rootID, "server", "database", "tasks[0]", "tasks[0].environment", "tasks[1]"])
    let fields = Dictionary(uniqueKeysWithValues: sections.flatMap(\.fields).map { ($0.id, $0) })
    #expect(fields["server.log_level"]?.kind == .choice(["debug", "info", "warning", "error"]))
    #expect(fields["database.driver"]?.kind == .choice(["firebird", "postgres"]))
    #expect(fields["database.factor"]?.kind == .decimal)
    #expect(fields["database.password_file"]?.kind == .raw)
    #expect(fields["title"]?.help == "Name shown at the top")

    var ed = EditSession(original, format: .json)
    try ed.assign(k("database", "pool"), .value(.integer(20)))
    try ed.assign(k("database", "factor"), .value(.decimal(2.25)))
    try ed.assign([.key("tasks"), .index(0), .key("environment"), .key("DESTINATION")], .value(.text("/srv/backup")))
    let r = s(try ed.result())
    #expect(r == s(original).replacingOccurrences(of: "\"pool\": 12,", with: "\"pool\": 20,")
        .replacingOccurrences(of: "\"factor\": 1.50,", with: "\"factor\": 2.25,")
        .replacingOccurrences(of: #""\/mnt\/backup""#, with: #""\/srv\/backup""#))
}
