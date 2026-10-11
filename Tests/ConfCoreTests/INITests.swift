import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
/// Path of a key in a section (`""` = General, before the first section).
private func k(_ section: String, _ key: String) -> ValuePath { [.key(section), .key(key)] }

/// Applies one change to an INI and returns the new text.
private func swap(_ text: String, _ c: ValuePath, _ v: Value) throws -> String {
    s(try Writer.apply(b(text), changes: [c: .value(v)], format: .ini))
}
private func swap(_ text: String, _ key: String, _ v: String) throws -> String {
    try swap(text, k("", key), .text(v))
}

private func values(_ doc: ConfDocument) -> [String: Value] {
    var r: [String: Value] = [:]
    for e in doc.entries { r[e.path.map { if case .key(let c) = $0 { return c }; return "" }.joined(separator: "/")] = e.value }
    return r
}

enum INIFixtures {
    static let folder = Suite.folder.appendingPathComponent("ini")
    static let all: [String] = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasSuffix(".ini") || $0.hasSuffix(".editorconfig") }.sorted() ?? []
    static func bytes(_ name: String) -> [UInt8] {
        Array(try! Data(contentsOf: folder.appendingPathComponent(name)))
    }
}

private let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

// MARK: - Reading rules

@Test func iniHasFixtures() {
    #expect(INIFixtures.all == ["arrays.ini", "bom-crlf.ini", "editorconfig-core-go.editorconfig",
                                  "editorconfig-core-js.editorconfig", "php.ini-production-excerpt.ini", "rules.ini"])
}

@Test func iniRules() throws {
    let doc = try INIReader.parse(INIFixtures.bytes("rules.ini"))
    let v = values(doc)
    // before the first section: "General" (key "" in the structure)
    #expect(v["/before_section"] == .text("goes to \"General\""))
    #expect(v["/colon"] == .text("separator ':'"), "key: value")
    #expect(v["/indented"] == .text("spaces at the ends do not count"))
    #expect(v["/empty"] == .text("") && v["/empty_with_comment"] == .text(""))
    #expect(v["/attached_semicolon"] == .text("a;b"), "';' without a space before it is part of the value")
    #expect(v["/attached_hash"] == .text("a#b"))
    #expect(v["/url"] == .text("http://x/#a"))
    #expect(v["/comment_at_end"] == .text("value"))
    #expect(v["/comment_tab"] == .text("value"))
    #expect(v["/color"] == .text("#DD0000"), "'#' at the start of the value is part of the value")
    #expect(v["/equals_in_value"] == .text("a=b=c"))
    #expect(v["/colon_in_value"] == .text(#"c:\folder"#), "the first separator wins")
    #expect(v["/interpolation"] == .text("%(home)s/bin and ${HOME}"), "interpolation stays as text")
    // sections
    #expect(v["section with spaces/double"] == .text("  with spaces ; and # inside  "), "double quotes, no escapes")
    #expect(v["section with spaces/single"] == .text("quotes \"double\" inside"))
    #expect(v["section with spaces/double_comment"] == .text("x"))
    #expect(v["section with spaces/double_empty"] == .text(""))
    #expect(v["section with spaces/accents"] == .text("ação 😀"))
    #expect(v["a.b/x"] == .text("1") && v["a.b/y"] == .text("2"), "literal dot; a repeated section continues the first one")
    #expect(v["*.[ch]/indent_size"] == .text("4"), "brackets inside the name (EditorConfig)")
    #expect(v["remote \"origin\"/url"] == .text("git@example:repo.git"), "a Git subsection is just a name")
    #expect(doc.headers.map(\.names) == [["section with spaces"], ["a.b"], ["*.[ch]"], ["remote \"origin\""]])
    #expect(doc.root["a"] == nil, "[a.b] does not create section 'a'")

    // comments
    let e = doc.entry(k("", "before_section"))!
    #expect(e.commentAbove == ["comment right above a key becomes help"], "a blank line separates; ';;' is dropped")
    #expect(e.section == nil && e.writtenKey == "before_section")
    #expect(doc.entry(k("", "empty_with_comment"))?.trailingComment == "only a comment")
    #expect(doc.entry(k("", "comment_at_end"))?.trailingComment == "comment")
    #expect(doc.entry(k("", "comment_tab"))?.trailingComment == "after a tab")
    #expect(doc.entry(k("", "url"))?.trailingComment == nil)
    #expect(doc.headers[1].trailingComment == "dot is literal")
    #expect(doc.entry(k("a.b", "y"))?.commentAbove == ["repeated section continues the first one"])
    // ranges
    #expect(doc.text(doc.entry(k("", "indented"))!.range) == "spaces at the ends do not count")
    #expect(doc.text(doc.entry(k("section with spaces", "double"))!.range) == "\"  with spaces ; and # inside  \"")
    #expect(doc.entry(k("", "empty"))!.range.isEmpty)
    #expect(doc.lineBreak == "\n" && !doc.hasBOM)
}

