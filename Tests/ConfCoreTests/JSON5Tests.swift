import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func k(_ partes: String...) -> Caminho { partes.map { .chave($0) } }

/// Aplica uma alteração num JSON5 e devolve o texto novo.
private func troca5(_ texto: String, _ caminho: Caminho, _ v: Valor) throws -> String {
    s(try Gravar.aplicar(b(texto), alteracoes: [caminho: .valor(v)], formato: .json5))
}

/// Casos da suíte oficial json5/json5-tests, copiados em `Fixtures/json5`.
/// Pela regra dela: `.json` e `.json5` são válidos; `.js` e `.txt`, inválidos.
enum SuiteJSON5 {
    static let pasta = Suite.pasta.appendingPathComponent("json5")

    static let todos: [String] = {
        let e = FileManager.default.enumerator(at: pasta, includingPropertiesForKeys: nil)!
        var r: [String] = []
        for case let u as URL in e where ["json", "json5", "js", "txt"].contains(u.pathExtension) {
            let rel = String(u.path.dropFirst(pasta.path.count + 1))
            if rel != "ORIGEM.txt" { r.append(rel) }
        }
        return r.sorted()
    }()
    static let validos = todos.filter { $0.hasSuffix(".json") || $0.hasSuffix(".json5") }
    static let invalidos = todos.filter { $0.hasSuffix(".js") || $0.hasSuffix(".txt") }

    static func bytes(_ caso: String) -> [UInt8] {
        Array(try! Data(contentsOf: pasta.appendingPathComponent(caso)))
    }
}

// MARK: - Conformidade (json5-tests)

@Test func suiteJSON5TemOsCasos() {
    #expect(SuiteJSON5.validos.count == 83)
    #expect(SuiteJSON5.invalidos.count == 31)
}

@Test(arguments: SuiteJSON5.validos)
func json5Valido(_ caso: String) throws {
    let bytes = SuiteJSON5.bytes(caso)
    let doc: DocumentoConf
    do { doc = try LeitorJSON.lerJSON5(bytes) } catch {
        Issue.record("recusou um caso válido: \(error)")
        return
    }
    #expect(doc.formato == .json5 && doc.nomeFormato == "JSON5")
    // os `.json` são JSON puro: o mesmo valor que o leitor JSON e o JSONSerialization leem
    if caso.hasSuffix(".json") {
        let json = try LeitorJSON.ler(bytes)
        #expect(json.valorRaiz == doc.valorRaiz)
        if caso != "objects/duplicate-keys.json",
           let esperado = try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) {
            let d = CompararJSON.valor(doc.valorRaiz, esperado, "$")
            #expect(d.isEmpty, "\(d.prefix(5).joined(separator: "\n"))")
        }
    }
}

@Test(arguments: SuiteJSON5.invalidos)
func json5Invalido(_ caso: String) {
    do {
        let doc = try LeitorJSON.lerJSON5(SuiteJSON5.bytes(caso))
        Issue.record("aceitou um caso inválido: \(doc.valorRaiz)")
    } catch {
        #expect(error.linha >= 1 && error.coluna >= 1)
        #expect(error.formato == .json5)
    }
}

/// O valor lido de alguns casos `.json5`, conferido à mão (o sistema não lê JSON5).
@Test func json5ValoresDaSuite() throws {
    func v(_ caso: String) throws -> Valor { try LeitorJSON.lerJSON5(SuiteJSON5.bytes(caso)).valorRaiz }
    #expect(try v("numbers/hexadecimal.json5") == .inteiro(0xC8))
    #expect(try v("numbers/negative-hexadecimal.json5") == .inteiro(-0xC8))
    #expect(try v("numbers/hexadecimal-with-integer-exponent.json5") == .inteiro(0xC8E4))
    #expect(try v("numbers/infinity.json5") == .decimal(.infinity))
    #expect(try v("numbers/negative-infinity.json5") == .decimal(-.infinity))
    #expect(try v("numbers/nan.json5") == .decimal(.nan))
    #expect(try v("numbers/float-leading-decimal-point.json5") == .decimal(0.5))
    #expect(try v("numbers/float-trailing-decimal-point.json5") == .decimal(5))
    #expect(try v("numbers/positive-integer.json5") == .inteiro(15))
    #expect(try v("numbers/negative-zero-float-leading-decimal-point.json5") == .decimal(-0.0))
    #expect(try v("strings/multi-line-string.json5") == .texto("hello world"))
    #expect(try v("strings/escaped-single-quoted-string.json5") == .texto("I can't wait"))
    #expect(try v("new-lines/escaped-cr.json5") == .tabela(Tabela(pares: [.init(chave: "a", valor: .texto("line 1 line 2"))])))
    #expect(try v("todo/unicode-escaped-unquoted-key.json5")
            == .tabela(Tabela(pares: [.init(chave: "sigΣma", valor: .texto("the sum of all things"))])))
    let leia = try LeitorJSON.lerJSON5(SuiteJSON5.bytes("misc/readme-example.json5"))
    #expect(leia.raiz["hex"] == .inteiro(0xDEADBEEF))
    #expect(leia.raiz["half"] == .decimal(0.5))
    #expect(leia.raiz["delta"] == .inteiro(10))
    #expect(leia.raiz["to"] == .decimal(.infinity))
    #expect(leia.raiz["this"] == .texto("is a multi-line string"))
    #expect(leia.entrada(k("here"))?.comentarioFim == "inline comment")
    #expect(leia.entrada(k("to"))?.comentarioFim == "and beyond!")
}

