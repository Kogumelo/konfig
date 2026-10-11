import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

/// Applies one change and returns the new text.
private func swap(_ text: String, _ path: ValuePath, _ v: Value) throws -> String {
    s(try Writer.apply(b(text), changes: [path: .value(v)]))
}

private func k(_ parts: String...) -> ValuePath { parts.map { .key($0) } }

// MARK: - Sanity check of the comparison against the suite

@Test func comparisonDetectsDifference() throws {
    let doc = try TOMLReader.parse("a = 1\nb = \"x\"\n")
    let wrong: [String: Any] = ["a": ["type": "integer", "value": "2"], "b": ["type": "string", "value": "x"]]
    #expect(!Compare.table(doc.root, wrong as NSDictionary, "").isEmpty)
    let right: [String: Any] = ["a": ["type": "integer", "value": "1"], "b": ["type": "string", "value": "x"]]
    #expect(Compare.table(doc.root, right as NSDictionary, "").isEmpty)
}

// MARK: - Criterion 2: opening and saving without changes does not change any byte

let specialFiles: [String: [UInt8]] = [
    "comments": b("""
        # File header
        title = "Dashboard"   # comment at the end

        # above the table
        [server]   # after the header
          host = '0.0.0.0'
          ports = [ 8080,  8443, ]  # two ports
        \t# tab before
        [[t]]
        x = 1
        """),
    "crlf": b("a = 1\r\n# c\r\n[t]\r\nb = \"\"\"\r\nline1\r\nline2\"\"\"\r\nl = [\r\n  1,\r\n  2,\r\n]\r\n"),
    "bom": [0xEF, 0xBB, 0xBF] + b("# with BOM\nname = \"ação\"\n[x]\ny = 2024-01-02\n"),
    "bom-crlf-no-final-newline": [0xEF, 0xBB, 0xBF] + b("a = 'b'\r\n[c]\r\nd = 1.5"),
    "empty": [],
    "comment-only": b("# nothing here\n\n\n"),
]

@Test(arguments: Array(specialFiles.keys).sorted())
func noChangeSameBytes(_ name: String) throws {
    let original = specialFiles[name]!
    var ed = EditSession(original)
    #expect(ed.error == nil)
    #expect(try ed.result() == original)
    #expect(!ed.hasChanges)
    // Even "changing" each value to itself, nothing changes.
    for e in ed.document!.entries {
        try ed.assign(e.path, .value(e.value))
        try ed.assign(e.path, .raw(ed.document!.text(e.range)))
    }
    #expect(ed.changes.isEmpty)
    #expect(try ed.result() == original)
}

@Test(arguments: Suite.valids)
func noChangeSameBytesSuite(_ testCase: String) throws {
    let original = Suite.bytes(testCase)
    var ed = EditSession(original)
    for e in ed.document!.entries { try ed.assign(e.path, .value(e.value)) }
    #expect(try ed.result() == original)
}

// MARK: - Criterion 3: changing a value alters only that hunk

/// A different value of the same type, to test saving.
func mutated(_ v: Value) -> Value? {
    switch v {
    case .text(let s): return .text(s + "x'\"")
    case .integer(let n): return .integer(n == Int64.max ? n - 1 : n + 1)
    case .decimal(let d): return .decimal(d.isFinite ? d + 1.5 : 2.5)
    case .boolean(let x): return .boolean(!x)
    case .dateTime(var dh):
        if dh.hasDate { dh.day = dh.day == 1 ? 2 : 1 } else { dh.minute = (dh.minute + 1) % 60 }
        return .dateTime(dh)
    case .array(let l):
        if let p = l.first { return .array(l + [p]) }
        return .array([.integer(1)])
    case .table(var t):
        t["km_toml_new"] = .integer(7)
        return .table(t)
    case .null: return .boolean(true)
    }
}

/// Checks that only the value's range changed: everything before and after stays the same, byte for byte.
func onlyTheHunkChanged(_ before: [UInt8], _ after: [UInt8], _ r: Range<Int>) -> Bool {
    let suffix = before.count - r.upperBound
    guard after.count >= r.lowerBound + suffix else { return false }
    return after.prefix(r.lowerBound).elementsEqual(before.prefix(r.lowerBound))
        && after.suffix(suffix).elementsEqual(before.suffix(suffix))
}

