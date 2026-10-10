import AppKit
import Observation
import SwiftUI
import ConfCore

enum Modo: String {
    case formulario, texto
}

/// Trecho do painel de alterações, com o nome da chave quando dá para saber.
struct TrechoRotulado: Identifiable {
    var trecho: Trecho
    var rotulo: String?
    var secao: String?
    var id: Int { trecho.id }
}

/// Estado que a janela mostra. O `Documento` é dono dele e registra cada alteração no desfazer.
/// Usado só na thread principal (o `Documento` garante isso nos pontos que o AppKit chama de fora).
@Observable
final class ModeloJanela {
    private(set) var edicao = Edicao([])
    var formato: Formato { edicao.formato }
    private(set) var secoes: [Secao] = []
    var selecao: String?
    private(set) var modo: Modo = .formulario
    var mostrarAlteracoes = true
    private(set) var trechos: [TrechoRotulado] = []
    private(set) var erroGravacao: String?
    /// Ids (caminho em texto) dos campos cujo valor difere do disco.
    private(set) var alterados: Set<String> = []
    var podeDesfazer = false
    var nomeArquivo = "sem título"

    // modo Texto
    var rascunho = "" { didSet { validarRascunho() } }
    private(set) var erroRascunho: ErroLeitura?
    /// Nome do formato do rascunho válido ("TOML", "JSON", "JSONC", ".env").
    private(set) var formatoRascunho = "TOML"
    private(set) var rascunhoDifere = false
    var erroAoAplicar: String?

    @ObservationIgnored weak var documento: Documento?
    @ObservationIgnored private var discoLido: (bytes: [UInt8], doc: DocumentoConf?)?

    /// Arquivo `.json` (não `.jsonc`) com comentário ou vírgula final: aviso discreto na janela.
    var avisoJSONC: Bool {
        formato == .json && edicao.documento?.usaExtensoesJSONC == true
            && !nomeArquivo.lowercased().hasSuffix(".jsonc")
    }

    var secaoSelecionada: Secao? { secoes.first { $0.id == selecao } ?? secoes.first }

    // MARK: Carregar e recalcular

    func carregar(_ bytes: [UInt8], formato: Formato) {
        edicao = Edicao(bytes, formato: formato)
        if edicao.documento == nil {
            modo = .texto
        }
        recalcular()
        if modo == .texto { entrarModoTexto() }
    }

    func gravado(_ bytes: [UInt8]) {
        edicao.gravado(bytes)
        recalcular()
        if modo == .texto && !rascunhoDifere { entrarModoTexto() }
    }

    /// Mexe direto na edição (o `Documento` cuida do desfazer).
    func alterarEdicao(_ f: (inout Edicao) throws -> Void) rethrows {
        try f(&edicao)
        recalcular()
    }

    func recalcular() {
        if let doc = edicao.documento { secoes = Campos.secoes(doc) } else { secoes = [] }
        if selecao == nil || !secoes.contains(where: { $0.id == selecao }) { selecao = secoes.first?.id }

        if discoLido?.bytes != edicao.disco {
            discoLido = (edicao.disco, try? formato.ler(edicao.disco))
        }
        let disco = discoLido?.doc
        var alt: Set<String> = []
        if let doc = edicao.documento {
            for e in doc.entradas where edicao.valor(e.caminho) != disco?.valorRaiz.valor(em: e.caminho) {
                alt.insert(e.caminho.texto)
            }
        }
        alterados = alt

        do {
            let r = try edicao.resultado()
            erroGravacao = nil
            let novo = r == edicao.base ? edicao.documento : (try? formato.ler(r))
            trechos = Diferenca.linhas(edicao.disco, r).map { t in
                var tr = TrechoRotulado(trecho: t)
                let linha = t.adicionadas.isEmpty ? t.linhaAntes : t.linhaDepois
                let doc = t.adicionadas.isEmpty ? disco : novo
                if let e = doc?.entradas.first(where: { $0.linha <= linha && linha <= $0.linhaFinal }) {
                    tr.rotulo = e.caminho.texto
                    tr.secao = e.secao.flatMap { doc?.cabecalhos[$0].caminho.texto } ?? "raiz"
                }
                return tr
            }
        } catch {
            erroGravacao = error.localizedDescription
            trechos = []
        }
    }

    func secao(doCampo id: String) -> String? {
        secoes.first { $0.campos.contains { $0.id == id } }?.id
    }

    // MARK: Valores para a tela

    func valor(_ c: Campo) -> Valor { edicao.valor(c.caminho) ?? c.valor }

    func textoCru(_ c: Campo) -> String {
        switch edicao.alteracoes[c.caminho] {
        case .cru(let s)?: return s
        case .valor(let v)?: return formato.escrever(v)
        case nil: return c.textoOriginal
        }
    }

    func definir(_ c: Campo, _ novo: NovoValor) {
        documento?.definir(c.caminho, novo, rotulo: c.rotulo)
    }