// MARK: - Ida e volta

private let json5Especiais: [String: [UInt8]] = [
    "exemplo": exemploJSON5Bytes(),
    "estilos": b("""
    {
      // chaves sem aspas, com aspas simples e duplas
      semAspas: 'simples', 'simples': "duplas", "duplas": 'it\\'s',
      $id_1: 0xff, b: 0XAB, c: -0x10, d: +7, e: .5, f: 5., g: +1.5e3, h: -.25, i: 5.e2,
      j: Infinity, k: -Infinity, l: +Infinity, m: NaN, n: -NaN,
      o: 'continua \\
    na outra linha', p: '\\x41\\v\\0\\a', q: [1, 'dois', 0x3,],
    }
    """),
    "crlf-bom": [0xEF, 0xBB, 0xBF] + b("{\r\n  // c\r\n  a: 'x\\\r\ny',\r\n  b: [\r\n    0x1,\r\n    .5,\r\n  ],\r\n}\r\n"),
    "cr": b("{\r  a: 1, // c\r  b: 'x\\\ry',\r}\r"),
    "espacos": b("{\u{0B}a\u{0C}:\u{A0}1,\u{FEFF}b\u{2028}:\u{2029}2\u{3000}}"),
]

private func exemploJSON5Bytes() -> [UInt8] {
    let raiz = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    return Array(try! Data(contentsOf: raiz.appendingPathComponent("exemplos/config.json5")))
}

private let casosIdaEVolta5 = SuiteJSON5.validos + Array(json5Especiais.keys).sorted()

@Test(arguments: casosIdaEVolta5)
func json5SemAlteracaoMesmosBytes(_ caso: String) throws {
    let bytes = json5Especiais[caso] ?? SuiteJSON5.bytes(caso)
    var ed = Edicao(bytes, formato: .json5)
    #expect(ed.documento != nil, "\(ed.erro.map { "\($0)" } ?? "")")
    #expect(try ed.resultado() == bytes)
    for e in ed.documento?.entradas ?? [] { try ed.definir(e.caminho, .valor(e.valor)) }
    #expect(ed.alteracoes.isEmpty)
    #expect(try ed.resultado() == bytes)
    #expect(!ed.temAlteracoes)
}

