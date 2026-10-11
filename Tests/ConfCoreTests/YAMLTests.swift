import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func k(_ keys: String...) -> ValuePath { keys.map { .key($0) } }

/// Applies one change to a YAML and returns the new text.
private func swap(_ text: String, _ c: ValuePath, _ v: Value) throws -> String {
    s(try Writer.apply(b(text), changes: [c: .value(v)], format: .yaml))
}

private let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

// MARK: - Reading

@Test func yamlFormatFromName() {
    #expect(Format(fileName: "docker-compose.yml") == .yaml)
    #expect(Format(fileName: "config.YAML") == .yaml)
    #expect(Format(fileName: "pubspec.yaml") == .yaml)
    #expect(Format.yaml.name == "YAML")
}

@Test func yamlCoreSchema() throws {
    let doc = try YAMLReader.parse("""
        a: yes
        b: no
        c: on
        d: off
        e: true
        f: False
        g: ~
        h:
        i: null
        j: 0x1F
        k: 0o17
        l: 010
        m: 1e3
        n: .inf
        o: -.Inf
        p: .NaN
        q: +12
        r: 1_000
        s: 0b101
        t: 2024-01-31
        u: 12:30
        v: "true"
        w: '1'
        x: 1.
        y: .5

        """)
    let t = doc.root
    #expect(t["a"] == .text("yes") && t["b"] == .text("no") && t["c"] == .text("on") && t["d"] == .text("off"),
            "YAML 1.2: yes/no/on/off are text")
    #expect(t["e"] == .boolean(true) && t["f"] == .boolean(false))
    #expect(t["g"] == .null && t["h"] == .null && t["i"] == .null)
    #expect(t["j"] == .integer(31) && t["k"] == .integer(15))
    #expect(t["l"] == .integer(10), "YAML 1.2: 010 is ten (in 1.1 it would be octal)")
    #expect(t["m"] == .decimal(1000))
    #expect(t["n"] == .decimal(.infinity) && t["o"] == .decimal(-.infinity))
    if case .decimal(let d)? = t["p"] { #expect(d.isNaN) } else { Issue.record("p") }
    #expect(t["q"] == .integer(12))
    #expect(t["r"] == .text("1_000") && t["s"] == .text("0b101"), "outside the core schema: text")
    #expect(t["t"] == .text("2024-01-31") && t["u"] == .text("12:30"), "no dates or sexagesimals in 1.2")
    #expect(t["v"] == .text("true") && t["w"] == .text("1"), "quoted is always text")
    #expect(t["x"] == .decimal(1) && t["y"] == .decimal(0.5))
}

@Test func yamlSectionsOnScreen() throws {
    let doc = try YAMLReader.parse(Array(try Data(contentsOf: projectRoot.appendingPathComponent("examples/config.yaml"))))
    let sections = Fields.sections(doc)
    #expect(sections.map(\.id) == [FormSection.rootID, "services", "services.web", "services.web.environment", "services.web.healthcheck",
                                 "services.database", "services.database.environment", "tasks[0]", "tasks[1]"])
    #expect(sections.first { $0.id == "tasks[0]" }?.title == "backup")
    #expect(sections.first { $0.id == "tasks[1]" }?.group == "tasks")
    let fields = Dictionary(uniqueKeysWithValues: sections.flatMap(\.fields).map { ($0.id, $0) })
    #expect(fields["log_level"]?.kind == .choice(["debug", "info", "warning", "error"]))
    #expect(fields["log_level"]?.help == "Log detail level\ndebug | info | warning | error")
    #expect(fields["services.web.restart"]?.kind == .choice(["no", "always", "on-failure", "unless-stopped"]))
    #expect(fields["services.web.ports"]?.kind == .array(.text))
    #expect(fields["services.web.command"]?.kind == .array(.text), "flow sequence of text only: chips")
    #expect(fields["services.web.healthcheck.test"]?.value == .array([.text("CMD"), .text("curl"), .text("-f"), .text("http://localhost")]))
    #expect(fields["services.web.environment.COUNTRY"]?.value == .text("no"))
    #expect(fields["services.web.environment.DEBUG"]?.kind == .boolean)
    #expect(fields["maintenance"]?.value == .text("The dashboard is under maintenance.\nPlease come back in a few minutes.\n"))
    #expect(fields["pool"]?.kind == .integer && fields["pool"]?.help == "simultaneous connections to the database")
    #expect(fields["limit_mb"]?.kind == .decimal)
    #expect(sections.first { $0.id == "services.web" }?.help == "Web server in front of the dashboard")
}