@Test func iniSectionsOnScreen() throws {
    let doc = try INIReader.parse(INIFixtures.bytes("rules.ini"))
    let sections = Fields.sections(doc)
    #expect(sections.map(\.title) == ["General", "section with spaces", "a.b", "*.[ch]", "remote \"origin\""])
    #expect(sections.map(\.subtitle).dropFirst() == ["[section with spaces]", "[a.b]", "[*.[ch]]", "[remote \"origin\"]"])
    #expect(sections[2].fields.map(\.label) == ["x", "y"])
    #expect(Set(sections.map(\.id)).count == sections.count)
    let choice = sections[1].fields.first { $0.label == "choice" }
    #expect(choice?.kind == .choice(["a", "b", "c"]))
    #expect(sections[0].fields.first { $0.label == "before_section" }?.help == "comment right above a key becomes help")
    #expect(sections[0].fields.allSatisfy { $0.kind == .text }, "every value is text")
}

@Test func iniArrays() throws {
    let doc = try INIReader.parse(INIFixtures.bytes("arrays.ini"))
    let v = values(doc)
    #expect(v["php/ext[]"] == .array([.text("curl"), .text("gd"), .text("intl")]), "'ext []' is the same array")
    #expect(v["interleaved/item[]"] == .array([.text("a"), .text("b")]))
    #expect(v["interleaved/other"] == .text("x"))
    #expect(v["extensions/extension"] == .array([.text("curl"), .text("gd")]), "repeated extension (PHP) is an array")
    #expect(v["extensions/zend_extension"] == .array([.text("opcache")]))
    let ext = doc.entry(k("php", "ext[]"))!
    #expect(ext.line == 4 && ext.lastLine == 6)
    #expect(ext.commentAbove == ["loaded extensions"])
    #expect(ext.position.items.map { doc.text($0.range) } == ["curl", "\"gd\"", "intl"])
    let field = Fields.sections(doc).flatMap(\.fields).first { $0.label == "ext[]" }
    #expect(field?.kind == .array(.text))
}

@Test func iniCRLFAndBOM() throws {
    let doc = try INIReader.parse(INIFixtures.bytes("bom-crlf.ini"))
    #expect(doc.hasBOM && doc.lineBreak == "\r\n")
    let v = values(doc)
    #expect(v["/name"] == .text("ação"))
    #expect(v["sec/list[]"] == .array([.text("1"), .text("2")]))
    #expect(v["sec/end"] == .text("no final newline"))
    #expect(doc.entry(k("", "name"))?.commentAbove == ["with BOM and CRLF"])
}