@Test(arguments: casosIdaEVolta5)
func json5MudarCadaValor(_ caso: String) throws {
    let bytes = json5Especiais[caso] ?? SuiteJSON5.bytes(caso)
    let doc = try LeitorJSON.lerJSON5(bytes)
    for e in doc.entradas {
        guard let novo = mutado(e.valor), Formato.json5.problema(novo) == nil else { continue }
        let saida = try Gravar.aplicar(doc, alteracoes: [e.caminho: .valor(novo)])
        #expect(soOTrechoMudou(bytes, saida, e.intervalo), "\(caso) \(e.caminho.texto)")
        let relido = try LeitorJSON.lerJSON5(saida)
        #expect(relido.valorRaiz.valor(em: e.caminho) == novo, "\(caso) \(e.caminho.texto)")
        #expect(relido.temBOM == doc.temBOM && relido.quebraDeLinha == doc.quebraDeLinha)
        // o estilo do valor se mantém
        let antes = s(Array(bytes[e.intervalo]))
        let depois = s(Array(saida[e.intervalo.lowerBound..<(saida.count - (bytes.count - e.intervalo.upperBound))]))
        if case .texto = e.valor { #expect(antes.first == depois.first, "\(caso): aspas \(antes) → \(depois)") }
        if case .inteiro = e.valor, antes.lowercased().contains("0x") {
            #expect(depois.lowercased().contains("0x"), "\(caso): hexadecimal \(antes) → \(depois)")
        }
    }
}

// MARK: - Estilo de cada valor ao gravar

@Test func json5TextoMantemAspas() throws {
    let t = "{a: 'um', b: \"dois\", c: 'it\\'s', d: 'x\\\nfim'}"
    #expect(try troca5(t, k("a"), .texto("o'k \"sim\"")) == "{a: 'o\\'k \"sim\"', b: \"dois\", c: 'it\\'s', d: 'x\\\nfim'}")
    #expect(try troca5(t, k("b"), .texto("it's")) == "{a: 'um', b: \"it's\", c: 'it\\'s', d: 'x\\\nfim'}")
    #expect(try troca5(t, k("c"), .texto("it's ok")) == "{a: 'um', b: \"dois\", c: 'it\\'s ok', d: 'x\\\nfim'}")
    // a continuação de linha fica onde estava quando o resto do texto não muda
    #expect(try troca5(t, k("d"), .texto("xfim!")) == "{a: 'um', b: \"dois\", c: 'it\\'s', d: 'x\\\nfim!'}")
    // escapes que só o JSON5 tem são copiados como estavam
    #expect(try troca5("{p: '\\x41\\v-'}", k("p"), .texto("A\u{0B}+")) == "{p: '\\x41\\v+'}")
}

@Test func json5NumeroMantemForma() throws {
    let t = "{a: 0xff, b: 0X1F, c: 0x00FF, d: +7, e: .5, f: 5., g: +1.5e3, h: Infinity, i: NaN, j: 3}"
    #expect(try troca5(t, k("a"), .inteiro(4096)).contains("a: 0x1000,"))
    #expect(try troca5(t, k("a"), .inteiro(-1)).contains("a: -0x01,"))
    #expect(try troca5(t, k("b"), .inteiro(171)).contains("b: 0XAB,"))
    #expect(try troca5(t, k("c"), .inteiro(10)).contains("c: 0x000A,"))
    #expect(try troca5(t, k("d"), .inteiro(8)).contains("d: +8,"))
    #expect(try troca5(t, k("d"), .inteiro(-8)).contains("d: -8,"))
    #expect(try troca5(t, k("e"), .decimal(0.25)).contains("e: .25,"))
    #expect(try troca5(t, k("e"), .decimal(1.25)).contains("e: 1.25,"))
    #expect(try troca5(t, k("f"), .decimal(6)).contains("f: 6.,"))
    #expect(try troca5(t, k("f"), .decimal(6.5)).contains("f: 6.5,"))
    #expect(try troca5(t, k("g"), .decimal(2000)).contains("g: +2.0e3,"))
    #expect(try troca5(t, k("h"), .decimal(-.infinity)).contains("h: -Infinity,"))
    #expect(try troca5(t, k("h"), .decimal(2.5)).contains("h: 2.5,"))
    #expect(try troca5(t, k("i"), .decimal(.nan)) == t)
    #expect(try troca5(t, k("j"), .decimal(.nan)).contains("j: NaN}"))
    // JSON5 aceita infinito e NaN; JSON não
    #expect(Formato.json5.problema(.decimal(.infinity)) == nil)
    #expect(Formato.json.problema(.decimal(.infinity)) != nil)
}

@Test func json5ListaComVirgulaFinal() throws {
    let t = "{\n  l: [\n    0x1, // um\n    'a',\n  ],\n}\n"
    // mesma quantidade: só o item muda, o comentário fica
    #expect(try troca5(t, k("l"), .lista([.inteiro(2), .texto("a")])) == "{\n  l: [\n    0x2, // um\n    'a',\n  ],\n}\n")
    // mais itens: reescrita com o recuo do primeiro e a vírgula final; cada item no estilo do antigo
    #expect(try troca5(t, k("l"), .lista([.inteiro(1), .texto("a"), .texto("b")]))
            == "{\n  l: [\n    0x1,\n    'a',\n    'b',\n  ],\n}\n")
}

// MARK: - Leitura

