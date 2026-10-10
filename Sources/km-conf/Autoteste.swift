import AppKit
import ConfCore

/// `KM_CONF_AUTOTESTE="<arquivo>|<pasta-de-saída>" km-conf.app/Contents/MacOS/km-conf`
///
/// O arquivo é uma cópia de `exemplos/config.toml` ou `exemplos/config.jsonc` (o
/// roteiro de cada formato conta com os campos desses exemplos).
///
/// Diagnóstico sem teclado: abre o arquivo, altera valores pelo mesmo caminho
/// dos controles, salva pela ação do ⌘S (`saveDocument:`), desfaz pela do ⌘Z
/// (`undo`), confere os bytes no disco e o `.bak`, guarda fotos da janela e
/// escreve `relatorio.txt` na pasta de saída. Depois encerra o app.
///
/// Os passos são encadeados pela fila principal (sem `Task`/`await`), como
/// eventos de verdade: cada passo roda, o laço de eventos gira, vem o próximo.
@MainActor
enum Autoteste {
    static var linhas: [String] = []
    static var falhas = 0
    static var atividade: NSObjectProtocol?
    static var passos: [(espera: Double, faz: () -> Void)] = []

    static func registra(_ ok: Bool, _ s: String) {
        linhas.append((ok ? "OK    " : "FALHA ") + s)
        if !ok { falhas += 1 }
    }

    static func passo(_ espera: Double = 0.3, _ f: @escaping () -> Void) { passos.append((espera, f)) }

    /// O que muda de um formato para outro: como estragar o texto, como acrescentar
    /// uma chave e como simular outro programa gravando no arquivo.
    struct Roteiro {
        var nomeFormato: String
        var textoInvalido: (String) -> String
        var textoValido: (String) -> String
        var caminhoNovo: Caminho
        var externo: (de: String, para: String)
    }

    static func roteiro(_ arquivo: URL) -> Roteiro {
        if Formato(extensao: arquivo.pathExtension) == .json {
            return Roteiro(nomeFormato: "JSONC",
                           textoInvalido: { $0.replacingOccurrences(of: "\"versao\": 3,", with: "\"versao\": ,") },
                           textoValido: { $0.replacingOccurrences(of: "\"versao\": 3,", with: "\"versao\": 3,\n  \"novo\": 1,") },
                           caminhoNovo: [.chave("novo")],
                           externo: ("\"pool\": 12", "\"pool\": 30"))
        }
        return Roteiro(nomeFormato: "TOML",
                       textoInvalido: { $0 + "\n[novo]\nx = \n" },
                       textoValido: { $0 + "\n[novo]\nx = 1\n" },
                       caminhoNovo: [.chave("novo"), .chave("x")],
                       externo: ("pool = 12", "pool = 30"))
    }

