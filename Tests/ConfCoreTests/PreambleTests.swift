import Testing
@testable import ConfCore

private func preamble(_ text: String, _ format: Format = .toml) throws -> String? {
    Fields.preambleComment(try format.parse(Array(text.utf8)))
}

private func swap(_ text: String, _ updated: String, _ format: Format = .toml) throws -> String? {
    guard let r = Preamble.replace(Array(text.utf8), format: format, by: updated) else { return nil }
    _ = try format.parse(r)   // still valid
    return String(decoding: r, as: UTF8.self)
}

let calendar = """
    # The challenge calendar.
    #
    #   - a new event only starts on a future date
    #   - the key is forever

    # Fields: key, label

    # The challenge of the day
    [[challenge]]
    key = "blue"

    """

@Test func preambleSeparatedByBlankLine() throws {
    #expect(try preamble(calendar) == """
        The challenge calendar.

          - a new event only starts on a future date
          - the key is forever

        Fields: key, label
        """)
    // the block attached to the header is still the section help, and only that
    let doc = try TOMLReader.parse(Array(calendar.utf8))
    #expect(Fields.sections(doc).first { $0.group == "challenge" }?.help == "The challenge of the day")
}

@Test func attachedPreambleIsFieldHelp() throws {
    #expect(try preamble("# dashboard name\ntitle = \"x\"\n") == nil)
    #expect(try preamble("title = \"x\"\n# after\n") == nil)
    #expect(try preamble("") == nil)
    #expect(try preamble("\u{FEFF}# only a comment\r\n\r\na = 1\r\n") == "only a comment")
    #expect(try preamble("\n\n# loose\n\n\na = 1\n") == "loose")
}

@Test func preambleOtherFormats() throws {
    #expect(try preamble("; General\n# still\n\n[s]\na = 1\n", .ini) == "General\nstill")
    #expect(try preamble("# secrets\n\nA=1\n", .env) == "secrets")
    #expect(try preamble("// tsconfig\n{\n  \"a\": 1\n}\n", .json) == "tsconfig")
    #expect(try preamble("# compose\n\n---\nname: x\n", .yaml) == "compose")
    #expect(try preamble("# compose\n---\nname: x\n", .yaml) == nil)   // help of `name`
}

@Test func replaceOnlyChangedLines() throws {
    let updated = """
        The challenge calendar.

          - a new event only starts on a FUTURE date
          - the key is forever

        Fields: key, label, languages
        """
    #expect(try swap(calendar, updated) == """
        # The challenge calendar.
        #
        #   - a new event only starts on a FUTURE date
        #   - the key is forever

        # Fields: key, label, languages

        # The challenge of the day
        [[challenge]]
        key = "blue"

        """)
    // no change: the same bytes
    #expect(try swap(calendar, try #require(try preamble(calendar))) == calendar)
}

@Test func replaceAddsAndDeletes() throws {
    #expect(try swap("# a\n\nx = 1\n", "a\nb\n\nc") == "# a\n# b\n#\n# c\n\nx = 1\n")
    #expect(try swap("# a\n# b\n\n# help\nx = 1\n", "") == "# help\nx = 1\n")
    #expect(try swap("x = 1\n", "new") == nil)
}

@Test func replaceKeepsMarkerCRLFAndBOM() throws {
    #expect(try swap("\u{FEFF}; old\r\n\r\n[s]\r\na = 1\r\n", "new\nsecond", .ini)
            == "\u{FEFF}; new\r\n; second\r\n\r\n[s]\r\na = 1\r\n")
    #expect(try swap("// old\n{ \"a\": 1 }\n", "new", .json) == "// new\n{ \"a\": 1 }\n")
}
