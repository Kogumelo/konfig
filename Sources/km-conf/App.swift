import AppKit

/// Ponto de entrada: app de documentos AppKit, menu montado em código (sem nib).
@main
@MainActor
enum App {
    static let delegado = Delegado()

    static func main() {
        // O primeiro NSDocumentController criado vira o `shared`.
        _ = ControladorDocumentos()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegado
        app.mainMenu = Menu.principal()
        app.run()
    }
}

/// Decide o tipo do arquivo pela extensão. O macOS não declara `.jsonc` (dá a ele um tipo
/// "dinâmico"), e a declaração do `Info.plist` só vale depois que o app é registrado.
final class ControladorDocumentos: NSDocumentController {
    override func typeForContents(of url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "toml": return "public.toml"
        case "json": return "public.json"
        case "jsonc": return "br.com.kogut.km-conf.jsonc"
        default: return try super.typeForContents(of: url)
        }
    }
}

@MainActor
final class Delegado: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        // Caminhos passados na linha de comando (`open km-conf.app --args arquivo.toml`)
        // o próprio AppKit abre como documentos.
        if let v = ProcessInfo.processInfo.environment["KM_CONF_AUTOTESTE"] {
            let partes = v.split(separator: "|").map(String.init)
            if partes.count == 2 {
                Autoteste.rodar(arquivo: URL(fileURLWithPath: partes[0]), saida: URL(fileURLWithPath: partes[1]))
                return
            }
        }
        // Aberto sem arquivo: mostra o painel de abrir.
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
    static func item(_ titulo: String, _ acao: Selector?, _ tecla: String = "",
                     _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: titulo, action: acao, keyEquivalent: tecla)
        i.keyEquivalentModifierMask = mods
        return i
    }

    static func submenu(_ titulo: String, _ itens: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenu(title: titulo)
        itens.forEach(m.addItem)
        let i = NSMenuItem(title: titulo, action: nil, keyEquivalent: "")
        i.submenu = m
        return i
    }

    static func principal() -> NSMenu {
        let principal = NSMenu()
        let nome = "km-conf"

        principal.addItem(submenu(nome, [
            item("Sobre o \(nome)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Ocultar \(nome)", #selector(NSApplication.hide(_:)), "h"),
            item("Ocultar Outros", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Mostrar Tudo", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Encerrar \(nome)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        let recentes = submenu("Abrir Recente", [
            item("Limpar Menu", #selector(NSDocumentController.clearRecentDocuments(_:))),
        ])
        principal.addItem(submenu("Arquivo", [
            item("Novo", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Abrir…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recentes,
            .separator(),
            item("Fechar", #selector(NSWindow.performClose(_:)), "w"),
            item("Salvar", #selector(NSDocument.save(_:)), "s"),
            item("Duplicar", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]),
            item("Renomear…", #selector(NSDocument.rename(_:))),
            item("Mover Para…", #selector(NSDocument.move(_:))),
            item("Reverter Para", #selector(NSDocument.revertToSaved(_:))),
        ]))

        principal.addItem(submenu("Editar", [
            item("Desfazer", Selector(("undo:")), "z"),
            item("Refazer", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Recortar", #selector(NSText.cut(_:)), "x"),
            item("Copiar", #selector(NSText.copy(_:)), "c"),
            item("Colar", #selector(NSText.paste(_:)), "v"),
            item("Selecionar Tudo", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            submenu("Buscar", [
                {
                    let i = item("Buscar…", #selector(NSTextView.performFindPanelAction(_:)), "f")
                    i.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                    return i
                }(),
                {
                    let i = item("Buscar Próximo", #selector(NSTextView.performFindPanelAction(_:)), "g")
                    i.tag = Int(NSFindPanelAction.next.rawValue)
                    return i
                }(),
            ]),
        ]))

        principal.addItem(submenu("Visualizar", [
            item("Formulário", #selector(Documento.mostrarFormulario(_:)), "1"),
            item("Texto", #selector(Documento.mostrarTexto(_:)), "2"),
            .separator(),
            item("Mostrar Barra Lateral", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Ocultar alterações", #selector(Documento.alternarAlteracoes(_:)), "i", [.command, .option]),
        ]))

        let janela = submenu("Janela", [
            item("Minimizar", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Trazer Todas para a Frente", #selector(NSApplication.arrangeInFront(_:))),
        ])
        principal.addItem(janela)
        NSApp.windowsMenu = janela.submenu
        return principal
    }
}