@Test(arguments: Suite.valids + Array(specialFiles.keys).sorted())
func changeEachValue(_ testCase: String) throws {
    let original = specialFiles[testCase] ?? Suite.bytes(testCase)
    let doc = try TOMLReader.parse(original)
    for e in doc.entries {
        guard let updated = mutated(e.value) else { continue }
        let output: [UInt8]
        do { output = try Writer.apply(original, changes: [e.path: .value(updated)]) } catch {
            Issue.record("\(e.path.text): \(error)")
            continue
        }
        #expect(onlyTheHunkChanged(original, output, e.range), "\(e.path.text): changed outside the hunk")
        let reparsed = try TOMLReader.parse(output)
        #expect(reparsed.root == doc.root.replacing(e.path, by: updated)!, "\(e.path.text)")
        #expect(reparsed.root.value(at: e.path) == updated)
    }
}

@Test func changeSeveralAtOnce() throws {
    let t = "a = 1 # one\nb = \"x\"\n[s]\nc = true\nd = 2.5\n"
    let r = s(try Writer.apply(b(t), changes: [
        k("a"): .value(.integer(10)), k("s", "c"): .value(.boolean(false)), k("s", "d"): .value(.decimal(3)),
    ]))
    #expect(r == "a = 10 # one\nb = \"x\"\n[s]\nc = false\nd = 3.0\n")
}

// MARK: - Style of each type

@Test func stringKeepsQuotes() throws {
    #expect(try swap("a = \"x\"\n", k("a"), .text("y\"z")) == "a = \"y\\\"z\"\n")
    #expect(try swap("a = 'x'\n", k("a"), .text("c:\\folder")) == "a = 'c:\\folder'\n")
    // does not fit in a literal string: becomes a basic string with escapes
    #expect(try swap("a = 'x'\n", k("a"), .text("it's")) == "a = \"it's\"\n")
    #expect(try swap("a = 'x'\n", k("a"), .text("l1\nl2")) == "a = \"l1\\nl2\"\n")
    #expect(try swap("a = \"\"\"\nx\"\"\"\n", k("a"), .text("one\ntwo")) == "a = \"\"\"\none\ntwo\"\"\"\n")
    #expect(try swap("a = '''x'''\n", k("a"), .text("c:\\x")) == "a = '''c:\\x'''\n")
    #expect(try swap("a = '''x'''\n", k("a"), .text("a'''b")) == "a = \"\"\"a'''b\"\"\"\n")
    #expect(try swap("a = \"\"\"x\"\"\"\n", k("a"), .text("\"\"\"")) == "a = \"\"\"\\\"\\\"\\\"\"\"\"\n")
    // CRLF inside multi-line text follows the file
    #expect(try swap("a = \"\"\"\r\nx\"\"\"\r\n", k("a"), .text("1\n2")) == "a = \"\"\"\r\n1\r\n2\"\"\"\r\n")
}

@Test func integerKeepsBase() throws {
    #expect(try swap("a = 0xff\n", k("a"), .integer(4096)) == "a = 0x1000\n")
    #expect(try swap("a = 0xFF\n", k("a"), .integer(171)) == "a = 0xAB\n")
    #expect(try swap("a = 0x00ff\n", k("a"), .integer(16)) == "a = 0x0010\n")
    #expect(try swap("a = 0o755\n", k("a"), .integer(0o644)) == "a = 0o644\n")
    #expect(try swap("a = 0b1010\n", k("a"), .integer(3)) == "a = 0b0011\n")
    #expect(try swap("a = 1_000\n", k("a"), .integer(1234567)) == "a = 1_234_567\n")
    #expect(try swap("a = +5\n", k("a"), .integer(6)) == "a = +6\n")
    // negatives do not exist in hex: becomes decimal
    #expect(try swap("a = 0xff\n", k("a"), .integer(-1)) == "a = -1\n")
}