    static func proximo() {
        guard !passos.isEmpty else { return }
        let p = passos.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + p.espera) {
            p.faz()
            proximo()
        }
    }

    /// Uma ação como se fosse um clique: depois dela, um evento de verdade passa pelo
    /// `NSApplication`, que no fim do despacho fecha o grupo de desfazer automático
    /// (é isso que marca o documento como editado num clique real).
    static func comoEvento(_ doc: Documento, _ f: () -> Void) {
        f()
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    static func rodar(arquivo: URL, saida: URL) {
        // Sem App Nap: o app roda em segundo plano e os temporizadores não podem atrasar.
        atividade = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                          reason: "autoteste")
        // Vigia: se algo abrir um alerta e travar, encerra depois de 60 s.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 60)
            let t = "FALHA tempo esgotado (alerta aberto ou travamento)\n"
            try? t.write(to: saida.appendingPathComponent("relatorio.txt"), atomically: true, encoding: .utf8)
            print(t, terminator: "")
            exit(2)
        }
        try? FileManager.default.createDirectory(at: saida, withIntermediateDirectories: true)
        let bak = arquivo.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: bak)
        let original = (try? Data(contentsOf: arquivo)) ?? Data()
        let r = roteiro(arquivo)

        var doc: Documento!
        var m: ModeloJanela { doc.modelo }
        var janela: NSWindow? { doc.windowControllers.first?.window }
        func campo(_ c: String) -> Campo? { m.secoes.flatMap(\.campos).first { $0.caminho.texto == c } }

        NSDocumentController.shared.openDocument(withContentsOf: arquivo, display: true) { d, _, erro in
            guard let d = d as? Documento else {
                registra(false, "abrir: \(erro.map { "\($0)" } ?? "-")")
                return fim(saida)
            }
            doc = d
            proximo()
        }

        passo(1.5) {
            registra(janela?.isVisible == true, "janela aberta: \(janela?.title ?? "-")")
            registra(m.edicao.documento?.nomeFormato == r.nomeFormato, "lido como \(r.nomeFormato)")
            registra((try? m.edicao.resultado()).map { Data($0) } == original, "abrir sem alterar: mesmos bytes")
            m.selecao = "servidor"
        }
        passo(0.8) {
            foto(janela, saida.appendingPathComponent("1-formulario.png"))
            registra(campo("servidor.nivel_log")?.tipo == .escolha(["debug", "info", "aviso", "erro"]),
                     "comentário 'a | b | c' virou escolha")
        }
        // Três alterações, cada uma como um evento separado (como três cliques).
        passo { comoEvento(doc) { m.definir(campo("banco.pool")!, .valor(.inteiro(20))) } }
        passo {
            comoEvento(doc) {
                m.definir(campo("servidor.portas")!, .valor(.lista([.inteiro(8080), .inteiro(8443), .inteiro(9000)])))
            }
        }
        passo { comoEvento(doc) { m.definir(campo("servidor.nivel_log")!, .valor(.texto("aviso"))) } }
        passo(0.8) {
            registra(doc.isDocumentEdited, "documento marcado como editado (título com '— Editado')")
            registra(m.trechos.count == 3, "painel de alterações com 3 trechos")
            foto(janela, saida.appendingPathComponent("2-alterado.png"))
            // ⌘S
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: doc, from: nil)
        }
        passo(2) {
            let gravado = (try? Data(contentsOf: arquivo)) ?? Data()
            registra((try? Data(contentsOf: bak)) == original, ".bak criado com o conteúdo anterior")
            let difs = Diferenca.linhas([UInt8](original), [UInt8](gravado))
            let mudadas = difs.flatMap { t in t.removidas.map { "- " + $0 } + t.adicionadas.map { "+ " + $0 } }
            linhas.append("      linhas mudadas no disco:\n" + mudadas.map { "        " + $0 }.joined(separator: "\n"))
            registra(difs.count == 3 && difs.allSatisfy { $0.removidas.count == 1 && $0.adicionadas.count == 1 },
                     "salvar mudou só as 3 linhas alteradas")
            registra(!doc.isDocumentEdited, "depois de salvar, documento limpo")
        }
        // ⌘Z três vezes
        for _ in 0..<3 { passo { comoEvento(doc) { doc.undoManager?.undo() } } }
        passo(0.5) {
            registra(m.edicao.valor(campo("banco.pool")!.caminho) == .inteiro(12), "⌘Z desfez banco.pool (20 → 12)")
            registra(m.trechos.count == 3, "depois do ⌘Z, as 3 linhas voltam a ficar pendentes em relação ao disco")
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: doc, from: nil)
        }
        passo(2) {
            registra((try? Data(contentsOf: arquivo)) == original, "desfazer tudo e salvar: arquivo idêntico ao original")
            m.trocarModo(.texto)
            m.rascunho = r.textoInvalido(String(decoding: original, as: UTF8.self))
        }
        passo(0.8) {
            registra(m.erroRascunho != nil, "texto inválido mostra erro: \(m.erroRascunho?.description ?? "-")")
            foto(janela, saida.appendingPathComponent("3-texto-erro.png"))
            registra(!m.aplicarRascunho(), "texto inválido não é aplicado")
            m.rascunho = r.textoValido(String(decoding: original, as: UTF8.self))
            registra(m.erroRascunho == nil && m.formatoRascunho == r.nomeFormato, "texto válido reconhecido como \(m.formatoRascunho)")
            var aplicou = false
            comoEvento(doc) { aplicou = m.aplicarRascunho() }
            registra(aplicou && m.edicao.documento?.entrada(r.caminhoNovo) != nil, "texto válido aplicado")
        }
        passo {
            comoEvento(doc) { doc.undoManager?.undo() }
            registra(m.edicao.temAlteracoes == false, "⌘Z desfez a edição de texto")
            m.trocarModo(.formulario)
            // Outro programa grava no arquivo sem edição pendente: o documento recarrega sozinho.
            let externo = String(decoding: original, as: UTF8.self).replacingOccurrences(of: r.externo.de, with: r.externo.para)
            try? externo.write(to: arquivo, atomically: true, encoding: .utf8)
        }
        passo(3) {
            registra(m.edicao.valor(campo("banco.pool")?.caminho ?? []) == .inteiro(30),
                     "arquivo alterado por outro programa e sem edição pendente: recarregado (pool = 30)")
            m.selecao = "banco"
        }
        passo(0.8) {
            foto(janela, saida.appendingPathComponent("4-recarregado.png"))
            try? original.write(to: arquivo)
            fim(saida)
        }
    }

    static func fim(_ saida: URL) {
        linhas.append(falhas == 0 ? "RESULTADO: tudo certo" : "RESULTADO: \(falhas) falha(s)")
        let texto = linhas.joined(separator: "\n") + "\n"
        try? texto.write(to: saida.appendingPathComponent("relatorio.txt"), atomically: true, encoding: .utf8)
        print(texto, terminator: "")
        for d in NSDocumentController.shared.documents { d.close() }
        exit(falhas == 0 ? 0 : 1)
    }

    /// Foto da própria janela (não precisa de permissão de Gravação de Tela).
    static func foto(_ w: NSWindow?, _ url: URL) {
        guard let v = w?.contentView?.superview ?? w?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