@Test(arguments: [
    ("a = 1\nb\n", 2, 1, "is not a section"),
    ("key without separator\n", 1, 1, "is not a section"),
    ("= 1\n", 1, 1, "missing key name"),
    ("[a]\nx = 1\n\nx = 2\n", 4, 1, "already appeared on line 2 in section [a]"),
    ("x = 1\nx = 2\n", 2, 1, "before the first section"),
    ("[a]\nx = 1\n[b]\n[a]\nx = 2\n", 5, 1, "already appeared on line 2"),
    ("[no end\n", 1, 1, "without ']'"),
    ("[a] b\n", 1, 1, "without ']'"),
    ("[  ]\n", 1, 1, "section without a name"),
    ("a = \"x\n", 1, 5, "not closed"),
    ("a = 'x\" \n", 1, 5, "not closed"),
    ("a = \"x\" y\n", 1, 9, "may follow the quotes"),
    ("a = 1\rb = 2\n", 1, 6, "lone CR"),
    ("[]= 1\n", 1, 1, "without ']'"),
    ("  [] = 1\n", 1, 3, "without ']'"),
    ("x[] = 1\nx = 2\n", 2, 1, "are not accepted"),
    ("x = 1\nx[] = 2\n", 2, 1, "are not accepted"),
    ("    value continuation\n", 1, 5, "is not a section"),
])
func iniRejectsWithLineAndColumn(_ testCase: (String, Int, Int, String)) {
    do {
        let doc = try INIReader.parse(testCase.0)
        Issue.record("accepted \(testCase.0.debugDescription): \(values(doc))")
    } catch {
        #expect(error.line == testCase.1 && error.column == testCase.2, "\(testCase.0.debugDescription): \(error)")
        #expect(error.message.contains(testCase.3), "\(error)")
        #expect(error.format == .ini)
    }
}

@Test func iniInvalidUTF8() {
    #expect(throws: ParseError.self) { try INIReader.parse([0x61, 0x3D, 0xE7, 0x0A]) }
}

@Test func iniParseValue() throws {
    #expect(try INIReader.parseValue("abc") == .text("abc"))
    #expect(try INIReader.parseValue("'a;b'") == .text("a;b"))
    #expect(try INIReader.parseValue("  x y  ") == .text("x y"))
    #expect(throws: ParseError.self) { try INIReader.parseValue("abc ; x") }
    #expect(throws: ParseError.self) { try INIReader.parseValue("\"abc") }
    #expect(throws: ParseError.self) { try INIReader.parseValue("a\nb = 2") }
}

@Test func iniFormatFromName() {
    #expect(Format(fileName: "php.ini") == .ini)
    #expect(Format(fileName: "desktop.INI") == .ini)
    #expect(Format(fileName: ".editorconfig") == .ini)
    #expect(Format(fileName: "config.ini.bak") == nil)
    #expect(Format.ini.name == "INI")
}

// MARK: - Real files

@Test func iniRealEditorConfig() throws {
    let js = try INIReader.parse(INIFixtures.bytes("editorconfig-core-js.editorconfig"))
    let v = values(js)
    #expect(v["/root"] == .text("true"))
    #expect(v["*/indent_style"] == .text("space"))
    #expect(v["*/block_comment_start"] == .text("/**"))
    #expect(v["*/block_comment"] == .text("*"))
    #expect(v["*.md/indent_size"] == .text("4"))
    let go = try INIReader.parse(INIFixtures.bytes("editorconfig-core-go.editorconfig"))
    #expect(go.headers.map { $0.names[0] } == ["*", "{Makefile,*.go,.gitmodules}", "go.{mod,work,work.sum,sum}",
                                                  "*.md", "Dockerfile"])
    #expect(values(go)["*.md/eclint_indent_style"] == .text("unset"))
}

@Test func iniRealPHP() throws {
    let doc = try INIReader.parse(INIFixtures.bytes("php.ini-production-excerpt.ini"))
    let v = values(doc)
    #expect(v["PHP/engine"] == .text("On"))
    #expect(v["PHP/error_reporting"] == .text("E_ALL & ~E_DEPRECATED"))
    #expect(v["PHP/variables_order"] == .text("GPCS"))
    #expect(v["PHP/auto_prepend_file"] == .text(""))
    #expect(v["Session/session.trans_sid_tags"] == .text("a=href,area=href,frame=src,form="))
    #expect(v["Session/session.cookie_path"] == .text("/"))
    #expect(doc.headers.map { $0.names[0] }.contains("CLI Server"))
    // the extensions come commented out (`;extension=…`): none becomes a key
    #expect(doc.entries.allSatisfy { $0.writtenKey != "extension" })
}

