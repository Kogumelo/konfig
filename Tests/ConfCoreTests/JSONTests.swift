import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func k(_ partes: String...) -> Caminho { partes.map { .chave($0) } }

/// Aplica uma alteração num JSON e devolve o texto novo.
private func troca(_ texto: String, _ caminho: Caminho, _ v: Valor) throws -> String {
    s(try Gravar.aplicar(b(texto), alteracoes: [caminho: .valor(v)], formato: .json))
}

/// Casos da JSONTestSuite (nst/JSONTestSuite, `test_parsing`), copiados em `Fixtures/JSONTestSuite`.
enum SuiteJSON {
    static let pasta = Suite.pasta.appendingPathComponent("JSONTestSuite/test_parsing")

    static let todos: [String] = (try? FileManager.default.contentsOfDirectory(atPath: pasta.path))?
        .filter { $0.hasSuffix(".json") }.sorted() ?? []
    static let y = todos.filter { $0.hasPrefix("y_") }
    static let n = todos.filter { $0.hasPrefix("n_") }
    static let i = todos.filter { $0.hasPrefix("i_") }

    static func bytes(_ caso: String) -> [UInt8] {
        Array(try! Data(contentsOf: pasta.appendingPathComponent(caso)))
    }

    /// `n_` recusados pelo JSON puro mas aceitos em JSONC: o único "erro" deles é
    /// comentário ou vírgula final.
    static let nAceitosEmJSONC: Set<String> = [
        "n_array_extra_comma.json",                    // ["",]
        "n_array_number_and_comma.json",               // [1,]
        "n_object_trailing_comma.json",                // {"id":0,}
        "n_object_trailing_comment.json",              // {"a":"b"}/**/
        "n_object_trailing_comment_slash_open.json",   // {"a":"b"}//
        "n_structure_object_with_comment.json",        // {"a":/*comment*/"b"}
    ]

    /// O que o km-conf faz com cada caso `i_` (a especificação deixa a critério de quem lê).
    /// `true` = aceita. Documentado no README.
    static let casosI: [String: Bool] = [
        // números fora do alcance: aceitos; inteiro que não cabe em 64 bits vira decimal
        // aproximado, expoente enorme vira infinito ou zero. Só são reescritos se editados.
        "i_number_double_huge_neg_exp.json": true,
        "i_number_huge_exp.json": true,
        "i_number_neg_int_huge_exp.json": true,
        "i_number_pos_double_huge_exp.json": true,
        "i_number_real_neg_overflow.json": true,
        "i_number_real_pos_overflow.json": true,
        "i_number_real_underflow.json": true,
        "i_number_too_big_neg_int.json": true,
        "i_number_too_big_pos_int.json": true,
        "i_number_very_big_negative_int.json": true,
        // BOM UTF-8 no começo: aceito e mantido ao gravar
        "i_structure_UTF-8_BOM_empty_object.json": true,
        // 500 níveis de aninhamento: recusado (o limite é 128, protege a pilha)
        "i_structure_500_nested_arrays.json": false,
        // escapes \u de surrogate sem par: recusados (não cabem num texto Unicode válido)
        "i_object_key_lone_2nd_surrogate.json": false,
        "i_string_1st_surrogate_but_2nd_missing.json": false,
        "i_string_1st_valid_surrogate_2nd_invalid.json": false,
        "i_string_incomplete_surrogate_and_escape_valid.json": false,
        "i_string_incomplete_surrogate_pair.json": false,
        "i_string_incomplete_surrogates_escape_valid.json": false,
        "i_string_invalid_lonely_surrogate.json": false,
        "i_string_invalid_surrogate.json": false,
        "i_string_inverted_surrogates_U+1D11E.json": false,
        "i_string_lone_second_surrogate.json": false,
        // bytes que não são UTF-8 válido (inclusive ISO-8859-1 e UTF-16): recusados
        "i_string_UTF-16LE_with_BOM.json": false,
        "i_string_UTF-8_invalid_sequence.json": false,
        "i_string_UTF8_surrogate_U+D800.json": false,
        "i_string_invalid_utf-8.json": false,
        "i_string_iso_latin_1.json": false,
        "i_string_lone_utf8_continuation_byte.json": false,
        "i_string_not_in_unicode_range.json": false,
        "i_string_overlong_sequence_2_bytes.json": false,
        "i_string_overlong_sequence_6_bytes.json": false,
        "i_string_overlong_sequence_6_bytes_null.json": false,
        "i_string_truncated-utf-8.json": false,
        "i_string_utf16BE_no_BOM.json": false,
        "i_string_utf16LE_no_BOM.json": false,
    ]

