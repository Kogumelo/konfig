import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func k(_ partes: String...) -> Caminho { partes.map { .chave($0) } }

/// Arquivos JSONC próprios (não há suíte oficial), em `Fixtures/jsonc`, e os exemplos.
enum CasosJSONC {
    static let pasta = Suite.pasta.appendingPathComponent("jsonc")
    static let raiz = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static let fixtures: [String] = (try? FileManager.default.contentsOfDirectory(atPath: pasta.path))?
        .filter { $0.hasSuffix(".jsonc") }.sorted() ?? []
    static let exemplos = ["exemplos/config.jsonc", "exemplos/settings.jsonc"]
    static let todos = fixtures + exemplos

    static func bytes(_ caso: String) -> [UInt8] {
        let u = caso.hasPrefix("exemplos/") ? raiz.appendingPathComponent(caso) : pasta.appendingPathComponent(caso)
        return Array(try! Data(contentsOf: u))
    }
}

@Test func casosJSONCPresentes() {
    #expect(CasosJSONC.fixtures == [
        "barras-dentro-de-texto.jsonc", "bom-crlf.jsonc", "bom.jsonc", "comentarios-em-cada-posicao.jsonc",
        "crlf.jsonc", "virgula-final.jsonc",
    ])
}

@Test(arguments: CasosJSONC.todos)
func jsoncSemAlteracaoMesmosBytes(_ caso: String) throws {
    let bytes = CasosJSONC.bytes(caso)
    var ed = Edicao(bytes, formato: .json)
    #expect(ed.documento?.usaExtensoesJSONC == true, "\(ed.erro.map { "\($0)" } ?? "")")
    // JSON puro recusa; JSONC aceita
    #expect(throws: ErroLeitura.self) { try LeitorJSON.ler(bytes, estrito: true) }
    #expect(try ed.resultado() == bytes)
    for e in ed.documento?.entradas ?? [] { try ed.definir(e.caminho, .valor(e.valor)) }
    #expect(ed.alteracoes.isEmpty)
    #expect(try ed.resultado() == bytes)
}

@Test(arguments: CasosJSONC.todos)
func jsoncMudarCadaValor(_ caso: String) throws {
    let bytes = CasosJSONC.bytes(caso)
    let doc = try LeitorJSON.ler(bytes)
    #expect(!doc.entradas.isEmpty)
    for e in doc.entradas {
        guard let novo = mutado(e.valor), Formato.json.problema(novo) == nil else { continue }
        let saida = try Gravar.aplicar(doc, alteracoes: [e.caminho: .valor(novo)])
        #expect(soOTrechoMudou(bytes, saida, e.intervalo), "\(caso) \(e.caminho.texto)")
        let relido = try LeitorJSON.ler(saida)
        #expect(relido.valorRaiz.valor(em: e.caminho) == novo, "\(caso) \(e.caminho.texto)")
        #expect(relido.usaExtensoesJSONC && relido.temBOM == doc.temBOM && relido.quebraDeLinha == doc.quebraDeLinha)
    }
}

// MARK: - Comentários em cada posição

@Test func jsoncComentariosEmCadaPosicao() throws {
    let doc = try LeitorJSON.ler(CasosJSONC.bytes("comentarios-em-cada-posicao.jsonc"))
    let puro = try LeitorJSON.ler("""
        {"a": 1, "b": 2, "c": 3, "d": "x", "e": [1, 2, 3], "f": {}, "g": [], "h": {"i": true}}
        """, estrito: true)
    #expect(doc.valorRaiz == puro.valorRaiz)
    #expect(doc.entrada(k("a"))?.comentarioAcima == ["acima da chave"])
    #expect(doc.entrada(k("a"))?.comentarioFim == "fim da linha, depois da vírgula")
    #expect(doc.entrada(k("c"))?.comentarioFim == "depois do valor, antes da vírgula")
    #expect(doc.entrada(k("d"))?.comentarioAcima == ["bloco", "de várias", "linhas"])
    #expect(doc.entrada(k("e"))?.comentarioFim == nil || doc.entrada(k("e"))?.comentarioFim == "depois do [")
    #expect(doc.entrada(k("h", "i"))?.comentarioAcima == ["aninhado"])
    #expect(doc.entrada(k("h", "i"))?.comentarioFim == "fim")
    // mudar "b", cercado de comentários dos dois lados, não toca neles
    let saida = s(try Gravar.aplicar(doc, alteracoes: [k("b"): .valor(.inteiro(20))]))
    #expect(saida.contains(#""b" /* entre chave e dois-pontos */ : /* entre dois-pontos e valor */ 20,"#))
    // e a lista, mudando a quantidade de itens, é reescrita (os comentários dentro dela se perdem, como no TOML)
    let l = s(try Gravar.aplicar(doc, alteracoes: [k("e"): .valor(.lista([.inteiro(1), .inteiro(2)]))]))
    #expect(l.contains("\"e\": [\n    1,\n    2\n  ],\n  \"f\""))
}