// MARK: - Saving: quotes and style

@Test func iniSaveKeepsQuotes() throws {
    // unquoted stays unquoted when it fits
    #expect(try swap("a = 1\n", "a", "2") == "a = 2\n")
    #expect(try swap("a: x ; c\n", "a", "y") == "a: y ; c\n")
    #expect(try swap("a=x\n", "a", "http://x/#b") == "a=http://x/#b\n")
    #expect(try swap("a=x\n", "a", "a#b") == "a=a#b\n")
    // does not fit unquoted: double quotes
    #expect(try swap("a = x ; c\n", "a", "a;b") == "a = \"a;b\" ; c\n")
    #expect(try swap("a = x\n", "a", "a #b") == "a = \"a #b\"\n")
    #expect(try swap("a = x\n", "a", "#DD0000") == "a = \"#DD0000\"\n")
    #expect(try swap("a = x\n", "a", " ends ") == "a = \" ends \"\n")
    #expect(try swap("a = x\n", "a", "\"hi\"") == "a = '\"hi\"'\n", "with double quotes: single")
    #expect(try swap("a = x\n", "a", "it's") == "a = it's\n", "a quote in the middle fits unquoted")
    // single stays single; double stays double; switches if the text contains that quote
    #expect(try swap("a = 'x'\n", "a", "y z") == "a = 'y z'\n")
    #expect(try swap("a = 'x'\n", "a", "it's") == "a = \"it's\"\n")
    #expect(try swap("a = \"x\"\n", "a", "y") == "a = \"y\"\n")
    #expect(try swap("a = \"x\"  ; c\n", "a", "say \"hi\"") == "a = 'say \"hi\"'  ; c\n")
    #expect(try swap("a = \"x\"\n", "a", "") == "a = \"\"\n")
    // empty value
    #expect(try swap("a =\n", "a", "v") == "a = v\n")
    #expect(try swap("a=\n", "a", "v") == "a=v\n")
    #expect(try swap("a =   ; c\n", "a", "v") == "a = v   ; c\n")
    #expect(try swap("a =; c\n", "a", "v") == "a = v ; c\n")
    #expect(try swap("a = x ; c\n", "a", "") == "a =  ; c\n")
    // CRLF and section
    #expect(try swap("[s]\r\nk = 1\r\n", k("s", "k"), .text("2")) == "[s]\r\nk = 2\r\n")
}

@Test func iniRejectsWhatDoesNotFit() {
    var ed = EditSession(b("a = 1\nl[] = x\n"), format: .ini)
    #expect(throws: SaveError.self) { try ed.assign(k("", "a"), .value(.integer(2))) }
    #expect(throws: SaveError.self) { try ed.assign(k("", "a"), .value(.text("a\nb"))) }
    #expect(throws: SaveError.self) { try ed.assign(k("", "a"), .value(.text("'a;b\""))) }
    #expect(throws: SaveError.self) { try ed.assign(k("", "l[]"), .value(.array([]))) }
    #expect(throws: SaveError.self) { try ed.assign(k("", "l[]"), .value(.array([.integer(1)]))) }
    #expect(throws: SaveError.self) { try ed.assign(k("", "a"), .raw("x ; y")) }
    #expect(throws: ParseError.self) { try ed.replaceText(b("a = 1\na = 2\n")) }
}

// MARK: - Arrays: adding and removing lines