    func desfazer() { documento?.undoManager?.undo() }

    // MARK: Modo Texto

    func entrarModoTexto() {
        let bytes = (try? edicao.resultado()) ?? edicao.base
        rascunho = String(decoding: bytes, as: UTF8.self)
        erroAoAplicar = nil
    }

    func validarRascunho() {
        let bytes = Array(rascunho.utf8)
        let atual = (try? edicao.resultado()) ?? edicao.base
        rascunhoDifere = bytes != atual
        do {
            formatoRascunho = try formato.ler(bytes).nomeFormato
            erroRascunho = nil
        } catch {
            erroRascunho = error
        }
    }

    /// Aplica o texto se for válido no formato. Devolve `false` se houver erro.
    @discardableResult
    func aplicarRascunho() -> Bool {
        validarRascunho()
        guard rascunhoDifere else { return true }
        guard erroRascunho == nil, let d = documento else { NSSound.beep(); return false }
        d.aplicarTexto(Array(rascunho.utf8))
        validarRascunho()
        return true
    }

    func trocarModo(_ novo: Modo) {
        guard novo != modo else { return }
        switch novo {
        case .texto:
            entrarModoTexto()
            modo = .texto
        case .formulario:
            guard aplicarRascunho(), edicao.documento != nil else { NSSound.beep(); return }
            modo = .formulario
        }
    }
}

/// Um arquivo `.toml`, `.json`, `.jsonc`, `.json5` ou `.env` aberto. AppKit cuida de ⌘S, Reverter, aviso de
/// alteração externa e recarga.
@objc(Documento)
final class Documento: NSDocument {
    let modelo = ModeloJanela()
    /// Últimos bytes preparados para gravar, capturados na thread principal.
    /// O AppKit pode chamar `data(ofType:)` em outra thread e com salvamentos em fila.
    private let trava = NSLock()
    private var _bytesGravando: [UInt8]?
    private var bytesGravando: [UInt8]? {
        get { trava.lock(); defer { trava.unlock() }; return _bytesGravando }
        set { trava.lock(); _bytesGravando = newValue; trava.unlock() }
    }