@Test func yamlMixedInlineArrayAndTableAreRawText() throws {
    let doc = try YAMLReader.parse("a: [1, x]\nb: {c: 1}\nc:\n  - 1\n  - [2]\nd:\n")
    let fields = Dictionary(uniqueKeysWithValues: Fields.sections(doc).flatMap(\.fields).map { ($0.id, $0) })
    #expect(fields["a"]?.kind == .raw && fields["b"]?.kind == .raw && fields["c"]?.kind == .raw && fields["d"]?.kind == .raw)
    #expect(fields["b"]?.kind.name(at: .yaml) == "YAML")
}

@Test(arguments: [
    ("a: 1\na: 2\n", 2, "already appeared"),
    ("a:\n\t- 1\n", 2, "tab"),
    ("a: 'x\n", 1, "quotes"),
    ("a: [1, 2\n", 1, "]"),
    ("a: b: c\n", 1, "map"),
    ("- a\nb: 1\n", 2, "unexpected"),
    ("a: \"\\q\"\n", 1, "escape"),
])
func yamlErrors(_ testCase: (String, Int, String)) {
    do {
        _ = try YAMLReader.parse(testCase.0)
        Issue.record("accepted: \(testCase.0)")
    } catch {
        #expect(!error.outsideSubset)
        #expect(error.line == testCase.1, "\(error)")
        #expect(error.message.contains(testCase.2), "\(error)")
    }
}

@Test(arguments: [
    ("base: &b {a: 1}\n", 1, "anchor"),
    ("a: 1\nb: *x\n", 2, "alias"),
    ("a:\n  <<: {b: 1}\n", 2, "merge"),
    ("a: !Ref x\n", 1, "tag"),
    ("a: !!str 1\n", 1, "tag"),
    ("%YAML 1.2\n---\na: 1\n", 1, "directive"),
    ("a: 1\n---\nb: 2\n", 2, "more than one document"),
    ("a: 1\n...\nb: 2\n", 3, "more than one document"),
    ("? a\n: 1\n", 1, "complex key"),
    ("[a, b]: 1\n", 1, "complex key"),
    ("~: 1\n", 1, "null key"),
])
func yamlOutsideSubset(_ testCase: (String, Int, String)) {
    do {
        _ = try YAMLReader.parse(testCase.0)
        Issue.record("accepted: \(testCase.0)")
    } catch {
        #expect(error.outsideSubset, "\(error)")
        #expect(error.line == testCase.1, "\(error)")
        #expect(error.message.contains(testCase.2), "\(error)")
        #expect(error.errorDescription?.contains("outside the subset") == true)
    }
}

@Test func yamlOutsideSubsetOpensAsTextOnly() throws {
    let text = b("defaults: &d\n  a: 1\nprod:\n  <<: *d\n  b: 2\n")
    var ed = EditSession(text, format: .yaml)
    #expect(ed.document == nil && ed.textOnly)
    #expect(try ed.result() == text, "no change: the same bytes")
    // the text can be replaced with another one also outside the subset (saved as is)
    let updated = b("defaults: &d\n  a: 2\nprod:\n  <<: *d\n")
    try ed.replaceText(updated)
    #expect(try ed.result() == updated && ed.textOnly)
    // and with one inside the subset, which opens in the form again
    try ed.replaceText(b("a: 1\n"))
    #expect(ed.document != nil && !ed.textOnly)
    // text with a real error is still rejected
    #expect(throws: ParseError.self) { try ed.replaceText(b("a: [1\n")) }
    // the other formats are unchanged: an error is an error
    var ini = EditSession(b("a = 1\n"), format: .ini)
    #expect(throws: ParseError.self) { try ini.replaceText(b("junk\n")) }
}

@Test func yamlParseValue() throws {
    #expect(try YAMLReader.parseValue("[1, a]") == .array([.integer(1), .text("a")]))
    #expect(try YAMLReader.parseValue("{a: 1}") == .table(Table(pairs: [.init(key: "a", value: .integer(1))])))
    #expect(try YAMLReader.parseValue("'x'") == .text("x"))
    #expect(try YAMLReader.parseValue("") == .null)
    #expect(try YAMLReader.parseValue("42") == .integer(42))
    // text of a block sequence as it is in the file (with the indentation)
    #expect(try YAMLReader.parseValue("  - a\n  - b") == .array([.text("a"), .text("b")]))
    #expect(throws: ParseError.self) { try YAMLReader.parseValue("[1,") }
}