@Test func iniArrayAddsOneLine() throws {
    let text = "[php]\next[] = curl\next[] = \"gd\" ; c\nmemory_limit = 128M\n"
    let c = k("php", "ext[]")
    let r = try swap(text, c, .array([.text("curl"), .text("gd"), .text("intl")]))
    #expect(r == "[php]\next[] = curl\next[] = \"gd\" ; c\next[] = \"intl\"\nmemory_limit = 128M\n")
    let diffList = Diff.lines(b(text), b(r))
    #expect(diffList.count == 1 && diffList[0].removed.isEmpty && diffList[0].added == ["ext[] = \"intl\""])
    // indentation and separator copied; CRLF
    #expect(try swap("[a]\r\n  x[]=1\r\n", k("a", "x[]"), .array([.text("1"), .text("2")]))
        == "[a]\r\n  x[]=1\r\n  x[]=2\r\n")
    // empty last item with a space before the '='
    #expect(try swap("x[] =\n", k("", "x[]"), .array([.text(""), .text("b")])) == "x[] =\nx[] = b\n")
    // last one without a final line break
    #expect(try swap("x[] = a", k("", "x[]"), .array([.text("a"), .text("b")])) == "x[] = a\nx[] = b")
    // PHP's extension=
    #expect(try swap("extension=curl\nextension=gd\n", k("", "extension"), .array([.text("curl"), .text("gd"), .text("intl")]))
        == "extension=curl\nextension=gd\nextension=intl\n")
}

@Test func iniArrayRemovesOneLine() throws {
    let text = "; top\nx[] = a\n; about b\nx[] = b\nx[] = c\nend = 1\n"
    let c = k("", "x[]")
    #expect(try swap(text, c, .array([.text("b"), .text("c")])) == "; top\n; about b\nx[] = b\nx[] = c\nend = 1\n")
    #expect(try swap(text, c, .array([.text("a"), .text("c")])) == "; top\nx[] = a\n; about b\nx[] = c\nend = 1\n")
    #expect(try swap(text, c, .array([.text("a"), .text("b")])) == "; top\nx[] = a\n; about b\nx[] = b\nend = 1\n")
    // the comment above a removed item stays
    #expect(try swap(text, c, .array([.text("a")])) == "; top\nx[] = a\n; about b\nend = 1\n")
    #expect(try swap(text, c, .array([.text("c")])) == "; top\n; about b\nx[] = c\nend = 1\n")
    #expect(try swap("x[] = a\r\nx[] = b", c, .array([.text("a")])) == "x[] = a")
    #expect(try swap("x[] = a\r\nx[] = b\r\n", c, .array([.text("b")])) == "x[] = b\r\n")
    for (before, after) in [(text, try swap(text, c, .array([.text("a"), .text("c")])))] {
        let diffList = Diff.lines(b(before), b(after))
        #expect(diffList.count == 1 && diffList[0].removed == ["x[] = b"] && diffList[0].added.isEmpty)
    }
}

@Test func iniArrayChangesOneItem() throws {
    let text = "x[] = a\nx[] = 'b' ; c\nx[] = c\n"
    let r = try swap(text, k("", "x[]"), .array([.text("a"), .text("B 2"), .text("c")]))
    #expect(r == "x[] = a\nx[] = 'B 2' ; c\nx[] = c\n")
    // mixed: change one and add another
    let r2 = try swap(text, k("", "x[]"), .array([.text("A"), .text("b"), .text("c"), .text("d")]))
    #expect(r2 == "x[] = A\nx[] = 'b' ; c\nx[] = c\nx[] = d\n")
}

@Test func iniArrayInterleavedWithOtherKey() throws {
    // the array spans the lines from 'a' to 'b', with 'other' in between: the two changes
    // overlap and are applied one at a time
    let original = INIFixtures.bytes("arrays.ini")
    var ed = EditSession(original, format: .ini)
    try ed.assign(k("interleaved", "other"), .value(.text("y")))
    try ed.assign(k("interleaved", "item[]"), .value(.array([.text("a"), .text("b"), .text("c")])))
    let r = s(try ed.result())
    #expect(r == s(original).replacingOccurrences(of: "other = x", with: "other = y")
        .replacingOccurrences(of: "item[] = b\n", with: "item[] = b\nitem[] = c\n"))
}