    override init() {
        super.init()
        hasUndoManager = true
        modelo.documento = self
        if let um = undoManager {
            for n: Notification.Name in [.NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange,
                                         .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoMudou), name: n, object: um)
            }
        }
    }

    @objc private func undoMudou(_ n: Notification) {
        modelo.podeDesfazer = undoManager?.canUndo ?? false
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let host = NSHostingController(rootView: Janela(modelo: modelo))
        host.sceneBridgingOptions = [.toolbars]
        let janela = NSWindow(contentViewController: host)
        janela.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        janela.toolbarStyle = .unified
        janela.setContentSize(NSSize(width: 1060, height: 660))
        janela.minSize = NSSize(width: 640, height: 400)
        let wc = NSWindowController(window: janela)
        wc.shouldCascadeWindows = true
        addWindowController(wc)
        janela.setFrameAutosaveName("km-conf.janela")
        if fileURL == nil { janela.center() }
    }

    // MARK: Leitura e gravação

    /// O AppKit chama leitura e gravação às vezes fora da thread principal (salvamento
    /// automático); o modelo da janela só é tocado na principal.
    private func naPrincipal<T>(_ f: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try f() }
        return try DispatchQueue.main.sync { try f() }
    }

    /// Formato pelo nome do arquivo (extensão e nomes de `.env`); sem ele, pelo tipo
    /// que o macOS deu ao arquivo. O tipo sozinho não basta: para um arquivo chamado
    /// `.env` o sistema devolve `public.data` e `pathExtension` vazio.
    private var formatoLido: Formato?

    override func read(from url: URL, ofType typeName: String) throws {
        formatoLido = Formato(nomeArquivo: url.lastPathComponent)
        try super.read(from: url, ofType: typeName)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let bytes = [UInt8](data)
        let formato = formatoLido ?? fileURL.flatMap { Formato(nomeArquivo: $0.lastPathComponent) }
            ?? Formato(tipo: typeName)
        naPrincipal {
            modelo.carregar(bytes, formato: formato)
            modelo.nomeArquivo = fileURL?.lastPathComponent ?? "sem título"
            undoManager?.removeAllActions()
        }
    }

    /// Arquivos `.env` mantêm o nome: sem isto o ⌘S gravaria `.env` como `.env.env`
    /// e `.env.local` como `.env.local.env` (o `NSDocument` acrescenta a extensão do tipo).
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        if Formato(tipo: typeName) == .env, let url = fileURL, Formato(nomeArquivo: url.lastPathComponent) == .env {
            return url.pathExtension.isEmpty ? nil : url.pathExtension
        }
        return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    override func data(ofType typeName: String) throws -> Data {
        // Bytes capturados na thread principal em `save(to:…)`.
        if let b = bytesGravando { return Data(b) }
        return Data(try naPrincipal { try modelo.edicao.resultado() })
    }

    override func writeSafely(to url: URL, ofType typeName: String, for op: NSDocument.SaveOperationType) throws {
        // Cópia do arquivo como estava no disco antes de sobrescrever: <arquivo>.toml.bak, <arquivo>.json.bak, .env.bak
        if op != .autosaveElsewhereOperation, FileManager.default.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: bak)
            try FileManager.default.copyItem(at: url, to: bak)
        }
        try super.writeSafely(to: url, ofType: typeName, for: op)
    }

    override func save(to url: URL, ofType typeName: String, for op: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // Texto em edição no modo Texto: grava junto se for válido.
        if modelo.modo == .texto && modelo.rascunhoDifere {
            if modelo.erroRascunho == nil {
                modelo.aplicarRascunho()
            } else if op == .saveOperation || op == .saveAsOperation {
                let e = modelo.erroRascunho!
                completionHandler(ErroGravar("O texto tem um erro na linha \(e.linha), coluna \(e.coluna): \(e.mensagem). Corrija ou descarte antes de salvar."))
                return
            }
        }
        // O resultado é calculado aqui, na thread principal; se não for válido, nada é gravado.
        let bytes: [UInt8]
        do { bytes = try modelo.edicao.resultado() } catch {
            completionHandler(error)
            return
        }
        bytesGravando = bytes
        super.save(to: url, ofType: typeName, for: op) { [weak self] erro in
            let concluir = {
                guard let self else { return completionHandler(erro) }
                if erro == nil, op == .saveOperation || op == .saveAsOperation || op == .autosaveInPlaceOperation {
                    self.modelo.gravado(bytes)
                    self.modelo.nomeArquivo = url.lastPathComponent
                }
                completionHandler(erro)
            }
            if Thread.isMainThread { concluir() } else { DispatchQueue.main.async(execute: concluir) }
        }
    }

    /// Outro programa gravou no arquivo. Sem edição pendente, recarrega na hora — o
    /// `NSDocument` sozinho só confere quando o app volta a ficar ativo. Com edição
    /// pendente, fica como está: ao salvar, o próprio `NSDocument` avisa do conflito.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDocumentEdited, let url = self.fileURL, let tipo = self.fileType,
                  let disco = try? Data(contentsOf: url), [UInt8](disco) != self.modelo.edicao.disco else { return }
            try? self.revert(toContentsOf: url, ofType: tipo)
        }
    }

    // MARK: Alterações com desfazer

    func definir(_ c: Caminho, _ novo: NovoValor, rotulo: String) {
        guard let anterior = modelo.edicao.efetivo(c) else { NSSound.beep(); return }
        do {
            try modelo.alterarEdicao { try $0.definir(c, novo) }
        } catch {
            presentError(error)
            return
        }
        guard modelo.edicao.efetivo(c) != anterior else { return }
        undoManager?.registerUndo(withTarget: self) { d in
            d.definir(c, anterior, rotulo: rotulo)
        }
        undoManager?.setActionName("Alterar \(rotulo)")
    }

    func aplicarTexto(_ bytes: [UInt8]) {
        let antes = modelo.edicao.instantaneo
        do {
            try modelo.alterarEdicao { try $0.trocarTexto(bytes) }
        } catch {
            presentError(error)
            return
        }
        registrarRestauracao(antes, nome: "Editar texto")
    }

    private func restaurar(_ i: Edicao.Instantaneo, nome: String) {
        let atual = modelo.edicao.instantaneo
        modelo.alterarEdicao { $0.restaurar(i) }
        if modelo.modo == .texto { modelo.entrarModoTexto() }
        registrarRestauracao(atual, nome: nome)
    }

    private func registrarRestauracao(_ i: Edicao.Instantaneo, nome: String) {
        undoManager?.registerUndo(withTarget: self) { d in
            d.restaurar(i, nome: nome)
        }
        undoManager?.setActionName(nome)
    }

    // MARK: Menu Visualizar

    @objc func mostrarFormulario(_ sender: Any?) { modelo.trocarModo(.formulario) }
    @objc func mostrarTexto(_ sender: Any?) { modelo.trocarModo(.texto) }
    @objc func alternarAlteracoes(_ sender: Any?) { modelo.mostrarAlteracoes.toggle() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let m = item as? NSMenuItem {
            switch item.action {
            case #selector(mostrarFormulario(_:)):
                m.state = modelo.modo == .formulario ? .on : .off
                return modelo.edicao.documento != nil || modelo.modo == .texto
            case #selector(mostrarTexto(_:)):
                m.state = modelo.modo == .texto ? .on : .off
                return true
            case #selector(alternarAlteracoes(_:)):
                m.title = modelo.mostrarAlteracoes ? "Ocultar alterações" : "Mostrar alterações"
                return true
            default: break
            }
        }
        return super.validateUserInterfaceItem(item)
    }
}