    static func fixture(_ nome: String) -> [UInt8] {
        Array(try! Data(contentsOf: Suite.pasta.appendingPathComponent("json/" + nome)))
    }
}

// MARK: - Conformidade (JSONTestSuite)

@Test func suiteJSONTemOsCasos() {
    #expect(SuiteJSON.y.count == 95)
    #expect(SuiteJSON.n.count == 188)
    #expect(SuiteJSON.i.count == 35)
    #expect(Set(SuiteJSON.casosI.keys) == Set(SuiteJSON.i), "todo caso i_ precisa estar documentado")
}

@Test(arguments: SuiteJSON.y)
func jsonY(_ caso: String) throws {
    let bytes = SuiteJSON.bytes(caso)
    let doc: DocumentoConf
    do { doc = try LeitorJSON.ler(bytes, estrito: true) } catch {
        Issue.record("recusou um caso válido: \(error)")
        return
    }
    #expect(!doc.usaExtensoesJSONC)
    // o mesmo valor que o JSONSerialization do sistema lê — menos chave repetida:
    // ele fica com a primeira; aqui vale a última, como em JavaScript, Python e Go
    if caso == "y_object_duplicated_key.json" {
        #expect(doc.valorRaiz == .tabela(Tabela(pares: [.init(chave: "a", valor: .texto("c"))])))
    } else if let esperado = try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) {
        let d = CompararJSON.valor(doc.valorRaiz, esperado, "$")
        #expect(d.isEmpty, "\(d.prefix(5).joined(separator: "\n"))")
    }
    // e o leitor JSONC (padrão) aceita igual
    #expect(try LeitorJSON.ler(bytes).valorRaiz == doc.valorRaiz)
}

@Test(arguments: SuiteJSON.n)
func jsonN(_ caso: String) {
    let bytes = SuiteJSON.bytes(caso)
    do {
        let doc = try LeitorJSON.ler(bytes, estrito: true)
        Issue.record("JSON puro aceitou um caso inválido: \(doc.valorRaiz)")
    } catch {
        #expect(error.linha >= 1 && error.coluna >= 1)
    }
    let aceitoEmJSONC = (try? LeitorJSON.ler(bytes)) != nil
    #expect(aceitoEmJSONC == SuiteJSON.nAceitosEmJSONC.contains(caso),
            "JSONC \(aceitoEmJSONC ? "aceitou" : "recusou") \(caso)")
}

@Test(arguments: SuiteJSON.i)
func jsonI(_ caso: String) {
    let aceito = (try? LeitorJSON.ler(SuiteJSON.bytes(caso), estrito: true)) != nil
    #expect(aceito == SuiteJSON.casosI[caso], "\(caso): \(aceito ? "aceito" : "recusado")")
}