@Test func iniUndoRestoresOriginal() throws {
    let original = INIFixtures.bytes("arrays.ini")
    var ed = EditSession(original, format: .ini)
    let c = k("php", "ext[]")
    let before = ed.effective(c)!
    try ed.assign(c, .value(.array([.text("curl"), .text("gd"), .text("intl"), .text("zip")])))
    #expect(try ed.result() != original)
    try ed.assign(c, before)
    #expect(try ed.result() == original)
}

// MARK: - Criteria 2 and 3 on every file (the same tests as TOML, JSON and .env)

private let iniSpecials: [String: [UInt8]] = [
    "empty": [],
    "comments-only": b("; nothing\n\n# here\n"),
    "no-final-newline": b("a = 1\n[s]\nb = 'two'"),
    "crlf-bom-arrays": [0xEF, 0xBB, 0xBF] + b("; c\r\na = \"x y\" ; z\r\n\r\n[s]\r\nl[] = 1\r\nl[] =\r\nc =\r\n"),
    "indented": b("  a = 1\n\tb:\t\"2\"\t# c\n [s] \n  c=3\n"),
    "sections-only": b("[a]\n[b]\n"),
]

private func iniCase(_ name: String) -> [UInt8] {
    if let x = iniSpecials[name] { return x }
    if name.hasPrefix("examples/") { return Array(try! Data(contentsOf: projectRoot.appendingPathComponent(name))) }
    return INIFixtures.bytes(name)
}

private let iniCases = INIFixtures.all + Array(iniSpecials.keys).sorted() + ["examples/config.ini"]

@Test(arguments: iniCases)
func iniNoChangeSameBytes(_ testCase: String) throws {
    let original = iniCase(testCase)
    var ed = EditSession(original, format: .ini)
    #expect(ed.error == nil, "\(String(describing: ed.error))")
    #expect(try ed.result() == original)
    #expect(!ed.hasChanges)
    for e in ed.document?.entries ?? [] {
        try ed.assign(e.path, .value(e.value))
        if case .text = e.value { try ed.assign(e.path, .raw(ed.document!.text(e.range))) }
    }
    #expect(ed.changes.isEmpty)
    #expect(try ed.result() == original)
}