@Test func decimalBoolData() throws {
    #expect(try swap("a = 1.5\n", k("a"), .decimal(2)) == "a = 2.0\n")
    #expect(try swap("a = 1.5\n", k("a"), .decimal(.infinity)) == "a = inf\n")
    #expect(try swap("a = 1.5\n", k("a"), .decimal(1e-7)) == "a = 1e-07\n")
    #expect(try swap("a = true\n", k("a"), .boolean(false)) == "a = false\n")
    var d = try #require({ if case .dateTime(let x) = try TOMLReader.parseValue("1979-05-27 07:32:00z") { return x }; return nil }())
    d.hour = 8
    #expect(try swap("a = 1979-05-27 07:32:00z\n", k("a"), .dateTime(d)) == "a = 1979-05-27 08:32:00z\n")
    var h = DateTime(kind: .time); h.hour = 9; h.minute = 5
    #expect(try swap("a = 07:32:00.500\n", k("a"), .dateTime(h)) == "a = 09:05:00\n")
    var l = DateTime(kind: .local); l.year = 2026; l.month = 12; l.day = 31; l.hour = 23; l.minute = 59
    #expect(try swap("a = 2026-01-01T00:00:00\n", k("a"), .dateTime(l)) == "a = 2026-12-31T23:59:00\n")
    var f = DateTime(kind: .withOffset); f.year = 2026; f.month = 3; f.day = 4; f.offsetMinutes = -180; f.offsetIsZ = false
    #expect(try swap("a = 2026-01-01T00:00:00Z\n", k("a"), .dateTime(f)) == "a = 2026-03-04T00:00:00-03:00\n")
}

@Test func singleLineArray() throws {
    let t = "ports = [ 8080, 8443 ]  # web\n"
    #expect(try swap(t, k("ports"), .array([.integer(8080), .integer(9000)])) == "ports = [ 8080, 9000 ]  # web\n")
    #expect(try swap(t, k("ports"), .array([.integer(8080), .integer(8443), .integer(1)])) == "ports = [ 8080, 8443, 1 ]  # web\n")
    #expect(try swap(t, k("ports"), .array([.integer(1)])) == "ports = [ 1 ]  # web\n")
    #expect(try swap("a = ['x','y',]\n", k("a"), .array([.text("z")])) == "a = ['z',]\n")
    #expect(try swap("a = []\n", k("a"), .array([.text("z")])) == "a = [\"z\"]\n")
    #expect(try swap("a = [1, 2]\n", k("a"), .array([])) == "a = []\n")
}

@Test func multiLineArray() throws {
    let t = "a = [\n  \"one\",\n  \"two\",\n]\nb = 1\n"
    #expect(try swap(t, k("a"), .array([.text("one"), .text("two"), .text("three")]))
            == "a = [\n  \"one\",\n  \"two\",\n  \"three\",\n]\nb = 1\n")
    #expect(try swap(t, k("a"), .array([.text("only")])) == "a = [\n  \"only\",\n]\nb = 1\n")
    // no trailing comma and indented by 4
    let u = "a = [\n    1,\n    2\n]\n"
    #expect(try swap(u, k("a"), .array([.integer(1), .integer(2), .integer(3)])) == "a = [\n    1,\n    2,\n    3\n]\n")
    // same number of items: only the item changes, inner comments stay
    let c = "a = [\n  1, # one\n  2, # two\n]\n"
    #expect(try swap(c, k("a"), .array([.integer(1), .integer(20)])) == "a = [\n  1, # one\n  20, # two\n]\n")
    // CRLF
    let w = "a = [\r\n  1,\r\n]\r\n"
    #expect(try swap(w, k("a"), .array([.integer(1), .integer(2)])) == "a = [\r\n  1,\r\n  2,\r\n]\r\n")
}

@Test func rawValueValidated() throws {
    let t = "m = [1, \"a\"] # mixed\n"
    let r = s(try Writer.apply(b(t), changes: [k("m"): .raw("[1, \"a\", 2.5]")]))
    #expect(r == "m = [1, \"a\", 2.5] # mixed\n")
    #expect(throws: SaveError.self) { try Writer.apply(b(t), changes: [k("m"): .raw("[1, ")]) }
    #expect(throws: SaveError.self) { try Writer.apply(b(t), changes: [k("m"): .raw("1\nx = 2")]) }
}

