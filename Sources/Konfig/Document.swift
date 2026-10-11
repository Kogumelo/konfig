import AppKit
import Observation
import SwiftUI
import ConfCore

enum Mode: String {
    case form, text
}

/// Hunk in the changes panel, with the key's name when it can be determined.
struct LabeledHunk: Identifiable {
    var hunk: Hunk
    var label: String?
    var section: String?
    var id: Int { hunk.id }
}

/// State the window shows. The `Document` owns it and registers each change for undo.
/// Used only on the main thread (the `Document` guarantees this at the points AppKit calls from elsewhere).
@Observable
final class WindowModel {
    private(set) var session = EditSession([])
    var format: Format { session.format }
    private(set) var sections: [FormSection] = []
    var selection: String?
    private(set) var mode: Mode = .form
    var showChanges = true
    private(set) var hunks: [LabeledHunk] = []
    private(set) var saveError: String?
    /// Ids (path as text) of the fields whose value differs from the disk.
    private(set) var changed: Set<String> = []
    var canUndo = false
    var fileName = NSLocalizedString("untitled", comment: "Window/file name of a document without a file")

    // Text mode
    var draft = "" { didSet { validateDraft() } }
    private(set) var draftError: ParseError?
    /// The draft is valid, but uses something outside the form's subset (YAML with anchors…):
    /// it can be applied and saved, but only as text.
    private(set) var draftWarning: ParseError?
    /// Format name of the valid draft ("TOML", "JSON", "JSONC", ".env", "INI").
    private(set) var draftFormat = "TOML"
    private(set) var draftDiffers = false
    var applyError: String?

    @ObservationIgnored weak var document: Document?
    @ObservationIgnored private var diskRead: (bytes: [UInt8], doc: ConfDocument?)?

    /// A `.json` file (not `.jsonc`) with comments or trailing commas: subtle notice in the window.
    var jsoncNotice: Bool {
        format == .json && session.document?.usesJSONCExtensions == true
            && !fileName.lowercased().hasSuffix(".jsonc")
    }

    /// Comment at the beginning of the file that is not help for any field (see `Fields.preambleComment`).
    private(set) var preambleComment: String?
    /// Selection of the "About the file" page in the sidebar (doesn't collide with a section id).
    static let preambleID = "\u{1}preamble"

    var selectedSection: FormSection? { sections.first { $0.id == selection } ?? sections.first }

    // MARK: Load and recompute

    func load(_ bytes: [UInt8], format: Format) {
        session = EditSession(bytes, format: format)
        if session.document == nil {
            mode = .text
        }
        recompute()
        if mode == .text { enterTextMode() }
    }

    func saved(_ bytes: [UInt8]) {
        session.saved(bytes)
        recompute()
        if mode == .text && !draftDiffers { enterTextMode() }
    }

    /// Modifies the edit session directly (the `Document` takes care of undo).
    func modifySession(_ f: (inout EditSession) throws -> Void) rethrows {
        try f(&session)
        recompute()
    }

    func recompute() {
        if let doc = session.document { sections = Fields.sections(doc) } else { sections = [] }
        preambleComment = session.document.flatMap(Fields.preambleComment)
        let preamble = selection == Self.preambleID && preambleComment != nil
        if selection == nil || (!preamble && !sections.contains(where: { $0.id == selection })) {
            selection = sections.first?.id ?? (preambleComment != nil ? Self.preambleID : nil)
        }

        if diskRead?.bytes != session.disk {
            diskRead = (session.disk, try? format.parse(session.disk))
        }
        let disk = diskRead?.doc
        var changedIDs: Set<String> = []
        if let doc = session.document {
            for e in doc.entries where session.value(e.path) != disk?.rootValue.value(at: e.path) {
                changedIDs.insert(e.path.text)
            }
        }
        changed = changedIDs

        do {
            let r = try session.result()
            saveError = nil
            let updated = r == session.base ? session.document : (try? format.parse(r))
            hunks = Diff.lines(session.disk, r).map { t in
                var labeled = LabeledHunk(hunk: t)
                let line = t.added.isEmpty ? t.lineBefore : t.lineAfter
                let doc = t.added.isEmpty ? disk : updated
                if let e = doc?.entries.first(where: { $0.line <= line && line <= $0.lastLine }) {
                    labeled.label = e.path.text
                    labeled.section = e.section.flatMap { doc?.headers[$0].path.text } ?? FormSection.rootID
                }
                return labeled
            }
        } catch {
            saveError = error.localizedDescription
            hunks = []
        }
    }

    func section(ofField id: String) -> String? {
        sections.first { $0.fields.contains { $0.id == id } }?.id
    }

    // MARK: Values for the screen

    func value(_ c: Field) -> Value { session.value(c.path) ?? c.value }