@Test(arguments: iniCases)
func iniChangeEachValue(_ testCase: String) throws {
    let original = iniCase(testCase)
    let doc = try INIReader.parse(original)
    func matches(_ e: Entry, _ updated: Value, _ span: Range<Int>, _ name: String) throws {
        let output: [UInt8]
        do { output = try Writer.apply(original, changes: [e.path: .value(updated)], format: .ini) } catch {
            Issue.record("\(testCase) \(e.writtenKey) \(name): \(error)")
            return
        }
        #expect(onlyTheHunkChanged(original, output, span), "\(testCase) \(e.writtenKey) \(name): changed outside the hunk")
        let reparsed = try INIReader.parse(output)
        #expect(reparsed.rootValue == doc.rootValue.replacing(e.path, by: updated)!, "\(testCase) \(e.writtenKey)")
        #expect(reparsed.entries.map(\.trailingComment) == doc.entries.map(\.trailingComment), "\(testCase) \(e.writtenKey)")
        #expect(reparsed.hasBOM == doc.hasBOM && reparsed.lineBreak == doc.lineBreak)
    }
    for e in doc.entries {
        switch e.value {
        case .text(let t):
            // fits unquoted, needs quotes, has double quotes
            for updated in [t + "x", t + " ;x# ", "say \"hi\"" + t] {
                try matches(e, .text(updated), e.range, updated)
            }
            // the quote style is kept when the value fits in it
            let output = try Writer.apply(original, changes: [e.path: .value(.text(t + "x"))], format: .ini)
            let reparsed = try INIReader.parse(output)
            let before = doc.bytes[e.range].first, after = reparsed.entry(e.path).map { reparsed.bytes[$0.range].first }
            if before == 0x22 || before == 0x27 { #expect(after == before, "\(testCase) \(e.writtenKey)") }
        case .array(let items):
            // each item: only its own hunk changes
            for i in items.indices {
                guard case .text(let t) = items[i] else { continue }
                var l = items
                l[i] = .text(t + " ;x")
                try matches(e, .array(l), e.position.items[i].range, "item \(i)")
            }
            // adding: one more line, nothing removed
            let plus = try Writer.apply(original, changes: [e.path: .value(.array(items + [.text("new")]))], format: .ini)
            let diffList = Diff.lines(original, plus)
            #expect(diffList.count == 1 && diffList[0].removed.isEmpty && diffList[0].added.count == 1, "\(testCase) \(e.writtenKey): \(diffList)")
            try matches(e, .array(items + [.text("new")]), e.range, "add")
            // removing each item: one line fewer
            if items.count > 1 {
                for i in items.indices {
                    var l = items
                    l.remove(at: i)
                    let minus = try Writer.apply(original, changes: [e.path: .value(.array(l))], format: .ini)
                    let d = Diff.lines(original, minus)
                    #expect(d.count == 1 && d[0].removed.count == 1 && d[0].added.isEmpty, "\(testCase) \(e.writtenKey) -\(i): \(d)")
                    try matches(e, .array(l), e.range, "remove \(i)")
                }
            }
        default:
            Issue.record("value that is neither text nor an array")
        }
    }
}

// MARK: - Example

@Test func exampleINI() throws {
    let original = Array(try Data(contentsOf: projectRoot.appendingPathComponent("examples/config.ini")))
    #expect(original.contains(0x0D), "the example uses CRLF")
    let doc = try INIReader.parse(original)
    #expect(doc.lineBreak == "\r\n")
    let sections = Fields.sections(doc)
    #expect(sections.map(\.title) == ["General", "server", "database", "php", "log.file"])
    let fields = Dictionary(uniqueKeysWithValues: sections.flatMap(\.fields).map { ($0.id, $0) })
    #expect(fields["server.log_level"]?.kind == .choice(["debug", "info", "warning", "error"]))
    #expect(fields["database.driver"]?.kind == .choice(["firebird", "postgres"]))
    #expect(fields["server.url"]?.value == .text("http://x/#a"))
    #expect(fields["database.pool"]?.help == "simultaneous connections")
    #expect(fields["php.\"extensions[]\""]?.kind == .array(.text))
    #expect(fields["php.color"]?.value == .text("#DD0000"))

    var ed = EditSession(original, format: .ini)
    try ed.assign(k("database", "pool"), .value(.text("20")))
    try ed.assign(k("server", "log_level"), .value(.text("warning")))
    try ed.assign(k("server", "title"), .value(.text("Kogumelo Dashboard 2")))
    try ed.assign(k("php", "extensions[]"), .value(.array([.text("curl"), .text("gd"), .text("intl"), .text("zip")])))
    let r = s(try ed.result())
    #expect(r == s(original).replacingOccurrences(of: "pool = 12 ", with: "pool = 20 ")
        .replacingOccurrences(of: "log_level = info", with: "log_level = warning")
        .replacingOccurrences(of: "\"Kogumelo Dashboard\"", with: "\"Kogumelo Dashboard 2\"")
        .replacingOccurrences(of: "extensions[] = intl\r\n", with: "extensions[] = intl\r\nextensions[] = zip\r\n"))
    // log_level and title are on adjacent lines: a single hunk
    let diffList = Diff.lines(original, b(r))
    #expect(diffList.count == 3, "\(diffList)")
    // 3 lines replaced and 1 added (the array item)
    #expect(diffList.flatMap(\.removed).count == 3 && diffList.flatMap(\.added).count == 4, "\(diffList)")
}