/// Compara com o que o `JSONSerialization` leu.
enum CompararJSON {
    static func valor(_ v: Valor, _ j: Any, _ onde: String) -> [String] {
        switch (v, j) {
        case (.tabela(let t), let d as NSDictionary):
            var r: [String] = []
            if t.pares.count != d.count { r.append("\(onde): \(t.pares.count) chaves, esperado \(d.count)") }
            for case let (k as String, x) in d {
                guard let y = t[k] else { r.append("\(onde): falta \(k)"); continue }
                r += valor(y, x, onde + "." + k)
            }
            return r
        case (.lista(let l), let a as NSArray):
            guard l.count == a.count else { return ["\(onde): \(l.count) itens, esperado \(a.count)"] }
            return zip(l, a).enumerated().flatMap { i, p in valor(p.0, p.1, "\(onde)[\(i)]") }
        case (.texto(let x), let y as String):
            return x.unicodeScalars.elementsEqual(y.unicodeScalars) ? [] : ["\(onde): \(x.debugDescription) ≠ \(y.debugDescription)"]
        case (.nulo, is NSNull):
            return []
        case (.booleano(let x), _) where booleano(j) != nil:
            return x == booleano(j) ? [] : ["\(onde): \(x) ≠ \(j)"]
        case (.inteiro(let x), _) where booleano(j) == nil && numero(j) != nil:
            return Double(x) == numero(j) ? [] : ["\(onde): \(x) ≠ \(j)"]
        case (.decimal(let x), _) where booleano(j) == nil && numero(j) != nil:
            // o JSONSerialization converte por NSDecimalNumber e pode errar no último dígito
            let y = numero(j)!
            return x == y || abs(x - y) <= abs(x) * 1e-15 ? [] : ["\(onde): \(x) ≠ \(j)"]
        default:
            return ["\(onde): \(v) ≠ \(j)"]
        }
    }

    /// `true`/`false` do JSONSerialization (no Mac, um CFBoolean; no Linux, NSNumber do tipo "c" ou Bool).
    static func booleano(_ j: Any) -> Bool? {
        #if canImport(Darwin)
        if let n = j as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
        #else
        if let n = j as? NSNumber { return String(cString: n.objCType) == "c" ? n.boolValue : nil }
        return j as? Bool
        #endif
    }

    static func numero(_ j: Any) -> Double? {
        if let n = j as? NSNumber { return n.doubleValue }
        if let i = j as? Int { return Double(i) }
        return j as? Double
    }
}

// MARK: - Ida e volta: abrir e gravar sem alterar é idêntico; alterar muda só o trecho

