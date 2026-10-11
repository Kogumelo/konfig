import AppKit
import ConfCore

/// `KONFIG_SELFTEST="<file>|<output-folder>" Konfig.app/Contents/MacOS/Konfig`
///
/// The file is a copy of `examples/config.toml`, `examples/config.json`,
/// `examples/config.jsonc`, `examples/settings.jsonc`, `examples/config.json5` or
/// `examples/.env`, `examples/config.ini` or `examples/config.yaml`, with the same name, or of `config.jsonc` named `something.json` (the
/// script for each format relies on the fields of those examples; the `.env` is
/// recognized by its name).
///
/// Keyboard-free diagnostics: opens the file, changes values through the same path
/// as the controls, saves via the ⌘S action (`saveDocument:`), undoes via the ⌘Z one
/// (`undo`), checks the bytes on disk and the `.bak`, saves screenshots of the window and
/// writes `report.txt` to the output folder. Then quits the app.
///
/// The steps are chained through the main queue (no `Task`/`await`), like
/// real events: each step runs, the event loop spins, the next one comes.
@MainActor
enum SelfTest {
    static var lines: [String] = []
    static var failures = 0
    static var activity: NSObjectProtocol?
    static var steps: [(expects: Double, does: () -> Void)] = []

    static func report(_ ok: Bool, _ s: String) {
        lines.append((ok ? "OK   " : "FAIL ") + s)
        if !ok { failures += 1 }
    }

    static func step(_ expects: Double = 0.3, _ f: @escaping () -> Void) { steps.append((expects, f)) }

    /// What changes from one format to another: which fields to change, how to break the text,
    /// how to add a key and how to simulate another program writing to the file.
    struct Script {
        var formatName: String
        /// Section shown in the screenshots.
        var section = "server"
        /// Field whose `a | b | c` comment becomes a choice (plain JSON has no comments).
        var choice: (field: String, options: [String])? = ("server.log_level", ["debug", "info", "warning", "error"])
        /// Three changes, each on a different line.
        var changes: [(field: String, value: Value)] = [
            ("database.pool", .integer(20)),
            ("server.ports", .array([.integer(8080), .integer(8443), .integer(9000)])),
            ("server.log_level", .text("warning")),
        ]
        /// The field of the first change: original value and what the "other program" writes.
        var pool: (original: Value, external: Value) = (.integer(12), .integer(30))
        var invalidText: (String) -> String
        var validText: (String) -> String
        var newPath: ValuePath
        var external: (from: String, to: String)
        /// `key[]` array (INI) or block sequence (YAML): adding an item must add only one line.
        var array: (field: String, item: Value)? = nil
        /// Valid text, but outside the form subset (YAML with an anchor): warning, not error.
        var textOutsideSubset: ((String) -> String)? = nil
    }