// MARK: - Protective quotes (YAML 1.1)

@Test(arguments: ["no", "No", "NO", "yes", "on", "off", "y", "n", "true", "False", "null", "~", "1e3", "010", "0x1F",
                  "0b11", "1_000", "12:30", "8080:80", "1.5", ".5", ".inf", "-.inf", ".nan", "2024-01-31", "<<", "=", ""])
func yamlProtectiveQuotes(_ text: String) throws {
    // unquoted value in the original: new text that another reader would read as another type gets quotes
    let r = try swap("country: br\n", k("country"), .text(text))
    #expect(r == "country: \"\(text)\"\n", "\(text) → \(r)")
    #expect(try YAMLReader.parse(r).root["country"] == .text(text))
}

@Test func yamlUnquotedWhenItFits() throws {
    #expect(try swap("a: x\n", k("a"), .text("Norway")) == "a: Norway\n")
    #expect(try swap("a: x\n", k("a"), .text("nginx:1.28")) == "a: nginx:1.28\n")
    #expect(try swap("a: x\n", k("a"), .text("http://x/#a")) == "a: http://x/#a\n")
    // needs quotes: ': ', ' #', special start, leading/trailing spaces
    #expect(try swap("a: x\n", k("a"), .text("a: b")) == "a: \"a: b\"\n")
    #expect(try swap("a: x\n", k("a"), .text("a #b")) == "a: \"a #b\"\n")
    #expect(try swap("a: x\n", k("a"), .text("*x")) == "a: \"*x\"\n")
    #expect(try swap("a: x\n", k("a"), .text("- x")) == "a: \"- x\"\n")
    #expect(try swap("a: x\n", k("a"), .text(" x")) == "a: \" x\"\n")
    #expect(try swap("a: x\n", k("a"), .text("x\ny")) == "a: \"x\\ny\"\n")
    // the quote style is kept
    #expect(try swap("a: 'x'\n", k("a"), .text("it's")) == "a: 'it''s'\n")
    #expect(try swap("a: 'x'\n", k("a"), .text("no")) == "a: 'no'\n")
    #expect(try swap("a: \"x\"\n", k("a"), .text("y")) == "a: \"y\"\n")
    #expect(try swap("a: 'x'\n", k("a"), .text("x\ny")) == "a: \"x\\ny\"\n")
    // empty value: `a: new`, not `a:new`
    #expect(try swap("a:\nb: 1\n", k("a"), .text("new")) == "a: new\nb: 1\n")
    #expect(try swap("a: # note\n", k("a"), .integer(3)) == "a: 3 # note\n")
}

@Test func yamlNumbersKeepShape() throws {
    #expect(try swap("a: 0x1F\n", k("a"), .integer(255)) == "a: 0xFF\n")
    #expect(try swap("a: 0o17\n", k("a"), .integer(8)) == "a: 0o10\n")
    #expect(try swap("a: +5\n", k("a"), .integer(6)) == "a: +6\n")
    #expect(try swap("a: 1.50\n", k("a"), .decimal(2.25)) == "a: 2.25\n")
    #expect(try swap("a: 1.5e3\n", k("a"), .decimal(2000)) == "a: 2.0e3\n")
    #expect(try swap("a: .Inf\n", k("a"), .decimal(-.infinity)) == "a: -.Inf\n")
    #expect(try swap("a: True\n", k("a"), .boolean(false)) == "a: False\n")
    #expect(try swap("a: 1\n", k("a"), .decimal(2.5)) == "a: 2.5\n")
    #expect(throws: SaveError.self) {
        try swap("a: 1\n", k("a"), .dateTime(DateTime(kind: .date)))
    }
}

// MARK: - Block sequences

@Test func yamlArrayGrows() throws {
    let text = "ports:\n  - 80   # http\n  - \"443\"\nend: 1\n"
    let r = try swap(text, k("ports"), .array([.integer(80), .text("443"), .text("8443")]))
    #expect(r == "ports:\n  - 80   # http\n  - \"443\"\n  - \"8443\"\nend: 1\n")
    let d = Diff.lines(b(text), b(r))
    #expect(d.count == 1 && d[0].removed.isEmpty && d[0].added == ["  - \"8443\""])
    // several new items, zero indentation (sequence at the same indentation as the key)
    let r2 = try swap("a:\n- x\nb: 2\n", k("a"), .array([.text("x"), .text("w"), .text("no")]))
    #expect(r2 == "a:\n- x\n- w\n- \"no\"\nb: 2\n", "'no' gets protective quotes")
    // new item of another type
    let r3 = try swap("a:\n  - x\n", k("a"), .array([.text("x"), .integer(3)]))
    #expect(r3 == "a:\n  - x\n  - 3\n")
}

