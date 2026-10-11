import AppKit
import ConfCore

/// Entry point: AppKit document app, menu built in code (no nib).
@main
@MainActor
enum App {
    static let delegate = AppDelegate()

    static func main() {
        Migration.preferencesFromOldName()
        // The first NSDocumentController created becomes `shared`.
        _ = DocumentController()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.mainMenu = Menu.mainMenu()
        app.run()
    }
}

/// Until 2026-10-11 the app was called km-conf, with bundle id `br.com.kogut.km-conf`.
/// Preferences are stored by bundle id; on the first launch with the new id, copy the ones
/// from the old one (window position and size, last folder of the open panel…). The old domain
/// is left as is. Recent documents and Finder's "Open With" don't carry over: the system
/// stores them by bundle id, outside the preferences.
enum Migration {
    static let oldID = "br.com.kogut.km-conf"
    static let oldWindow = "NSWindow Frame km-conf.janela"
    static let newWindow = "NSWindow Frame konfig.janela"

    static func preferencesFromOldName() {
        let defaults = UserDefaults.standard
        let mark = "migrouDoNomeAntigo"
        guard !defaults.bool(forKey: mark) else { return }
        defer { defaults.set(true, forKey: mark) }
        guard let oldPrefs = defaults.persistentDomain(forName: oldID) else { return }
        for (key, value) in oldPrefs {
            let newKey = key == oldWindow ? newWindow : key
            if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
        }
    }
}

/// Decides the file's type by its name. macOS doesn't declare `.jsonc`, `.json5`, `.env` or `.ini` (it gives them
/// a "dynamic" type, and a file named just `.env` gets `public.data`), and the `Info.plist`
/// declaration only takes effect after the app is registered.
final class DocumentController: NSDocumentController {
    override func typeForContents(of url: URL) throws -> String {
        if url.pathExtension.lowercased() == "jsonc" { return "br.com.kogut.konfig.jsonc" }
        switch Format(fileName: url.lastPathComponent) {
        case .toml?: return "public.toml"
        case .json?: return "public.json"
        case .json5?: return "br.com.kogut.konfig.json5"
        case .env?: return "br.com.kogut.konfig.env"
        case .ini?: return "br.com.kogut.konfig.ini"
        case .yaml?: return "public.yaml"
        case nil: return try super.typeForContents(of: url)
        }
    }

    /// The open panel accepts any file: `.env` and `.env.local` have no type
    /// the panel recognizes. `typeForContents` decides whether it can be opened.
    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
    }
}

extension Format {
    /// Format from the `Info.plist` document type (last resort, without a file name).
    init(kind: String) {
        let t = kind.lowercased()
        if t.contains("json5") { self = .json5 } else if t.contains("json") { self = .json } else if t.hasSuffix(".env") { self = .env } else if t.hasSuffix(".ini") { self = .ini } else if t.contains("yaml") { self = .yaml } else { self = .toml }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        // Paths passed on the command line (`open Konfig.app --args file.toml`)
        // are opened as documents by AppKit itself.
        if let v = ProcessInfo.processInfo.environment["KONFIG_SELFTEST"] {
            let parts = v.split(separator: "|").map(String.init)
            if parts.count == 2 {
                SelfTest.run(file: URL(fileURLWithPath: parts[0]), output: URL(fileURLWithPath: parts[1]))
                return
            }
        }
        // Launched without a file: show the open panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NSDocumentController.shared.openDocument(nil) }
        return false
    }
}