    func rawText(_ c: Field) -> String {
        switch session.changes[c.path] {
        case .raw(let s)?: return s
        case .value(let v)?: return format.write(v)
        case nil: return c.originalText
        }
    }

    func assign(_ c: Field, _ updated: NewValue) {
        document?.assign(c.path, updated, label: c.label)
    }

    func undo() { document?.undoManager?.undo() }

    /// Replaces the preamble comment, keeping values changed in the form and not yet saved.
    func setPreamble(_ updated: String) {
        let current = (try? session.result()) ?? session.base
        guard let bytes = Preamble.replace(current, format: format, by: updated), bytes != current else { return }
        document?.applyText(bytes, name: NSLocalizedString("Edit Comment", comment: "Undo action name"))
    }

    // MARK: Text mode

    func enterTextMode() {
        let bytes = (try? session.result()) ?? session.base
        draft = String(decoding: bytes, as: UTF8.self)
        applyError = nil
    }

    func validateDraft() {
        let bytes = Array(draft.utf8)
        let current = (try? session.result()) ?? session.base
        draftDiffers = bytes != current
        draftWarning = nil
        do {
            draftFormat = try format.parse(bytes).formatName
            draftError = nil
        } catch where error.outsideSubset {
            draftFormat = format.name
            draftError = nil
            draftWarning = error
        } catch {
            draftError = error
        }
    }

    /// Applies the text if it is valid in the format. Returns `false` if there is an error.
    @discardableResult
    func applyDraft() -> Bool {
        validateDraft()
        guard draftDiffers else { return true }
        guard draftError == nil, let d = document else { NSSound.beep(); return false }
        d.applyText(Array(draft.utf8))
        validateDraft()
        return true
    }

    func switchMode(_ updated: Mode) {
        guard updated != mode else { return }
        switch updated {
        case .text:
            enterTextMode()
            mode = .text
        case .form:
            guard applyDraft(), session.document != nil else { NSSound.beep(); return }
            mode = .form
        }
    }
}