@Test func yamlArrayShrinks() throws {
    let text = "l:\n  - a\n  # about b\n  - b\n  - c  # c\nend: 1\n"
    #expect(try swap(text, k("l"), .array([.text("a"), .text("c")])) == "l:\n  - a\n  # about b\n  - c  # c\nend: 1\n")
    #expect(try swap(text, k("l"), .array([.text("b"), .text("c")])) == "l:\n  # about b\n  - b\n  - c  # c\nend: 1\n")
    #expect(try swap(text, k("l"), .array([.text("a"), .text("b")])) == "l:\n  - a\n  # about b\n  - b\nend: 1\n")
    #expect(try swap(text, k("l"), .array([])) == "l:\n  []\nend: 1\n")
    // change one item and remove another: the last one goes, the first changes in place
    #expect(try swap(text, k("l"), .array([.text("A"), .text("b")])) == "l:\n  - A\n  # about b\n  - b\nend: 1\n")
}

@Test func yamlInlineArray() throws {
    #expect(try swap("a: [x, w]\n", k("a"), .array([.text("x"), .text("w"), .text("z w")])) == "a: [x, w, z w]\n")
    #expect(try swap("a: [x, w]\n", k("a"), .array([.text("x"), .text("a,b")])) == "a: [x, \"a,b\"]\n")
    #expect(try swap("a: ['x', \"w\"]\n", k("a"), .array([.text("x2"), .text("w")])) == "a: ['x2', \"w\"]\n")
    #expect(try swap("a: {b, c: 1}\n", k("a"), .table(Table(pairs: [.init(key: "b", value: .null)]))) == "a: {b: null}\n")
    #expect(try swap("a: [1, 2]\n", k("a"), .array([.integer(1)])) == "a: [1]\n")
}

// MARK: - Blocks | and >

@Test func yamlLiteralBlock() throws {
    let text = "msg: |  # note\n  line 1\n  line 2\nend: 1\n"
    #expect(try swap(text, k("msg"), .text("one\ntwo\nthree\n")) == "msg: |  # note\n  one\n  two\n  three\nend: 1\n")
    // no trailing line break: '-' indicator; several: '+'
    #expect(try swap(text, k("msg"), .text("one")) == "msg: |-  # note\n  one\nend: 1\n")
    #expect(try swap(text, k("msg"), .text("one\n\n")) == "msg: |+  # note\n  one\n\nend: 1\n")
    // blank lines in the middle stay empty (no spaces)
    #expect(try swap(text, k("msg"), .text("a\n\nb\n")) == "msg: |  # note\n  a\n\n  b\nend: 1\n")
    // a first line starting with a space would need an indentation indicator: becomes quoted
    #expect(try swap(text, k("msg"), .text("  x\n")) == "msg: \"  x\\n\"\nend: 1\n")
    // the original indentation is kept, also in a sequence item
    #expect(try swap("l:\n    - |\n        a\n", k("l"), .array([.text("b\n")])) == "l:\n    - |\n        b\n")
    // at the end of the file, without a final line break
    #expect(try swap("a: |\n  x", k("a"), .text("y\n")) == "a: |\n  y\n")
    #expect(try swap("a: |\n  x", k("a"), .text("y\n\n")) == "a: |+\n  y\n\n")
}

@Test func yamlFoldedBlock() throws {
    let text = "msg: >\n  a long\n  text\n\n  another\nend: 1\n"
    #expect(try YAMLReader.parse(text).root["msg"] == .text("a long text\nanother\n"))
    #expect(try swap(text, k("msg"), .text("a b\nc\n")) == "msg: >\n  a b\n\n  c\nend: 1\n")
    // a line starting with a space is not folded: becomes literal
    #expect(try swap(text, k("msg"), .text("a\n  b\n")) == "msg: |\n  a\n    b\nend: 1\n")
    // with an indentation indicator (the line starting with a space also turns `>` into `|`)
    let r = try swap("a: >2\n   x\n", k("a"), .text(" y\n"))
    #expect(r == "a: |2\n   y\n")
    #expect(try YAMLReader.parse(r).root["a"] == .text(" y\n"))
}

