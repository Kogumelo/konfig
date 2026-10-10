import AppKit
import ConfCore

/// `KM_CONF_AUTOTESTE="<arquivo>|<pasta-de-saída>" km-conf.app/Contents/MacOS/km-conf`
///
/// O arquivo é uma cópia de `exemplos/config.toml`, `exemplos/config.json`,
/// `exemplos/config.jsonc`, `exemplos/settings.jsonc`, `exemplos/config.json5` ou
/// `exemplos/.env` ou `exemplos/config.ini`, com o mesmo nome, ou de `config.jsonc` com nome `algo.json` (o
/// roteiro de cada formato conta com os campos desses exemplos; o `.env` é
/// reconhecido pelo nome).
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

    /// O que muda de um formato para outro: que campos alterar, como estragar o texto,
    /// como acrescentar uma chave e como simular outro programa gravando no arquivo.
    struct Roteiro {
        var nomeFormato: String
        /// Seção mostrada nas fotos.
        var secao = "servidor"
        /// Campo cujo comentário `a | b | c` vira escolha (JSON puro não tem comentários).
        var escolha: (campo: String, opcoes: [String])? = ("servidor.nivel_log", ["debug", "info", "aviso", "erro"])
        /// Três alterações, cada uma numa linha diferente.
        var alteracoes: [(campo: String, valor: Valor)] = [
            ("banco.pool", .inteiro(20)),
            ("servidor.portas", .lista([.inteiro(8080), .inteiro(8443), .inteiro(9000)])),
            ("servidor.nivel_log", .texto("aviso")),
        ]
        /// O campo da primeira alteração: valor original e o que o "outro programa" grava.
        var pool: (original: Valor, externo: Valor) = (.inteiro(12), .inteiro(30))
        var textoInvalido: (String) -> String
        var textoValido: (String) -> String
        var caminhoNovo: Caminho
        var externo: (de: String, para: String)
        /// Lista `chave[]` (INI): acrescentar um item deve acrescentar só uma linha.
        var lista: (campo: String, item: Valor)? = nil
    }

    static func roteiro(_ arquivo: URL) -> Roteiro {
        switch Formato(nomeArquivo: arquivo.lastPathComponent) {
        case .json? where arquivo.lastPathComponent.lowercased().hasPrefix("settings"):
            // exemplos/settings.jsonc, no estilo do settings.json do VS Code (chaves com ponto)
            return Roteiro(nomeFormato: "JSONC",
                           secao: "raiz",
                           escolha: ("\"editor.wordWrap\"", ["off", "on", "wordWrapColumn", "bounded"]),
                           alteracoes: [
                               ("\"editor.fontSize\"", .inteiro(16)),
                               ("\"editor.rulers\"", .lista([.inteiro(80), .inteiro(100), .inteiro(120)])),
                               ("\"editor.wordWrap\"", .texto("on")),
                           ],
                           pool: (.inteiro(14), .inteiro(18)),
                           textoInvalido: { $0.replacingOccurrences(of: "\"editor.fontSize\": 14,", with: "\"editor.fontSize\": ,") },
                           textoValido: { $0.replacingOccurrences(of: "\"editor.fontSize\": 14,", with: "\"editor.fontSize\": 14,\n  \"novo\": 1,") },
                           caminhoNovo: [.chave("novo")],
                           externo: ("\"editor.fontSize\": 14", "\"editor.fontSize\": 18"))
        case .json5?:
            return Roteiro(nomeFormato: "JSON5",
                           textoInvalido: { $0.replacingOccurrences(of: "versao: 3,", with: "versao: ,") },
                           textoValido: { $0.replacingOccurrences(of: "versao: 3,", with: "versao: 3,\n  novo: 1,") },
                           caminhoNovo: [.chave("novo")],
                           externo: ("pool: 12", "pool: 30"))
        // `config.jsonc`, ou uma cópia dele com nome `.json` (então a janela mostra o aviso "JSON com comentários")
        case .json? where arquivo.pathExtension.lowercased() == "jsonc"
            || (try? LeitorJSON.ler([UInt8](Data(contentsOf: arquivo))))?.usaExtensoesJSONC == true:
            return Roteiro(nomeFormato: "JSONC",
                           textoInvalido: { $0.replacingOccurrences(of: "\"versao\": 3,", with: "\"versao\": ,") },
                           textoValido: { $0.replacingOccurrences(of: "\"versao\": 3,", with: "\"versao\": 3,\n  \"novo\": 1,") },
                           caminhoNovo: [.chave("novo")],
                           externo: ("\"pool\": 12", "\"pool\": 30"))
        case .json?:
            return Roteiro(nomeFormato: "JSON",
                           escolha: nil,
                           textoInvalido: { $0.replacingOccurrences(of: "\"versao\": 3,", with: "\"versao\": ,") },
                           textoValido: { $0.replacingOccurrences(of: "\"versao\": 3,", with: "\"versao\": 3,\n    \"novo\": 1,") },
                           caminhoNovo: [.chave("novo")],
                           externo: ("\"pool\": 12", "\"pool\": 30"))
        case .env?:
            return Roteiro(nomeFormato: ".env",
                           secao: "raiz",
                           escolha: ("NIVEL_LOG", ["debug", "info", "aviso", "erro"]),
                           alteracoes: [
                               ("BANCO_POOL", .texto("20")),
                               ("NIVEL_LOG", .texto("aviso")),
                               ("APP_TITULO", .texto("Painel Kogumelo 2")),
                           ],
                           pool: (.texto("12"), .texto("30")),
                           textoInvalido: { $0 + "\nSEM_IGUAL\n" },
                           textoValido: { $0 + "\nNOVA=1\n" },
                           caminhoNovo: [.chave("NOVA")],
                           externo: ("BANCO_POOL=12", "BANCO_POOL=30"))
        case .ini?:
            // exemplos/config.ini (CRLF): as alterações e o texto novo usam a quebra do arquivo
            return Roteiro(nomeFormato: "INI",
                           alteracoes: [
                               ("banco.pool", .texto("20")),
                               ("servidor.porta", .texto("8443")),
                               ("servidor.nivel_log", .texto("aviso")),
                           ],
                           pool: (.texto("12"), .texto("30")),
                           textoInvalido: { $0 + "\r\nSEM_IGUAL\r\n" },
                           textoValido: { $0 + "\r\n[novo]\r\nx = 1\r\n" },
                           caminhoNovo: [.chave("novo"), .chave("x")],
                           externo: ("pool = 12", "pool = 30"),
                           lista: ("php.\"extensoes[]\"", .texto("zip")))
        default:
            return Roteiro(nomeFormato: "TOML",
                           textoInvalido: { $0 + "\n[novo]\nx = \n" },
                           textoValido: { $0 + "\n[novo]\nx = 1\n" },
                           caminhoNovo: [.chave("novo"), .chave("x")],
                           externo: ("pool = 12", "pool = 30"))
        }
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
            registra(m.avisoJSONC == (arquivo.pathExtension.lowercased() == "json" && r.nomeFormato == "JSONC"),
                     "aviso 'JSON com comentários' \(m.avisoJSONC ? "mostrado" : "não mostrado")")
            registra((try? m.edicao.resultado()).map { Data($0) } == original, "abrir sem alterar: mesmos bytes")
            m.selecao = r.secao
        }
        passo(0.8) {
            foto(janela, saida.appendingPathComponent("1-formulario.png"))
            if let e = r.escolha {
                registra(campo(e.campo)?.tipo == .escolha(e.opcoes), "comentário 'a | b | c' virou escolha")
            } else {
                registra(m.secoes.flatMap(\.campos).allSatisfy { $0.ajuda == nil }, "sem comentários, nenhum campo com ajuda")
            }
        }
        if let l = r.lista {
            passo {
                guard let c = campo(l.campo), case .lista(let itens) = c.valor else {
                    return registra(false, "lista \(l.campo) não encontrada")
                }
                comoEvento(doc) { m.definir(c, .valor(.lista(itens + [l.item]))) }
            }
            passo(0.5) {
                let t = m.trechos
                registra(t.count == 1 && t[0].trecho.removidas.isEmpty && t[0].trecho.adicionadas.count == 1,
                         "acrescentar um item na lista \(l.campo): só uma linha nova (\(t.first?.trecho.adicionadas.first ?? "-"))")
                comoEvento(doc) { doc.undoManager?.undo() }
            }
            passo(0.5) {
                registra(m.trechos.isEmpty && !m.edicao.temAlteracoes, "⌘Z desfez o item acrescentado")
            }
        }
        // Três alterações, cada uma como um evento separado (como três cliques).
        for a in r.alteracoes {
            passo { comoEvento(doc) { m.definir(campo(a.campo)!, .valor(a.valor)) } }
        }
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
            let pool = r.alteracoes[0].campo
            registra(m.edicao.valor(campo(pool)!.caminho) == r.pool.original, "⌘Z desfez \(pool) (volta a \(r.pool.original))")
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
            registra(m.edicao.valor(campo(r.alteracoes[0].campo)?.caminho ?? []) == r.pool.externo,
                     "arquivo alterado por outro programa e sem edição pendente: recarregado (\(r.externo.para))")
            if r.secao != "raiz" { m.selecao = "banco" }
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