private let jsonEspeciais: [String: [UInt8]] = [
    "tsconfig": SuiteJSON.fixture("tsconfig.json"),
    "crlf-bom": [0xEF, 0xBB, 0xBF] + b("{\r\n  // c\r\n  \"a\": 1,\r\n  \"b\": [\r\n    \"x\",\r\n    \"y\",\r\n  ],\r\n  \"c\": {\"d\": null}\r\n}\r\n"),
    "raiz-lista": b("[\n  {\"nome\": \"a\", \"n\": 1},\n  {\"nome\": \"b\", \"n\": 2}\n]\n"),
    "raiz-escalar": b("  \"só um texto\"  \n"),
    "escapes": b(#"{"url": "http:\/\/exemplo.com\/a", "nome": "José 😀", "t": "a\tb\nc"}"#),
    "numeros": b(#"{"a": 1.50, "b": 1.5e3, "c": 2E+10, "d": -0.0, "e": 0, "f": 12345678901234567890, "g": [1, 2.0, 3e1]}"#),
    "repetida": b(#"{"a": 1, "b": 2, "a": 3}"#),
]

@Test(arguments: SuiteJSON.y + Array(jsonEspeciais.keys).sorted())
func jsonSemAlteracaoMesmosBytes(_ caso: String) throws {
    let bytes = jsonEspeciais[caso] ?? SuiteJSON.bytes(caso)
    var ed = Edicao(bytes, formato: .json)
    #expect(ed.documento != nil)
    #expect(try ed.resultado() == bytes)
    // definir o mesmo valor de cada campo não muda nada
    for e in ed.documento?.entradas ?? [] { try ed.definir(e.caminho, .valor(e.valor)) }
    #expect(ed.alteracoes.isEmpty)
    #expect(try ed.resultado() == bytes)
    #expect(!ed.temAlteracoes)
}

/// Confere que só o intervalo do valor mudou: tudo antes e depois fica igual, byte a byte.
private func soOTrechoMudouJSON(_ antes: [UInt8], _ depois: [UInt8], _ r: Range<Int>) -> Bool {
    let sufixo = antes.count - r.upperBound
    guard depois.count >= r.lowerBound + sufixo else { return false }
    return depois.prefix(r.lowerBound).elementsEqual(antes.prefix(r.lowerBound))
        && depois.suffix(sufixo).elementsEqual(antes.suffix(sufixo))
}

@Test(arguments: SuiteJSON.y + Array(jsonEspeciais.keys).sorted())
func jsonMudarCadaValor(_ caso: String) throws {
    let bytes = jsonEspeciais[caso] ?? SuiteJSON.bytes(caso)
    let doc = try LeitorJSON.ler(bytes)
    for e in doc.entradas {
        guard let novo = mutado(e.valor), Formato.json.problema(novo) == nil else { continue }
        let saida = try Gravar.aplicar(doc, alteracoes: [e.caminho: .valor(novo)])
        #expect(soOTrechoMudouJSON(bytes, saida, e.intervalo), "\(caso) \(e.caminho.texto)")
        let relido = try LeitorJSON.ler(saida)
        #expect(relido.valorRaiz.valor(em: e.caminho) == novo, "\(caso) \(e.caminho.texto)")
        #expect(relido.usaExtensoesJSONC == doc.usaExtensoesJSONC, "\(caso): o dialeto não pode mudar")
        #expect(relido.temBOM == doc.temBOM && relido.quebraDeLinha == doc.quebraDeLinha)
    }
}

// MARK: - tsconfig.json com comentários e vírgula final

@Test func tsconfigLidoComComentarios() throws {
    let doc = try LeitorJSON.ler(SuiteJSON.fixture("tsconfig.json"))
    #expect(doc.usaExtensoesJSONC)
    #expect(doc.nomeFormato == "JSONC")
    #expect(throws: ErroLeitura.self) { try LeitorJSON.ler(SuiteJSON.fixture("tsconfig.json"), estrito: true) }

    let secoes = Campos.secoes(doc)
    #expect(secoes.map(\.titulo) == ["Raiz", "compilerOptions", "compilerOptions.paths"])
    #expect(secoes[0].campos.map(\.rotulo) == ["include", "exclude"])
    #expect(secoes[1].ajuda == "Visit https://aka.ms/tsconfig to read more about this file")
    #expect(secoes[2].campos.map(\.rotulo) == ["@/*", "~utils/*"])

    let campos = Dictionary(uniqueKeysWithValues: secoes.flatMap(\.campos).map { ($0.id, $0) })
    let alvo = try #require(campos["compilerOptions.target"])
    #expect(alvo.tipo == .escolha(["es2017", "es2020", "es2022", "esnext"]))
    #expect(alvo.ajuda == "Language and Environment\nes2017 | es2020 | es2022 | esnext")
    #expect(campos["compilerOptions.module"]?.ajuda == "Modules")
    #expect(campos["compilerOptions.skipLibCheck"]?.ajuda == "acelera o build")
    #expect(campos["compilerOptions.lib"]?.tipo == .lista(.texto))
    #expect(campos["compilerOptions.strict"]?.tipo == .booleano)
    #expect(campos["compilerOptions.maxNodeModuleJsDepth"]?.tipo == .inteiro)
    #expect(campos["include"]?.linha == 30)
}

@Test func tsconfigAlterarMudaSoOTrecho() throws {
    let original = SuiteJSON.fixture("tsconfig.json")
    var ed = Edicao(original, formato: .json)
    try ed.definir(k("compilerOptions", "target"), .valor(.texto("esnext")))
    try ed.definir(k("compilerOptions", "strict"), .valor(.booleano(false)))
    try ed.definir(k("include"), .valor(.lista([.texto("src/**/*.ts"), .texto("src/**/*.tsx"), .texto("tests/**/*.ts")])))
    try ed.definir(k("compilerOptions", "paths", "@/*"), .valor(.lista([.texto("./app/*")])))
    let saida = try ed.resultado()
    let esperado = s(original)
        .replacingOccurrences(of: #""target": "es2022""#, with: #""target": "esnext""#)
        .replacingOccurrences(of: #""strict": true"#, with: #""strict": false"#)
        .replacingOccurrences(of: "    \"src/**/*.tsx\",\n", with: "    \"src/**/*.tsx\",\n    \"tests/**/*.ts\",\n")
        .replacingOccurrences(of: #""@/*": ["./src/*"]"#, with: #""@/*": ["./app/*"]"#)
    #expect(s(saida) == esperado)
    let difs = Diferenca.linhas(original, saida)
    #expect(difs.count == 4)
    // os comentários e as vírgulas finais continuam lá
    #expect(s(saida).contains("// es2017 | es2020 | es2022 | esnext"))
    #expect(s(saida).contains("\"skipLibCheck\": true, // acelera o build\n  },"))
}

@Test func tsconfigDesfazerVoltaAoOriginal() throws {
    let original = SuiteJSON.fixture("tsconfig.json")
    var ed = Edicao(original, formato: .json)
    try ed.definir(k("compilerOptions", "outDir"), .valor(.texto("./build")))
    #expect(ed.temAlteracoes)
    try ed.definir(k("compilerOptions", "outDir"), .valor(.texto("./dist")))
    #expect(!ed.temAlteracoes)
    #expect(try ed.resultado() == original)
}

// MARK: - Textos: aspas e escapes do original

@Test func textoMantemEscapes() throws {
    let t = #"{"url": "http:\/\/exemplo.com\/a", "nome": "José", "x": "Olá"}"#
    #expect(try troca(t, k("url"), .texto("http://exemplo.com/b/c")) == #"{"url": "http:\/\/exemplo.com\/b\/c", "nome": "José", "x": "Olá"}"#)
    #expect(try troca(t, k("nome"), .texto("José Ação")) == #"{"url": "http:\/\/exemplo.com\/a", "nome": "José Ação", "x": "Olá"}"#)
    #expect(try troca(t, k("x"), .texto("Olá 😀")) == #"{"url": "http:\/\/exemplo.com\/a", "nome": "José", "x": "Olá 😀"}"#)
    // texto sem pista de estilo, num arquivo que só tem ASCII e escapa o não-ASCII
    #expect(try troca(#"{"a": "x", "b": "é"}"#, k("a"), .texto("ç")) == #"{"a": "ç", "b": "é"}"#)
    // arquivo com acentos diretos: acentos diretos
    #expect(try troca(#"{"a": "x", "b": "é"}"#, k("a"), .texto("ç")) == #"{"a": "ç", "b": "é"}"#)
    // aspas, barra invertida, quebra e controle sempre escapados
    #expect(try troca(#"{"a": ""}"#, k("a"), .texto("a\"b\\c\nd\u{1}")) == #"{"a": "a\"b\\c\nd\u0001"}"#)
    // começo e fim iguais ficam como estavam, mesmo escritos de outro jeito
    #expect(try troca(#"{"a": "ABC\tfim"}"#, k("a"), .texto("ABX\tfim")) == #"{"a": "ABX\tfim"}"#)
}

@Test func numeroMantemForma() throws {
    let t = #"{"a": 1.50, "b": 1.5e3, "c": 2E+10, "d": -0.5, "e": 7, "f": 1e-7}"#
    #expect(try troca(t, k("a"), .decimal(2.5)).contains(#""a": 2.50,"#))
    #expect(try troca(t, k("a"), .decimal(0.125)).contains(#""a": 0.125,"#))
    #expect(try troca(t, k("b"), .decimal(2000)).contains(#""b": 2.0e3,"#))
    #expect(try troca(t, k("b"), .decimal(0.00025)).contains(#""b": 2.5e-4,"#))
    #expect(try troca(t, k("c"), .decimal(3e12)).contains(#""c": 3E+12,"#))
    #expect(try troca(t, k("d"), .decimal(3)).contains(#""d": 3.0,"#))
    #expect(try troca(t, k("e"), .inteiro(-42)).contains(#""e": -42,"#))
    #expect(try troca(t, k("f"), .decimal(2e-7)).contains(#""f": 2e-7}"#))
    // decimal sempre continua decimal ao reler
    #expect(FormatarJSON.decimal(1e21, estilo: "0.5") == "1e21")
    #expect(FormatarJSON.decimal(100, estilo: nil) == "100.0")
    #expect(FormatarJSON.decimal(-0.0, estilo: nil) == "-0.0")
    // JSON não tem infinito nem NaN
    #expect(throws: ErroGravar.self) { try troca(t, k("a"), .decimal(.infinity)) }
}

// MARK: - Estrutura

@Test func chaveRepetidaValeAUltima() throws {
    let t = #"{"a": 1, "b": 2, "a": 3}"#
    let doc = try LeitorJSON.ler(t)
    #expect(doc.raiz["a"] == .inteiro(3))
    #expect(doc.raiz.pares.map(\.chave) == ["a", "b"])
    #expect(doc.entradas.map(\.caminho.texto) == ["b", "a"])
    #expect(try troca(t, k("a"), .inteiro(9)) == #"{"a": 1, "b": 2, "a": 9}"#)
}

@Test func raizListaDeObjetosViraSecoes() throws {
    let doc = try LeitorJSON.ler(jsonEspeciais["raiz-lista"]!)
    let secoes = Campos.secoes(doc)
    #expect(secoes.map(\.titulo) == ["a", "b"])
    #expect(secoes.map(\.grupo) == ["(raiz)", "(raiz)"])
    #expect(secoes[1].campos.map(\.caminho.texto) == ["[1].nome", "[1].n"])
    #expect(s(try Gravar.aplicar(doc, alteracoes: [[.indice(1), .chave("n")]: .valor(.inteiro(5))]))
            == "[\n  {\"nome\": \"a\", \"n\": 1},\n  {\"nome\": \"b\", \"n\": 5}\n]\n")
}

@Test func raizEscalarEditavel() throws {
    let t = "  \"só um texto\"  \n"
    #expect(try troca(t, [], .texto("outro")) == "  \"outro\"  \n")
    let doc = try LeitorJSON.ler(t)
    #expect(Campos.secoes(doc).first?.campos.map(\.rotulo) == ["(raiz)"])
}

@Test func nuloECruEmJSON() throws {
    let t = "{\n  \"a\": null,\n  \"b\": [1, \"x\"]\n}\n"
    var ed = Edicao(b(t), formato: .json)
    let doc = try #require(ed.documento)
    #expect(Campos.tipo(doc.entrada(k("a"))!) == .cru)
    #expect(Campos.tipo(doc.entrada(k("b"))!) == .cru)
    try ed.definir(k("a"), .cru(#"{"x": 1}"#))
    try ed.definir(k("b"), .cru("[\n    2\n  ]"))
    #expect(s(try ed.resultado()) == "{\n  \"a\": {\"x\": 1},\n  \"b\": [\n    2\n  ]\n}\n")
    #expect(throws: ErroGravar.self) { try ed.definir(k("a"), .cru("{x: 1}")) }
}

@Test func jsonPuroContinuaPuro() throws {
    let t = "{\n  \"a\": [1, 2]\n}\n"
    // valor cru com comentário tornaria o arquivo JSONC: recusado na gravação
    #expect(throws: ErroGravar.self) {
        try Gravar.aplicar(b(t), alteracoes: [k("a"): .cru("[1, 2, /* três */ 3]")], formato: .json)
    }
    // já JSONC: pode
    let c = "{\n  // c\n  \"a\": [1, 2]\n}\n"
    #expect(s(try Gravar.aplicar(b(c), alteracoes: [k("a"): .cru("[1, /* x */ 3]")], formato: .json))
            == "{\n  // c\n  \"a\": [1, /* x */ 3]\n}\n")
}

@Test func listaDeVariasLinhasJSONC() throws {
    let t = "{\n  \"l\": [\n    1, // um\n    2,\n  ],\n}\n"
    // mesma quantidade de itens: só o item muda, o comentário fica
    #expect(try troca(t, k("l"), .lista([.inteiro(1), .inteiro(5)])) == "{\n  \"l\": [\n    1, // um\n    5,\n  ],\n}\n")
    // mais itens: reescrita com o recuo do primeiro e a vírgula final
    #expect(try troca(t, k("l"), .lista([.inteiro(1), .inteiro(2), .inteiro(3)]))
            == "{\n  \"l\": [\n    1,\n    2,\n    3,\n  ],\n}\n")
    // sem vírgula final no original: nenhuma é acrescentada
    let p = "{\n  \"l\": [\n    1,\n    2\n  ]\n}\n"
    #expect(try troca(p, k("l"), .lista([.inteiro(1)])) == "{\n  \"l\": [\n    1\n  ]\n}\n")
}

@Test func comentarioDeBlocoComoAjudaEEscolha() throws {
    let t = """
    {
      /* Nível de log
       * debug | info | erro
       */
      "log": "info",

      // separado por linha em branco: não é ajuda de "b"

      "b": 1
    }
    """
    let doc = try LeitorJSON.ler(t)
    let e = try #require(doc.entrada(k("log")))
    #expect(e.comentarioAcima == ["Nível de log", "debug | info | erro"])
    #expect(Campos.tipo(e) == .escolha(["debug", "info", "erro"]))
    #expect(doc.entrada(k("b"))?.comentarioAcima == [])
}

@Test func errosComLinhaEColuna() {
    do {
        _ = try LeitorJSON.ler("{\n  \"a\": 1,\n  \"b\" 2\n}")
        Issue.record("deveria recusar")
    } catch {
        #expect(error.linha == 3 && error.coluna == 7)
        #expect(error.formato == .json)
        #expect(error.localizedDescription.hasPrefix("JSON inválido"))
    }
    #expect(throws: ErroLeitura.self) { try LeitorJSON.ler("{\"a\": 1,}", estrito: true) }
    #expect(throws: ErroLeitura.self) { try LeitorJSON.ler("{'a': 1}") }
    #expect(throws: ErroLeitura.self) { try LeitorJSON.ler("/* sem fim") }
    #expect(throws: ErroLeitura.self) { try LeitorJSON.ler("") }
}

@Test func edicaoTrocarTextoJSON() throws {
    var ed = Edicao(b("{\"a\": 1}"), formato: .json)
    #expect(throws: ErroLeitura.self) { try ed.trocarTexto(b("{\"a\": }")) }
    try ed.trocarTexto(b("{\"a\": 2, \"b\": true}"))
    #expect(ed.valor(k("b")) == .booleano(true))
    #expect(ed.temAlteracoes)
}

@Test func formatoPelaExtensao() {
    #expect(Formato(extensao: "json") == .json)
    #expect(Formato(extensao: "JSONC") == .json)
    #expect(Formato(extensao: "toml") == .toml)
    #expect(Formato(extensao: "yaml") == nil)
}

// MARK: - exemplos/config.jsonc

@Test func exemploJSONC() throws {
    let raiz = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let original = Array(try Data(contentsOf: raiz.appendingPathComponent("exemplos/config.jsonc")))
    let doc = try LeitorJSON.ler(original)
    let secoes = Campos.secoes(doc)
    #expect(secoes.map(\.titulo) == ["Raiz", "servidor", "banco", "backup", "tarefas[0].ambiente", "limpar-logs"])
    #expect(secoes.map(\.id) == ["raiz", "servidor", "banco", "tarefas[0]", "tarefas[0].ambiente", "tarefas[1]"])
    let campos = Dictionary(uniqueKeysWithValues: secoes.flatMap(\.campos).map { ($0.id, $0) })
    #expect(campos["servidor.nivel_log"]?.tipo == .escolha(["debug", "info", "aviso", "erro"]))
    #expect(campos["banco.driver"]?.tipo == .escolha(["firebird", "postgres"]))
    #expect(campos["banco.fator"]?.tipo == .decimal)
    #expect(campos["banco.senha_arquivo"]?.tipo == .cru)
    #expect(campos["titulo"]?.ajuda == "Nome que aparece no topo")

    var ed = Edicao(original, formato: .json)
    try ed.definir(k("banco", "pool"), .valor(.inteiro(20)))
    try ed.definir(k("banco", "fator"), .valor(.decimal(2.25)))
    try ed.definir([.chave("tarefas"), .indice(0), .chave("ambiente"), .chave("DESTINO")], .valor(.texto("/srv/backup")))
    let r = s(try ed.resultado())
    #expect(r == s(original).replacingOccurrences(of: "\"pool\": 12,", with: "\"pool\": 20,")
        .replacingOccurrences(of: "\"fator\": 1.50,", with: "\"fator\": 2.25,")
        .replacingOccurrences(of: #""\/mnt\/backup""#, with: #""\/srv\/backup""#))
}