@Test func yamlBlockWithKeepBeforeBlankLines() throws {
    // new text with '+' and blank lines after the block: they would be read as part of the value
    let r = try swap("a: |\n  x\n\nb: 1\n", k("a"), .text("y\n\n"))
    #expect(try YAMLReader.parse(r).root["a"] == .text("y\n\n"))
    #expect(r.hasSuffix("\n\nb: 1\n"))
}

// MARK: - CRLF and BOM

@Test func yamlCRLFAndBOM() throws {
    let text: [UInt8] = [0xEF, 0xBB, 0xBF] + b("# c\r\na: 1\r\nl:\r\n  - x\r\nm: |\r\n  one\r\n  two\r\nz: end\r\n")
    let doc = try YAMLReader.parse(text)
    #expect(doc.hasBOM && doc.lineBreak == "\r\n")
    #expect(doc.root["m"] == .text("one\ntwo\n"), "CRLF inside the block becomes \\n")
    #expect(doc.entry(k("a"))?.commentAbove == ["c"])
    var ed = EditSession(text, format: .yaml)
    #expect(try ed.result() == text)
    try ed.assign(k("l"), .value(.array([.text("x"), .text("w")])))
    try ed.assign(k("m"), .value(.text("one\ntwo\nthree\n")))
    try ed.assign(k("a"), .value(.integer(2)))
    let r = try ed.result()
    #expect(r == [0xEF, 0xBB, 0xBF] + b("# c\r\na: 2\r\nl:\r\n  - x\r\n  - w\r\nm: |\r\n  one\r\n  two\r\n  three\r\nz: end\r\n"))
}

// MARK: - Criteria 2 and 3: on every accepted case of the suite, on the example and on our own cases

private let yamlSpecials: [String: [UInt8]] = [
    "empty": [],
    "comments-only": b("# nothing\n\n# here\n"),
    "no-final-newline": b("a: 1\nb: 'two'"),
    "crlf-bom": [0xEF, 0xBB, 0xBF] + b("# c\r\na: \"x y\" # z\r\n\r\nl:\r\n  - 1\r\n  -\r\n  - [a, b]\r\nc:\r\nd: |-\r\n  t\r\n"),
    "docker-compose": b("""
        services:
          app:
            image: "app:1"
            ports: ["80:80"]
            depends_on:
              - db
          db:
            image: postgres
        """),
    "github-actions": b("""
        name: CI
        on:
          push:
            branches: [ main ]
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - name: Test
                run: |
                  swift build
                  swift test

        """),
    "kubernetes": b("""
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
          labels: {app: web, tier: "frontend"}
        spec:
          replicas: 3
          template:
            spec:
              containers:
                - name: web
                  image: nginx:1.27
                  args: ["--port", "8080"]
                  env:
                    - name: MODE
                      value: "production"
                  resources:
                    limits:
                      cpu: 500m
                      memory: 128Mi

        """),
    "pubspec": b("""
        name: km_lib
        description: >-
          Shared library of the
          Kogumelo apps.
        version: 1.2.3+4
        publish_to: none

        environment:
          sdk: '>=3.0.0 <4.0.0'

        dependencies:
          flutter:
            sdk: flutter
          intl: ^0.19.0
        """),
    "openapi": b("""
        openapi: 3.0.3
        info:
          title: Dashboard API
          description: |
            Line 1.

            Line 3, after a blank one.
          version: "2.0"
        paths:
          /tasks/{id}:
            get:
              parameters:
                - in: path
                  name: id
                  required: true
                  schema: {type: integer, minimum: 1}
              responses:
                '200':
                  description: OK

        """),
    "root-sequence": b("- a\n- b: 1\n- [x]\n"),
    "root-scalar": b("--- loose text\n...\n"),
    "explicit": b("---\na: 1\n...\n# end\n"),
]

private func yamlCase(_ name: String) -> [UInt8] {
    if let x = yamlSpecials[name] { return x }
    if name.hasPrefix("examples/") { return Array(try! Data(contentsOf: projectRoot.appendingPathComponent(name))) }
    return YAMLSuite.bytes(name)
}

private let yamlCases = YAMLSuite.inside + Array(yamlSpecials.keys).sorted() + ["examples/config.yaml"]