/// An open `.toml`, `.json`, `.jsonc`, `.json5`, `.env` or `.ini` file. AppKit takes care of ⌘S, Revert, the
/// external-change warning and reloading.
@objc(Document)
final class Document: NSDocument {
    let model = WindowModel()
    /// Last bytes prepared for saving, captured on the main thread.
    /// AppKit may call `data(ofType:)` on another thread and with queued saves.
    private let stateLock = NSLock()
    private var _bytesBeingSaved: [UInt8]?
    private var bytesBeingSaved: [UInt8]? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _bytesBeingSaved }
        set { stateLock.lock(); _bytesBeingSaved = newValue; stateLock.unlock() }
    }

    override init() {
        super.init()
        hasUndoManager = true
        model.document = self
        if let um = undoManager {
            for n: Notification.Name in [.NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange,
                                         .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoChanged), name: n, object: um)
            }
        }
    }

    @objc private func undoChanged(_ n: Notification) {
        model.canUndo = undoManager?.canUndo ?? false
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let host = NSHostingController(rootView: WindowView(model: model))
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1060, height: 660))
        window.minSize = NSSize(width: 640, height: 400)
        let wc = NSWindowController(window: window)
        wc.shouldCascadeWindows = true
        addWindowController(wc)
        window.setFrameAutosaveName("konfig.janela")
        if fileURL == nil { window.center() }
    }

    // MARK: Reading and writing

    /// AppKit sometimes calls reading and writing off the main thread (autosave);
    /// the window model is only touched on the main thread.
    private func onMain<T>(_ f: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try f() }
        return try DispatchQueue.main.sync { try f() }
    }

    /// Format from the file name (extension and `.env` names); without it, from the type
    /// macOS gave the file. The type alone isn't enough: for a file named
    /// `.env` the system returns `public.data` and an empty `pathExtension`.
    private var formatRead: Format?

    override func read(from url: URL, ofType typeName: String) throws {
        formatRead = Format(fileName: url.lastPathComponent)
        try super.read(from: url, ofType: typeName)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let bytes = [UInt8](data)
        let format = formatRead ?? fileURL.flatMap { Format(fileName: $0.lastPathComponent) }
            ?? Format(kind: typeName)
        onMain {
            model.load(bytes, format: format)
            model.fileName = fileURL?.lastPathComponent ?? NSLocalizedString("untitled", comment: "Window/file name of a document without a file")
            undoManager?.removeAllActions()
        }
    }

    /// `.env`, `.editorconfig` and `.yaml`/`.yml` files keep their name: without this ⌘S would save `.env` as `.env.env`,
    /// `.env.local` as `.env.local.env` and `.editorconfig` as `.editorconfig.ini`
    /// (`NSDocument` appends the type's extension).
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        let f = Format(kind: typeName)
        if f == .env || f == .ini || f == .yaml, let url = fileURL, Format(fileName: url.lastPathComponent) == f {
            return url.pathExtension.isEmpty ? nil : url.pathExtension
        }
        return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    override func data(ofType typeName: String) throws -> Data {
        // Bytes captured on the main thread in `save(to:…)`.
        if let b = bytesBeingSaved { return Data(b) }
        return Data(try onMain { try model.session.result() })
    }

    override func writeSafely(to url: URL, ofType typeName: String, for op: NSDocument.SaveOperationType) throws {
        // Copy of the file as it was on disk before overwriting: <file>.toml.bak, <file>.json.bak, .env.bak
        if op != .autosaveElsewhereOperation, FileManager.default.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: bak)
            try FileManager.default.copyItem(at: url, to: bak)
        }
        try super.writeSafely(to: url, ofType: typeName, for: op)
    }

    override func save(to url: URL, ofType typeName: String, for op: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // Text being edited in Text mode: saved along if valid.
        if model.mode == .text && model.draftDiffers {
            if model.draftError == nil {
                model.applyDraft()
            } else if op == .saveOperation || op == .saveAsOperation {
                let e = model.draftError!
                completionHandler(SaveError(String(format: NSLocalizedString("The text has an error on line %ld, column %ld: %@. Fix or discard it before saving.", comment: "Save error; %ld = line, %ld = column, %@ = parse error message"), e.line, e.column, e.message)))
                return
            }
        }
        // The result is computed here, on the main thread; if it isn't valid, nothing is written.
        let bytes: [UInt8]
        do { bytes = try model.session.result() } catch {
            completionHandler(error)
            return
        }
        bytesBeingSaved = bytes
        super.save(to: url, ofType: typeName, for: op) { [weak self] error in
            let finish = {
                guard let self else { return completionHandler(error) }
                if error == nil, op == .saveOperation || op == .saveAsOperation || op == .autosaveInPlaceOperation {
                    self.model.saved(bytes)
                    self.model.fileName = url.lastPathComponent
                }
                completionHandler(error)
            }
            if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
        }
    }

    /// Another program wrote to the file. Without pending edits, reload right away — on its own
    /// `NSDocument` only checks when the app becomes active again. With pending edits,
    /// leave it as is: on save, `NSDocument` itself warns about the conflict.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDocumentEdited, let url = self.fileURL, let kind = self.fileType,
                  let disk = try? Data(contentsOf: url), [UInt8](disk) != self.model.session.disk else { return }
            try? self.revert(toContentsOf: url, ofType: kind)
        }
    }

    // MARK: Changes with undo

    func assign(_ c: ValuePath, _ updated: NewValue, label: String) {
        guard let previous = model.session.effective(c) else { NSSound.beep(); return }
        do {
            try model.modifySession { try $0.assign(c, updated) }
        } catch {
            presentError(error)
            return
        }
        guard model.session.effective(c) != previous else { return }
        undoManager?.registerUndo(withTarget: self) { d in
            d.assign(c, previous, label: label)
        }
        undoManager?.setActionName(String(format: NSLocalizedString("Change %@", comment: "Undo action name; %@ = key"), label))
    }

    func applyText(_ bytes: [UInt8], name: String = NSLocalizedString("Edit Text", comment: "Undo action name")) {
        let before = model.session.snapshot
        do {
            try model.modifySession { try $0.replaceText(bytes) }
        } catch {
            presentError(error)
            return
        }
        registerRestore(before, name: name)
    }

    private func restore(_ snap: EditSession.Snapshot, name: String) {
        let current = model.session.snapshot
        model.modifySession { $0.restore(snap) }
        if model.mode == .text { model.enterTextMode() }
        registerRestore(current, name: name)
    }

    private func registerRestore(_ snap: EditSession.Snapshot, name: String) {
        undoManager?.registerUndo(withTarget: self) { d in
            d.restore(snap, name: name)
        }
        undoManager?.setActionName(name)
    }

    // MARK: View menu

    @objc func showForm(_ sender: Any?) { model.switchMode(.form) }
    @objc func showText(_ sender: Any?) { model.switchMode(.text) }
    @objc func toggleChanges(_ sender: Any?) { model.showChanges.toggle() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let m = item as? NSMenuItem {
            switch item.action {
            case #selector(showForm(_:)):
                m.state = model.mode == .form ? .on : .off
                return model.session.document != nil || model.mode == .text
            case #selector(showText(_:)):
                m.state = model.mode == .text ? .on : .off
                return true
            case #selector(toggleChanges(_:)):
                m.title = model.showChanges ? NSLocalizedString("Hide Changes", comment: "Menu item (View); toggles the changes panel") : NSLocalizedString("Show Changes", comment: "Menu item (View); toggles the changes panel")
                return true
            default: break
            }
        }
        return super.validateUserInterfaceItem(item)
    }
}
