import Foundation
import Testing
@testable import ConfCore

// The two promises the app makes for every format, checked on the real examples:
// a save changes only what was edited (no key and no comment lost), and a file the reader
// refuses is never rewritten. Files written here go to a temporary folder only.

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

private let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private let examples: [String: Format] = [
    "config.toml": .toml, "config.json": .json, "config.jsonc": .json, "settings.jsonc": .json,
    "config.json5": .json5, ".env": .env, "config.ini": .ini, "config.yaml": .yaml,
]

private func example(_ name: String) -> [UInt8] {
    Array(try! Data(contentsOf: projectRoot.appendingPathComponent("examples").appendingPathComponent(name)))
}

/// A different scalar of the same kind, accepted by the format; `nil` for arrays and tables.
private func edited(_ v: Value, _ format: Format) -> Value? {
    let r: Value
    switch v {
    case .text(let s): r = .text(s + "z")
    case .integer(let n): r = .integer(n + 1)
    case .decimal(let d): r = .decimal(d + 1.5)
    case .boolean(let x): r = .boolean(!x)
    default: return nil
    }
    return format.problem(r) == nil ? r : nil
}

// MARK: - Round trip: no key and no comment lost

@Test func everyFormatHasAnExample() {
    #expect(Set(examples.values) == Set(Format.allCases))
}

@Test(arguments: examples.keys.sorted())
func exampleRoundTripKeepsKeysAndComments(_ name: String) throws {
    let format = examples[name]!, original = example(name)
    let doc = try format.parse(original)
    let preamble = Fields.preambleComment(doc)
    var edits = 0
    for e in doc.entries {
        guard let updated = edited(e.value, format) else { continue }
        edits += 1
        var ed = EditSession(original, format: format)
        try ed.assign(e.path, .value(updated))
        let saved = try ed.result()
        let after = try format.parse(saved)
        #expect(after.entries.map(\.path) == doc.entries.map(\.path), "\(name) \(e.path.text): keys changed")
        for (x, y) in zip(doc.entries, after.entries) {
            #expect(y.value == (x.path == e.path ? updated : x.value), "\(name) \(e.path.text) → \(x.path.text)")
            #expect(y.commentAbove == x.commentAbove, "\(name) \(e.path.text): comment above \(x.path.text) lost")
            #expect(y.trailingComment == x.trailingComment, "\(name) \(e.path.text): comment after \(x.path.text) lost")
        }
        #expect(Fields.preambleComment(after) == preamble, "\(name) \(e.path.text): opening comment changed")
        #expect(after.hasBOM == doc.hasBOM && after.lineBreak == doc.lineBreak)
        #expect(onlyTheHunkChanged(original, saved, e.range), "\(name) \(e.path.text): changed outside the value")
        // putting the old value back restores it, again touching only its span (the spelling may differ:
        // 1e3 comes back as 1000, and an INI value starting with '#' comes back quoted)
        var back = EditSession(saved, format: format)
        try back.assign(e.path, .value(e.value))
        let undone = try back.result()
        #expect(onlyTheHunkChanged(original, undone, e.range), "\(name) \(e.path.text): undoing changed outside the value")
        #expect(try format.parse(undone).entries.map(\.value) == doc.entries.map(\.value))
    }
    #expect(edits > 0, "\(name): no editable value")
}

// MARK: - An invalid file is refused and kept intact

private let invalid: [(Format, String)] = [
    (.toml, "# keep me\na = 1\nb = \n"),
    (.json, "{\n  // keep me\n  \"a\": 1,\n  \"b\": \n}\n"),
    (.json5, "{\n  // keep me\n  a: 1,\n  b: ,\n}\n"),
    (.env, "# keep me\nA=1\nB\n"),
    (.ini, "; keep me\na = 1\na = 2\n"),
    (.yaml, "# keep me\na: 1\nb: [1, 2\n"),
]

@Test(arguments: invalid.indices)
func invalidFileIsRefusedAndKept(_ i: Int) throws {
    let (format, text) = invalid[i]
    let original = b(text)
    var ed = EditSession(original, format: format)
    #expect(ed.document == nil, "\(format.name): accepted an invalid file")
    let error = try #require(ed.error)
    #expect(!error.outsideSubset && !ed.textOnly)
    #expect(error.line >= 2 && error.column >= 1, "\(format.name): \(error)")
    // saving without changes writes back exactly what was read
    #expect(try ed.result() == original)
    #expect(!ed.hasChanges)
    // the form cannot change it, and neither can the writer
    #expect(throws: SaveError.self) { try ed.assign([.key("a")], .value(.integer(2))) }
    #expect(throws: SaveError.self) { try Writer.apply(original, changes: [[.key("a")]: .value(.integer(2))], format: format) }
    #expect(try ed.result() == original)
}

@Test(arguments: invalid.indices)
func invalidTextDoesNotReplaceAValidFile(_ i: Int) throws {
    let (format, text) = invalid[i]
    let name = examples.first { $0.value == format }!.key
    let original = example(name)
    var ed = EditSession(original, format: format)
    let e = try #require(ed.document?.entries.first { edited($0.value, format) != nil })
    try ed.assign(e.path, .value(edited(e.value, format)!))
    let pending = try ed.result()
    #expect(throws: ParseError.self) { try ed.replaceText(b(text)) }
    // the base text and the pending change survive the refused text
    #expect(ed.base == original && ed.document != nil)
    #expect(try ed.result() == pending)
}

// MARK: - The whole cycle on disk, in a temporary folder

@Test(arguments: examples.keys.sorted())
func saveCycleOnDisk(_ name: String) throws {
    let format = examples[name]!, original = example(name)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("konfig-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent(name)
    try Data(original).write(to: file)

    var ed = EditSession(Array(try Data(contentsOf: file)), format: format)
    let e = try #require(ed.document?.entries.first { edited($0.value, format) != nil })
    let updated = edited(e.value, format)!
    try ed.assign(e.path, .value(updated))
    let bytes = try ed.result()
    try Data(bytes).write(to: file, options: .atomic)
    ed.saved(bytes)
    #expect(!ed.hasChanges && ed.changes.isEmpty)

    let reopened = EditSession(Array(try Data(contentsOf: file)), format: format)
    #expect(reopened.value(e.path) == updated)
    #expect(try reopened.result() == bytes)
    #expect(example(name) == original, "the example in the project must not be touched")
}