@Test(arguments: yamlCases)
func yamlNoChangeSameBytes(_ testCase: String) throws {
    let original = yamlCase(testCase)
    var ed = EditSession(original, format: .yaml)
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

/// Value changed for the test: texts get quotes and a character that requires double quotes.
private func mutatedYAML(_ v: Value) -> Value {
    switch v {
    case .null: return .text("no")
    case .decimal(let d) where !d.isFinite: return .decimal(2.5)
    default: return mutated(v)!
    }
}

@Test(arguments: yamlCases)
func yamlChangeEachValue(_ testCase: String) throws {
    let original = yamlCase(testCase)
    let doc = try YAMLReader.parse(original)
    func matches(_ e: Entry, _ updated: Value, _ span: Range<Int>, _ name: String) {
        let output: [UInt8]
        do { output = try Writer.apply(doc, changes: [e.path: .value(updated)]) } catch {
            Issue.record("\(testCase) \(e.path.text) \(name): \(error)")
            return
        }
        #expect(onlyTheHunkChanged(original, output, span), "\(testCase) \(e.path.text) \(name): changed outside the hunk")
        guard let reparsed = try? YAMLReader.parse(output) else { Issue.record("\(testCase): reparse"); return }
        #expect(reparsed.rootValue == doc.rootValue.replacing(e.path, by: updated)!, "\(testCase) \(e.path.text) \(name)")
        #expect(reparsed.hasBOM == doc.hasBOM && reparsed.lineBreak == doc.lineBreak)
    }
    for e in doc.entries {
        let updated = mutatedYAML(e.value)
        matches(e, updated, e.range, "mutated")
        switch e.value {
        case .text(let t):
            // texts that a YAML 1.1 reader would read as another type; multi-line text
            for x in ["no", "on", "1e3", "010", "null", t + "\nline 2\n"] { matches(e, .text(x), e.range, x) }
        case .array(let items) where !items.isEmpty:
            // each item: only its own hunk changes
            for i in items.indices where items[i].kind != .array && items[i].kind != .table {
                var l = items
                l[i] = mutatedYAML(items[i])
                matches(e, .array(l), e.position.items[i].range, "item \(i)")
            }
            let inBlock = doc.bytes[e.range].first { $0 != 0x20 } == 0x2D
            guard inBlock else { break }
            // adding: one more line, nothing removed
            if let output = try? Writer.apply(doc, changes: [e.path: .value(.array(items + [.text("new")]))]) {
                let d = Diff.lines(original, output)
                #expect(d.count == 1 && d[0].removed.isEmpty && d[0].added.count == 1, "\(testCase) \(e.path.text): \(d)")
            }
            matches(e, .array(items + [.text("new")]), e.range, "add")
            // removing each item: only its lines
            if items.count > 1 {
                for i in items.indices {
                    var l = items
                    l.remove(at: i)
                    matches(e, .array(l), e.range, "remove \(i)")
                    if let output = try? Writer.apply(doc, changes: [e.path: .value(.array(l))]) {
                        let d = Diff.lines(original, output)
                        #expect(d.count == 1 && d[0].added.isEmpty, "\(testCase) \(e.path.text) -\(i): \(d)")
                    }
                }
            }
        default: break
        }
    }
}

// MARK: - Example

@Test func exampleYAML() throws {
    let original = Array(try Data(contentsOf: projectRoot.appendingPathComponent("examples/config.yaml")))
    var ed = EditSession(original, format: .yaml)
    try ed.assign(k("pool"), .value(.integer(20)))
    try ed.assign(k("log_level"), .value(.text("warning")))
    try ed.assign(k("services", "web", "restart"), .value(.text("no")))
    try ed.assign(k("services", "web", "ports"), .value(.array([.text("8080:80"), .text("8443:443"), .text("9000:9000")])))
    try ed.assign(k("maintenance"), .value(.text("Back online at 2 pm.\n")))
    let r = s(try ed.result())
    #expect(r == s(original).replacingOccurrences(of: "pool: 12", with: "pool: 20")
        .replacingOccurrences(of: "log_level: info", with: "log_level: warning")
        .replacingOccurrences(of: "restart: unless-stopped", with: "restart: \"no\"")
        .replacingOccurrences(of: "      - \"8443:443\"\n", with: "      - \"8443:443\"\n      - \"9000:9000\"\n")
        .replacingOccurrences(of: "  The dashboard is under maintenance.\n  Please come back in a few minutes.\n", with: "  Back online at 2 pm.\n"))
    let diffList = Diff.lines(original, b(r))
    #expect(diffList.count == 5, "\(diffList)")
}