@MainActor
enum Menu {
    static func item(_ title: String, _ action: Selector?, _ keyEq: String = "",
                     _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: keyEq)
        i.keyEquivalentModifierMask = mods
        return i
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = m
        return i
    }

    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let name = "Konfig"

        main.addItem(submenu(name, [
            item(String(format: NSLocalizedString("About %@", comment: "Menu item; %@ = app name"), name), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(String(format: NSLocalizedString("Hide %@", comment: "Menu item; %@ = app name"), name), #selector(NSApplication.hide(_:)), "h"),
            item(NSLocalizedString("Hide Others", comment: "Menu item"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(NSLocalizedString("Show All", comment: "Menu item"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(format: NSLocalizedString("Quit %@", comment: "Menu item; %@ = app name"), name), #selector(NSApplication.terminate(_:)), "q"),
        ]))

        let recents = submenu(NSLocalizedString("Open Recent", comment: "Menu item"), [
            item(NSLocalizedString("Clear Menu", comment: "Menu item"), #selector(NSDocumentController.clearRecentDocuments(_:))),
        ])
        main.addItem(submenu(NSLocalizedString("File", comment: "Menu title"), [
            item(NSLocalizedString("New", comment: "Menu item"), #selector(NSDocumentController.newDocument(_:)), "n"),
            item(NSLocalizedString("Open…", comment: "Menu item"), #selector(NSDocumentController.openDocument(_:)), "o"),
            recents,
            .separator(),
            item(NSLocalizedString("Close", comment: "Menu item"), #selector(NSWindow.performClose(_:)), "w"),
            item(NSLocalizedString("Save", comment: "Menu item"), #selector(NSDocument.save(_:)), "s"),
            item(NSLocalizedString("Duplicate", comment: "Menu item"), #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]),
            item(NSLocalizedString("Rename…", comment: "Menu item"), #selector(NSDocument.rename(_:))),
            item(NSLocalizedString("Move To…", comment: "Menu item"), #selector(NSDocument.move(_:))),
            item(NSLocalizedString("Revert To", comment: "Menu item"), #selector(NSDocument.revertToSaved(_:))),
        ]))

        main.addItem(submenu(NSLocalizedString("Edit", comment: "Menu title"), [
            item(NSLocalizedString("Undo", comment: "Menu item"), Selector(("undo:")), "z"),
            item(NSLocalizedString("Redo", comment: "Menu item"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(NSLocalizedString("Cut", comment: "Menu item"), #selector(NSText.cut(_:)), "x"),
            item(NSLocalizedString("Copy", comment: "Menu item"), #selector(NSText.copy(_:)), "c"),
            item(NSLocalizedString("Paste", comment: "Menu item"), #selector(NSText.paste(_:)), "v"),
            item(NSLocalizedString("Select All", comment: "Menu item"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            submenu(NSLocalizedString("Find", comment: "Menu title (submenu of Edit)"), [
                {
                    let i = item(NSLocalizedString("Find…", comment: "Menu item"), #selector(NSTextView.performFindPanelAction(_:)), "f")
                    i.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                    return i
                }(),
                {
                    let i = item(NSLocalizedString("Find Next", comment: "Menu item"), #selector(NSTextView.performFindPanelAction(_:)), "g")
                    i.tag = Int(NSFindPanelAction.next.rawValue)
                    return i
                }(),
            ]),
        ]))

        main.addItem(submenu(NSLocalizedString("View", comment: "Menu title"), [
            item(NSLocalizedString("Form", comment: "Menu item (View); Form mode"), #selector(Document.showForm(_:)), "1"),
            item(NSLocalizedString("Text", comment: "Menu item (View); Text mode"), #selector(Document.showText(_:)), "2"),
            .separator(),
            item(NSLocalizedString("Show Sidebar", comment: "Menu item"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item(NSLocalizedString("Hide Changes", comment: "Menu item (View); toggles the changes panel"), #selector(Document.toggleChanges(_:)), "i", [.command, .option]),
        ]))

        let window = submenu(NSLocalizedString("Window", comment: "Menu title"), [
            item(NSLocalizedString("Minimize", comment: "Menu item"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(NSLocalizedString("Zoom", comment: "Menu item"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(NSLocalizedString("Bring All to Front", comment: "Menu item"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }
}