@Test func jsoncVirgulaFinalMantida() throws {
    let original = CasosJSONC.bytes("virgula-final.jsonc")
    var ed = Edicao(original, formato: .json)
    try ed.definir(k("lista"), .valor(.lista([.inteiro(1), .inteiro(2)])))
    try ed.definir(k("listaVariasLinhas"), .valor(.lista([.texto("a"), .texto("b"), .texto("c")])))
    try ed.definir(k("objetoVariasLinhas", "y"), .valor(.lista([.booleano(true)])))
    try ed.definir(k("comComentario"), .valor(.lista([.inteiro(10), .inteiro(25)])))
    let r = s(try ed.resultado())
    #expect(r.contains(#""lista": [1, 2,],"#))
    #expect(r.contains("\"listaVariasLinhas\": [\n    \"a\",\n    \"b\",\n    \"c\",\n  ],"))
    #expect(r.contains(#""y": [true,],"#))
    // mesma quantidade: os comentários dentro da lista ficam
    #expect(r.contains("10, // dez\n    25, /* vinte */\n  ],"))
    // sem vírgula final no original: nenhuma aparece
    let semVirgula = #"{"l": [1, 2]}"#
    #expect(s(try Gravar.aplicar(b(semVirgula), alteracoes: [k("l"): .valor(.lista([.inteiro(3)]))], formato: .json))
            == #"{"l": [3]}"#)
}

@Test func jsoncBarrasDentroDeTexto() throws {
    let doc = try LeitorJSON.ler(CasosJSONC.bytes("barras-dentro-de-texto.jsonc"))
    #expect(doc.raiz["url"] == .texto("http://exemplo.com/a"))
    #expect(doc.raiz["abre"] == .texto("/* isto não é comentário"))
    #expect(doc.raiz["fecha"] == .texto("nem isto */"))
    #expect(doc.raiz["dupla"] == .texto("// nem isto"))
    #expect(doc.raiz["aspas"] == .texto("fim com \\\" e // depois"))
    #expect(doc.raiz["barraFinal"] == .texto("c:\\pasta\\"))
    #expect(doc.raiz["glob"] == .texto("src/**/*.ts"))
    #expect(doc.entrada(k("url"))?.comentarioFim == "a URL tem // e não é comentário")
    #expect(doc.entrada(k("aspas"))?.comentarioFim == "comentário de verdade")
    #expect(doc.entrada(k("barraFinal"))?.comentarioFim == "texto que termina em barra invertida")
    #expect(doc.entrada(k("abre"))?.comentarioFim == nil)
}

@Test func jsoncCRLFeBOM() throws {
    for caso in ["crlf.jsonc", "bom.jsonc", "bom-crlf.jsonc"] {
        let original = CasosJSONC.bytes(caso)
        let doc = try LeitorJSON.ler(original)
        #expect(doc.temBOM == caso.hasPrefix("bom"), "\(caso)")
        #expect(doc.quebraDeLinha == (caso.contains("crlf") ? "\r\n" : "\n"), "\(caso)")
    }
    // lista que cresce num arquivo CRLF: as quebras novas também são CRLF
    let crlf = CasosJSONC.bytes("crlf.jsonc")
    let r = s(try Gravar.aplicar(crlf, alteracoes: [k("b"): .valor(.lista([.inteiro(1), .inteiro(2), .inteiro(3)]))],
                                 formato: .json))
    #expect(r.contains("\"b\": [\r\n    1,\r\n    2,\r\n    3,\r\n  ],\r\n"))
    #expect(!r.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    // BOM fica
    let bom = CasosJSONC.bytes("bom.jsonc")
    let rb = try Gravar.aplicar(bom, alteracoes: [k("nome"): .valor(.texto("Joana"))], formato: .json)
    #expect(rb.starts(with: [0xEF, 0xBB, 0xBF]))
    #expect(s(rb).contains("\"nome\": \"Joana\", /* acento */"))
}

// MARK: - exemplos/settings.jsonc

@Test func exemploSettingsJSONC() throws {
    let original = CasosJSONC.bytes("exemplos/settings.jsonc")
    let doc = try LeitorJSON.ler(original)
    let secoes = Campos.secoes(doc)
    // chaves com ponto aparecem entre aspas, para não serem confundidas com o caminho
    #expect(secoes.map(\.titulo) == ["Raiz", #""files.exclude""#, #""files.associations""#, #""[python]""#,
                                     #""[markdown]""#, #""terminal.integrated.env.osx""#])
    let campos = Dictionary(uniqueKeysWithValues: secoes.flatMap(\.campos).map { ($0.caminho, $0) })
    #expect(campos[k("editor.wordWrap")]?.tipo == .escolha(["off", "on", "wordWrapColumn", "bounded"]))
    #expect(campos[k("editor.renderWhitespace")]?.tipo == .escolha(["none", "boundary", "selection", "trailing", "all"]))
    #expect(campos[k("files.autoSave")]?.tipo == .escolha(["off", "afterDelay", "onFocusChange", "onWindowChange"]))
    #expect(campos[k("editor.tabSize")]?.ajuda == "espaços por tabulação")
    #expect(campos[k("editor.rulers")]?.tipo == .lista(.inteiro))

    var ed = Edicao(original, formato: .json)
    try ed.definir(k("editor.fontSize"), .valor(.inteiro(16)))
    try ed.definir(k("editor.wordWrap"), .valor(.texto("on")))
    try ed.definir(k("[python]", "editor.tabSize"), .valor(.inteiro(2)))
    let r = s(try ed.resultado())
    #expect(r == s(original)
        .replacingOccurrences(of: "\"editor.fontSize\": 14,", with: "\"editor.fontSize\": 16,")
        .replacingOccurrences(of: "\"editor.wordWrap\": \"off\",", with: "\"editor.wordWrap\": \"on\",")
        .replacingOccurrences(of: "\"editor.tabSize\": 4,", with: "\"editor.tabSize\": 2,"))
    #expect(r.contains("// off | on | wordWrapColumn | bounded\n  \"editor.wordWrap\": \"on\","))
}