@Test func json5ChavesEComentarios() throws {
    let t = """
    {
      // debug | info | erro
      nivel: 'info',
      $porta: 8080, // porta HTTP
      'com espaço': true,
      ümlåût: 1,
      \\u0061b: 2,
    }
    """
    let doc = try LeitorJSON.lerJSON5(t)
    #expect(doc.raiz.pares.map(\.chave) == ["nivel", "$porta", "com espaço", "ümlåût", "ab"])
    let campos = Dictionary(uniqueKeysWithValues: Campos.secoes(doc).flatMap(\.campos).map { ($0.caminho, $0) })
    #expect(campos[k("nivel")]?.tipo == .escolha(["debug", "info", "erro"]))
    #expect(campos[k("$porta")]?.ajuda == "porta HTTP")
}

@Test func json5Erros() {
    for t in ["{1a: 1}", "{a-b: 1}", "[010]", "[0x]", "['a\nb']", "['\\1']", "[.]", "[+]", "{a: 1,,}", "[,]", "{'a' 1}"] {
        #expect(throws: ErroLeitura.self, "\(t.debugDescription)") { try LeitorJSON.lerJSON5(t) }
    }
    // o JSON e o JSONC continuam recusando o que é só do JSON5
    for t in ["{a: 1}", "['x']", "[0x1]", "[Infinity]", "[.5]", "[+1]"] {
        #expect(throws: ErroLeitura.self, "\(t.debugDescription)") { try LeitorJSON.ler(t) }
    }
    do {
        _ = try LeitorJSON.lerJSON5("{\n  a: 1,\n  b c\n}")
        Issue.record("deveria recusar")
    } catch {
        #expect(error.linha == 3 && error.coluna == 5)
        #expect(error.localizedDescription.hasPrefix("JSON5 inválido"))
    }
}

@Test func formatoJSON5PelaExtensao() {
    #expect(Formato(extensao: "json5") == .json5)
    #expect(Formato(nomeArquivo: "config.JSON5") == .json5)
    #expect(Formato(nomeArquivo: "settings.jsonc") == .json)
    #expect(Formato.json5.ehJSON && Formato.json.ehJSON && !Formato.toml.ehJSON)
}

// MARK: - exemplos/config.json5

@Test func exemploJSON5() throws {
    let original = exemploJSON5Bytes()
    let doc = try LeitorJSON.lerJSON5(original)
    let secoes = Campos.secoes(doc)
    #expect(secoes.map(\.titulo) == ["Raiz", "servidor", "banco", "backup", "tarefas[0].ambiente", "limpar-logs"])
    let campos = Dictionary(uniqueKeysWithValues: secoes.flatMap(\.campos).map { ($0.id, $0) })
    #expect(campos["servidor.nivel_log"]?.tipo == .escolha(["debug", "info", "aviso", "erro"]))
    #expect(campos["banco.driver"]?.tipo == .escolha(["firebird", "postgres"]))
    #expect(campos["servidor.permissoes"]?.tipo == .inteiro)
    #expect(campos["banco.limite_linhas"]?.tipo == .decimal)
    #expect(campos["descricao"]?.valor == .texto("Painel dos sistemas Kogumelo e LanceWeb"))
    #expect(campos["titulo"]?.ajuda == "Nome que aparece no topo")

    var ed = Edicao(original, formato: .json5)
    try ed.definir(k("banco", "pool"), .valor(.inteiro(20)))
    try ed.definir(k("banco", "fator"), .valor(.decimal(2.25)))
    try ed.definir(k("servidor", "permissoes"), .valor(.inteiro(0o750)))
    try ed.definir(k("servidor", "tempo_limite"), .valor(.decimal(0.75)))
    try ed.definir(k("servidor", "nivel_log"), .valor(.texto("aviso")))
    try ed.definir([.chave("tarefas"), .indice(0), .chave("ambiente"), .chave("DESTINO")], .valor(.texto("/srv/backup")))
    let r = s(try ed.resultado())
    #expect(r == s(original)
        .replacingOccurrences(of: "pool: 12,", with: "pool: 20,")
        .replacingOccurrences(of: "fator: +1.50,", with: "fator: +2.25,")
        .replacingOccurrences(of: "permissoes: 0x1ED,", with: "permissoes: 0x1E8,")
        .replacingOccurrences(of: "tempo_limite: .5,", with: "tempo_limite: .75,")
        .replacingOccurrences(of: "nivel_log: 'info',", with: "nivel_log: 'aviso',")
        .replacingOccurrences(of: "DESTINO: '/mnt/backup'", with: "DESTINO: '/srv/backup'"))
    // os comentários vizinhos continuam lá
    #expect(r.contains("pool: 20, // conexões simultâneas\n"))
    #expect(r.contains("// debug | info | aviso | erro\n    nivel_log: 'aviso',"))
}