    static func script(_ file: URL) -> Script {
        switch Format(fileName: file.lastPathComponent) {
        case .json? where file.lastPathComponent.lowercased().hasPrefix("settings"):
            // examples/settings.jsonc, in the style of VS Code's settings.json (dotted keys)
            return Script(formatName: "JSONC",
                           section: FormSection.rootID,
                           choice: ("\"editor.wordWrap\"", ["off", "on", "wordWrapColumn", "bounded"]),
                           changes: [
                               ("\"editor.fontSize\"", .integer(16)),
                               ("\"editor.rulers\"", .array([.integer(80), .integer(100), .integer(120)])),
                               ("\"editor.wordWrap\"", .text("on")),
                           ],
                           pool: (.integer(14), .integer(18)),
                           invalidText: { $0.replacingOccurrences(of: "\"editor.fontSize\": 14,", with: "\"editor.fontSize\": ,") },
                           validText: { $0.replacingOccurrences(of: "\"editor.fontSize\": 14,", with: "\"editor.fontSize\": 14,\n  \"new\": 1,") },
                           newPath: [.key("new")],
                           external: ("\"editor.fontSize\": 14", "\"editor.fontSize\": 18"))
        case .json5?:
            return Script(formatName: "JSON5",
                           invalidText: { $0.replacingOccurrences(of: "version: 3,", with: "version: ,") },
                           validText: { $0.replacingOccurrences(of: "version: 3,", with: "version: 3,\n  new: 1,") },
                           newPath: [.key("new")],
                           external: ("pool: 12", "pool: 30"))
        // `config.jsonc`, or a copy of it named `.json` (then the window shows the "JSON with comments" notice)
        case .json? where file.pathExtension.lowercased() == "jsonc"
            || (try? JSONReader.parse([UInt8](Data(contentsOf: file))))?.usesJSONCExtensions == true:
            return Script(formatName: "JSONC",
                           invalidText: { $0.replacingOccurrences(of: "\"version\": 3,", with: "\"version\": ,") },
                           validText: { $0.replacingOccurrences(of: "\"version\": 3,", with: "\"version\": 3,\n  \"new\": 1,") },
                           newPath: [.key("new")],
                           external: ("\"pool\": 12", "\"pool\": 30"))
        case .json?:
            return Script(formatName: "JSON",
                           choice: nil,
                           invalidText: { $0.replacingOccurrences(of: "\"version\": 3,", with: "\"version\": ,") },
                           validText: { $0.replacingOccurrences(of: "\"version\": 3,", with: "\"version\": 3,\n    \"new\": 1,") },
                           newPath: [.key("new")],
                           external: ("\"pool\": 12", "\"pool\": 30"))
        case .env?:
            return Script(formatName: ".env",
                           section: FormSection.rootID,
                           choice: ("LOG_LEVEL", ["debug", "info", "warning", "error"]),
                           changes: [
                               ("DATABASE_POOL", .text("20")),
                               ("LOG_LEVEL", .text("warning")),
                               ("APP_TITLE", .text("Kogumelo Dashboard 2")),
                           ],
                           pool: (.text("12"), .text("30")),
                           invalidText: { $0 + "\nNO_EQUALS\n" },
                           validText: { $0 + "\nNEW_VAR=1\n" },
                           newPath: [.key("NEW_VAR")],
                           external: ("DATABASE_POOL=12", "DATABASE_POOL=30"))
        case .ini?:
            // examples/config.ini (CRLF): the changes and the new text use the file's line break
            return Script(formatName: "INI",
                           changes: [
                               ("database.pool", .text("20")),
                               ("server.port", .text("8443")),
                               ("server.log_level", .text("warning")),
                           ],
                           pool: (.text("12"), .text("30")),
                           invalidText: { $0 + "\r\nNO_EQUALS\r\n" },
                           validText: { $0 + "\r\n[new]\r\nx = 1\r\n" },
                           newPath: [.key("new"), .key("x")],
                           external: ("pool = 12", "pool = 30"),
                           array: ("php.\"extensions[]\"", .text("zip")))
        case .yaml?:
            // examples/config.yaml, in the style of a docker-compose file
            return Script(formatName: "YAML",
                           section: "services.web",
                           choice: ("services.web.restart", ["no", "always", "on-failure", "unless-stopped"]),
                           changes: [
                               ("pool", .integer(20)),
                               ("log_level", .text("warning")),
                               ("services.web.image", .text("nginx:1.28-alpine")),
                           ],
                           invalidText: { $0 + "\nbroken: [no end\n" },
                           validText: { $0 + "\nnew: 1\n" },
                           newPath: [.key("new")],
                           external: ("pool: 12", "pool: 30"),
                           array: ("services.web.ports", .text("9000:9000")),
                           textOutsideSubset: { $0 + "\nbase: &b {a: 1}\ncopy: *b\n" })
        default:
            return Script(formatName: "TOML",
                           invalidText: { $0 + "\n[new]\nx = \n" },
                           validText: { $0 + "\n[new]\nx = 1\n" },
                           newPath: [.key("new"), .key("x")],
                           external: ("pool = 12", "pool = 30"))
        }
    }