@Test func missingPath() {
    #expect(throws: SaveError.self) { try Writer.apply(b("a = 1\n"), changes: [k("b"): .value(.integer(1))]) }
}

@Test func arrayOfTablesItem() throws {
    let t = "[[t]]\nname = \"a\"\n[[t]]\nname = \"b\"\n"
    let r = try swap(t, [.key("t"), .index(1), .key("name")], .text("c"))
    #expect(r == "[[t]]\nname = \"a\"\n[[t]]\nname = \"c\"\n")
}

@Test func bomAndCRLFPreserved() throws {
    let t: [UInt8] = [0xEF, 0xBB, 0xBF] + b("a = 1\r\nb = 2\r\n")
    let r = try Writer.apply(t, changes: [k("b"): .value(.integer(3))])
    #expect(r == [0xEF, 0xBB, 0xBF] + b("a = 1\r\nb = 3\r\n"))
}

// MARK: - Editing (document state)

@Test func textEditAndUndo() throws {
    var ed = EditSession(b("a = 1\n"))
    try ed.assign(k("a"), .value(.integer(2)))
    let before = ed.snapshot
    try ed.replaceText(b("a = 2\nb = 3\n"))
    #expect(ed.changes.isEmpty)
    #expect(try ed.result() == b("a = 2\nb = 3\n"))
    #expect(throws: ParseError.self) { try ed.replaceText(b("a = \n")) }
    ed.restore(before)
    #expect(try ed.result() == b("a = 2\n"))
    ed.saved(try ed.result())
    #expect(!ed.hasChanges)
    #expect(ed.disk == b("a = 2\n"))
    // going back to the old value after saving is a new change
    try ed.assign(k("a"), .value(.integer(1)))
    #expect(ed.hasChanges)
}

@Test func diffByLines() {
    let d = Diff.lines(b("a\nb\nc\n"), b("a\nB\nc\nd\n"))
    #expect(d == [Hunk(lineBefore: 2, lineAfter: 2, removed: ["b"], added: ["B"]),
                  Hunk(lineBefore: 4, lineAfter: 4, removed: [], added: ["d"])])
    #expect(Diff.lines(b("x\n"), b("x\n")).isEmpty)
}

// MARK: - Fields

@Test func exampleFields() throws {
    let t = """
    title = "Dashboard"
    [server]
    # debug | info | warning | error
    level = "info"
    tls = true # requires a certificate
    ports = [8080, 8443]
    mixed = [1, "a"]
    pt = { x = 1 }
    when = 2026-12-31T23:59:00
    [[tasks]]
    name = "backup"
    [[tasks]]
    cron = "0 4 * * 0"
    """
    let sections = Fields.sections(try TOMLReader.parse(t))
    #expect(sections.map(\.title) == ["Root", "server", "backup", "item 2"])
    #expect(sections[2].group == "tasks" && sections[2].totalItems == 2 && sections[3].itemIndex == 1)
    let s = sections[1].fields
    #expect(s[0].kind == .choice(["debug", "info", "warning", "error"]))
    #expect(s[1].kind == .boolean && s[1].help == "requires a certificate")
    #expect(s[2].kind == .array(.integer))
    #expect(s[3].kind == .raw && s[4].kind == .raw)
    #expect(s[5].kind == .date(.local))
}

@Test func changeDuringSaveIsNotLost() throws {
    var ed = EditSession(b("a = 1\nb = 1\n"))
    try ed.assign(k("a"), .value(.integer(2)))
    let saving = try ed.result()
    try ed.assign(k("b"), .value(.integer(3)))  // arrives while saving
    ed.saved(saving)
    #expect(ed.disk == b("a = 2\nb = 1\n"))
    #expect(try ed.result() == b("a = 2\nb = 3\n"))
    #expect(ed.hasChanges)
}