    static func nextOne() {
        guard !steps.isEmpty else { return }
        let p = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + p.expects) {
            p.does()
            nextOne()
        }
    }

    /// An action as if it were a click: after it, a real event goes through
    /// `NSApplication`, which at the end of dispatch closes the automatic undo group
    /// (that is what marks the document as edited on a real click).
    static func asEvent(_ doc: Document, _ f: () -> Void) {
        f()
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    static func run(file: URL, output: URL) {
        // No App Nap: the app runs in the background and the timers must not be delayed.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                          reason: "self-test")
        // Watchdog: if something opens an alert and hangs, quit after 60 s.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 60)
            let t = "FAIL timed out (alert open or hang)\n"
            try? t.write(to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            print(t, terminator: "")
            exit(2)
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bak = file.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: bak)
        let original = (try? Data(contentsOf: file)) ?? Data()
        let r = script(file)

        var doc: Document!
        var m: WindowModel { doc.model }
        var window: NSWindow? { doc.windowControllers.first?.window }
        func field(_ c: String) -> Field? { m.sections.flatMap(\.fields).first { $0.path.text == c } }

        NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { d, _, error in
            guard let d = d as? Document else {
                report(false, "open: \(error.map { "\($0)" } ?? "-")")
                return end(output)
            }
            doc = d
            nextOne()
        }

        step(1.5) {
            report(window?.isVisible == true, "window open: \(window?.title ?? "-")")
            report(m.session.document?.formatName == r.formatName, "read as \(r.formatName)")
            report(m.jsoncNotice == (file.pathExtension.lowercased() == "json" && r.formatName == "JSONC"),
                     "'JSON with comments' notice \(m.jsoncNotice ? "shown" : "not shown")")
            report((try? m.session.result()).map { Data($0) } == original, "open without changing: same bytes")
            if m.preambleComment != nil { m.selection = WindowModel.preambleID }
        }
        var preamble: String?
        step(0.8) {
            preamble = m.preambleComment
            guard let c = preamble else { return }
            screenshot(window, output.appendingPathComponent("0-preamble.png"))
            report(true, "preamble comment in 'About the file': \(c.split(separator: "\n").first ?? "")")
            asEvent(doc) { m.setPreamble(c + "\nself-test line") }
        }
        step(0.5) {
            guard let c = preamble else { return }
            let t = m.hunks
            report(m.preambleComment == c + "\nself-test line"
                     && t.count == 1 && t[0].hunk.removed.isEmpty && t[0].hunk.added.count == 1,
                     "editing the preamble comment: only one new line (\(t.first?.hunk.added.first ?? "-"))")
            screenshot(window, output.appendingPathComponent("0-preamble-edited.png"))
            asEvent(doc) { doc.undoManager?.undo() }
        }
        step(0.5) {
            if let c = preamble {
                report(m.preambleComment == c && (try? m.session.result()).map { Data($0) } == original,
                         "⌘Z undid the comment edit")
            }
            m.selection = r.section
        }
        step(0.8) {
            screenshot(window, output.appendingPathComponent("1-form.png"))
            if let e = r.choice {
                report(field(e.field)?.kind == .choice(e.options), "'a | b | c' comment became a choice")
            } else {
                report(m.sections.flatMap(\.fields).allSatisfy { $0.help == nil }, "no comments, no field with help")
            }
        }
        if let l = r.array {
            step {
                guard let c = field(l.field), case .array(let items) = c.value else {
                    return report(false, "array \(l.field) not found")
                }
                asEvent(doc) { m.assign(c, .value(.array(items + [l.item]))) }
            }
            step(0.5) {
                let t = m.hunks
                report(t.count == 1 && t[0].hunk.removed.isEmpty && t[0].hunk.added.count == 1,
                         "adding an item to array \(l.field): only one new line (\(t.first?.hunk.added.first ?? "-"))")
                asEvent(doc) { doc.undoManager?.undo() }
            }
            step(0.5) {
                report(m.hunks.isEmpty && !m.session.hasChanges, "⌘Z undid the added item")
            }
        }
        // Three changes, each as a separate event (like three clicks).
        for a in r.changes {
            step { asEvent(doc) { m.assign(field(a.field)!, .value(a.value)) } }
        }
        step(0.8) {
            report(doc.isDocumentEdited, "document marked as edited (title with '— Edited')")
            report(m.hunks.count == 3, "changes panel with 3 hunks")
            screenshot(window, output.appendingPathComponent("2-changed.png"))
            // ⌘S
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: doc, from: nil)
        }
        step(2) {
            let saved = (try? Data(contentsOf: file)) ?? Data()
            report((try? Data(contentsOf: bak)) == original, ".bak created with the previous content")
            let diffList = Diff.lines([UInt8](original), [UInt8](saved))
            let changedOnes = diffList.flatMap { t in t.removed.map { "- " + $0 } + t.added.map { "+ " + $0 } }
            lines.append("     lines changed on disk:\n" + changedOnes.map { "        " + $0 }.joined(separator: "\n"))
            report(diffList.count == 3 && diffList.allSatisfy { $0.removed.count == 1 && $0.added.count == 1 },
                     "saving changed only the 3 changed lines")
            report(!doc.isDocumentEdited, "after saving, document clean")
        }
        // ⌘Z three times
        for _ in 0..<3 { step { asEvent(doc) { doc.undoManager?.undo() } } }
        step(0.5) {
            let pool = r.changes[0].field
            report(m.session.value(field(pool)!.path) == r.pool.original, "⌘Z undid \(pool) (back to \(r.pool.original))")
            report(m.hunks.count == 3, "after ⌘Z, the 3 lines are pending again relative to disk")
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: doc, from: nil)
        }
        step(2) {
            report((try? Data(contentsOf: file)) == original, "undo everything and save: file identical to the original")
            m.switchMode(.text)
            m.draft = r.invalidText(String(decoding: original, as: UTF8.self))
        }
        step(0.8) {
            report(m.draftError != nil, "invalid text shows an error: \(m.draftError?.description ?? "-")")
            screenshot(window, output.appendingPathComponent("3-text-error.png"))
            report(!m.applyDraft(), "invalid text is not applied")
            if let f = r.textOutsideSubset {
                m.draft = f(String(decoding: original, as: UTF8.self))
                report(m.draftError == nil && m.draftWarning?.outsideSubset == true,
                         "text outside the subset: warning, not error (\(m.draftWarning?.description ?? "-"))")
                screenshot(window, output.appendingPathComponent("3b-text-outside-subset.png"))
            }
            m.draft = r.validText(String(decoding: original, as: UTF8.self))
            report(m.draftError == nil && m.draftFormat == r.formatName, "valid text recognized as \(m.draftFormat)")
            var applied = false
            asEvent(doc) { applied = m.applyDraft() }
            report(applied && m.session.document?.entry(r.newPath) != nil, "valid text applied")
        }
        step {
            asEvent(doc) { doc.undoManager?.undo() }
            report(m.session.hasChanges == false, "⌘Z undid the text edit")
            m.switchMode(.form)
            // Another program writes to the file with no pending edit: the document reloads by itself.
            let external = String(decoding: original, as: UTF8.self).replacingOccurrences(of: r.external.from, with: r.external.to)
            try? external.write(to: file, atomically: true, encoding: .utf8)
        }
        step(3) {
            report(m.session.value(field(r.changes[0].field)?.path ?? []) == r.pool.external,
                     "file changed by another program and no pending edit: reloaded (\(r.external.to))")
            if r.section != FormSection.rootID { m.selection = "database" }
        }
        step(0.8) {
            screenshot(window, output.appendingPathComponent("4-reloaded.png"))
            try? original.write(to: file)
            end(output)
        }
    }

    static func end(_ output: URL) {
        lines.append(failures == 0 ? "RESULT: all good" : "RESULT: \(failures) failure(s)")
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(text, terminator: "")
        for d in NSDocumentController.shared.documents { d.close() }
        exit(failures == 0 ? 0 : 1)
    }

    /// Screenshot of the window itself (does not need Screen Recording permission).
    static func screenshot(_ w: NSWindow?, _ url: URL) {
        guard let v = w?.contentView?.superview ?? w?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
