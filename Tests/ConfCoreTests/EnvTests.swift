import Foundation
import Testing
@testable import ConfCore
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func k(_ c: String) -> Caminho { [.chave(c)] }

/// Aplica uma alteração num .env e devolve o texto novo.
private func troca(_ texto: String, _ chave: String, _ v: String) throws -> String {
    s(try Gravar.aplicar(b(texto), alteracoes: [k(chave): .valor(.texto(v))], formato: .env))
}

private func valores(_ doc: DocumentoConf) -> [String: String] {
    var r: [String: String] = [:]
    for e in doc.entradas { if case .texto(let t) = e.valor { r[e.chaveEscrita] = t } }
    return r
}

enum FixturesEnv {
    static let pasta = Suite.pasta.appendingPathComponent("env")
    static let todos: [String] = (try? FileManager.default.contentsOfDirectory(atPath: pasta.path))?
        .filter { $0.hasSuffix(".env") }.sorted() ?? []
    static func bytes(_ nome: String) -> [UInt8] {
        Array(try! Data(contentsOf: pasta.appendingPathComponent(nome)))
    }
}

private let raizProjeto = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

// MARK: - Regras de leitura

@Test func envTemAsFixtures() {
    #expect(FixturesEnv.todos == ["aspas.env", "basico.env", "bom.env", "crlf.env"])
}

@Test func envRegrasBasicas() throws {
    let doc = try LeitorEnv.ler(FixturesEnv.bytes("basico.env"))
    let v = valores(doc)
    #expect(v["APP_NOME"] == "km-conf")
    #expect(v["APP_PORTA"] == "8080", "export na frente")
    #expect(v["INDENTADA"] == "sim")
    #expect(v["ESPACOS_NO_IGUAL"] == "valor com espacos", "espaços nas pontas não contam")
    #expect(v["VAZIA"] == "")
    #expect(v["VAZIA_COM_COMENTARIO"] == "")
    #expect(v["COM_COMENTARIO"] == "abc")
    #expect(v["CERQUILHA_COLADA"] == "abc", "sem aspas, # começa comentário mesmo colado (como dotenv)")
    #expect(v["NIVEL_LOG"] == "info")
    #expect(v["modo.ponto-e-traco_1"] == "ok")
    #expect(v["export"] == "variavel chamada export")
    #expect(v["URL"] == "postgres://u:p@localhost:5432/db?ssl=true&x=1")
    #expect(v["IGUAL_NO_VALOR"] == "a=b=c")
    #expect(v["APOSTROFO_NO_MEIO"] == "it's")
    #expect(doc.entradas.count == 14)
    #expect(doc.cabecalhos.isEmpty)
    #expect(doc.quebraDeLinha == "\n" && !doc.temBOM)

    let e = doc.entrada(k("APP_NOME"))!
    #expect(e.comentarioAcima == ["Nome do app"], "linha em branco separa o comentário do arquivo")
    #expect(doc.entrada(k("COM_COMENTARIO"))?.comentarioFim == "comentário no fim")
    #expect(doc.entrada(k("CERQUILHA_COLADA"))?.comentarioFim == "def")
    #expect(doc.entrada(k("APP_PORTA"))?.comentarioAcima == [])
    #expect(doc.entrada(k("APP_PORTA"))?.chaveEscrita == "APP_PORTA")
    #expect(doc.texto(doc.entrada(k("ESPACOS_NO_IGUAL"))!.intervalo) == "valor com espacos")
}

@Test func envRegrasDeAspas() throws {
    let doc = try LeitorEnv.ler(FixturesEnv.bytes("aspas.env"))
    let v = valores(doc)
    #expect(v["SIMPLES"] == #"literal \n sem escape"#)
    #expect(v["SIMPLES_COM_HASH"] == "a # b")
    #expect(doc.entrada(k("SIMPLES_COM_HASH"))?.comentarioFim == "comentário depois")
    #expect(v["DUPLAS"] == "linha1\nlinha2")
    #expect(v["DUPLAS_ESCAPES"] == "aspas \" e barra \\ e cr \r fim")
    #expect(v["BARRA_DESCONHECIDA"] == #"c:\pasta\dados"#, "barra que não é escape fica")
    #expect(v["EXPANSAO"] == "${HOME}/bin e $USER", "sem expansão")
    #expect(v["EXPANSAO_SEM_ASPAS"] == "${HOME}/bin")
    #expect(v["HASH_DENTRO"] == "senha#123")
    #expect(v["VAZIA_DUPLAS"] == "" && v["VAZIA_SIMPLES"] == "")
    #expect(v["ESPACOS_DENTRO"] == "  com espaços  ")
    #expect(v["ACENTOS"] == "ação 😀")
    #expect(v["VARIAS_LINHAS"] == "primeira\nsegunda\nterceira")
    #expect(v["VARIAS_SIMPLES"] == "-----BEGIN-----\nabc\n-----END-----")
    #expect(v["CRASE"] == "`texto`", "crase não é aspas")
    #expect(v["DEPOIS"] == "fim")
    let multi = doc.entrada(k("VARIAS_LINHAS"))!
    #expect(multi.linhaFinal == multi.linha + 2)
    #expect(doc.entrada(k("DEPOIS"))?.linha == 20)
}

@Test func envCRLFeBOM() throws {
    let crlf = try LeitorEnv.ler(FixturesEnv.bytes("crlf.env"))
    #expect(crlf.quebraDeLinha == "\r\n")
    #expect(valores(crlf) == ["A": "1", "B": "dois\npartes", "C": "tres", "MULTI": "x\ny", "D": "4"])
    #expect(crlf.entrada(k("B"))?.comentarioAcima == ["ajuda de B"])
    #expect(crlf.entrada(k("B"))?.comentarioFim == "fim")
    #expect(crlf.entrada(k("A"))?.comentarioAcima == ["comentário"])
    let bom = try LeitorEnv.ler(FixturesEnv.bytes("bom.env"))
    #expect(bom.temBOM)
    #expect(valores(bom) == ["NOME": "ação", "VAZIA": "", "ULTIMA": "sem quebra final"])
    #expect(bom.entrada(k("NOME"))?.comentarioAcima == ["com BOM"])
}

@Test func envEscolhaPeloComentario() throws {
    let doc = try LeitorEnv.ler(FixturesEnv.bytes("basico.env"))
    let secoes = Campos.secoes(doc)
    #expect(secoes.count == 1)
    #expect(secoes[0].titulo == "Variáveis")
    let campos = Dictionary(uniqueKeysWithValues: secoes[0].campos.map { ($0.id, $0) })
    #expect(campos["NIVEL_LOG"]?.tipo == .escolha(["debug", "info", "aviso", "erro"]))
    #expect(campos["NIVEL_LOG"]?.ajuda == "nível do log\ndebug | info | aviso | erro")
    #expect(campos["APP_PORTA"]?.tipo == .texto, "em .env tudo é texto")
}

@Test(arguments: [
    ("A", 1, 2, "falta '='"),
    ("=1", 1, 1, "nome de uma variável"),
    ("A 1", 1, 3, "esperava '='"),
    ("A=1\nB=\"aberta\nC=3\n", 2, 3, "nunca fechadas"),
    ("A='x\n", 1, 3, "nunca fechadas"),
    ("A=\"x\" y\n", 1, 7, "depois das aspas"),
    ("A=1\n\nA=2\n", 3, 1, "linha 1"),
    ("export A\n", 1, 9, "falta '='"),
    ("A=1\rB=2\n", 1, 4, "CR sozinho"),
    ("ÇÃO=1\n", 1, 1, "nome de uma variável"),
])
func envErrosComLinhaEColuna(_ caso: (String, Int, Int, String)) {
    do {
        let doc = try LeitorEnv.ler(caso.0)
        Issue.record("aceitou \(caso.0.debugDescription): \(valores(doc))")
    } catch {
        #expect(error.linha == caso.1 && error.coluna == caso.2, "\(caso.0.debugDescription): \(error)")
        #expect(error.mensagem.contains(caso.3), "\(error)")
        #expect(error.formato == .env)
    }
}

@Test func envUTF8Invalido() {
    #expect(throws: ErroLeitura.self) { try LeitorEnv.ler([0x41, 0x3D, 0xE7, 0x0A]) }
}

@Test func envLerValor() throws {
    #expect(try LeitorEnv.lerValor("abc") == .texto("abc"))
    #expect(try LeitorEnv.lerValor(#""a\nb""#) == .texto("a\nb"))
    #expect(try LeitorEnv.lerValor("'x y'") == .texto("x y"))
    #expect(throws: ErroLeitura.self) { try LeitorEnv.lerValor("abc # x") }
    #expect(throws: ErroLeitura.self) { try LeitorEnv.lerValor("\"abc") }
}

// MARK: - Formato pelo nome do arquivo

@Test func formatoPeloNome() {
    #expect(Formato(nomeArquivo: ".env") == .env)
    #expect(Formato(nomeArquivo: ".env.local") == .env)
    #expect(Formato(nomeArquivo: ".env.production") == .env)
    #expect(Formato(nomeArquivo: "producao.env") == .env)
    #expect(Formato(nomeArquivo: "PRODUCAO.ENV") == .env)
    #expect(Formato(nomeArquivo: "config.toml") == .toml)
    #expect(Formato(nomeArquivo: "tsconfig.json") == .json)
    #expect(Formato(nomeArquivo: "a.jsonc") == .json)
    #expect(Formato(nomeArquivo: "environment.txt") == nil)
    #expect(Formato(nomeArquivo: "leiame") == nil)
    #expect(Formato(nomeArquivo: ".envrc") == nil)
}

/// O que o macOS devolve para os nomes de `.env`: por isso o formato vem do nome, não só da extensão.
@Test func extensaoDoSistemaParaArquivosEnv() throws {
    #expect(URL(fileURLWithPath: "/tmp/.env").pathExtension == "")
    #expect(URL(fileURLWithPath: "/tmp/.env.local").pathExtension == "local")
    #expect(URL(fileURLWithPath: "/tmp/producao.env").pathExtension == "env")
    #if os(macOS)
    // Tipo de arquivo que o sistema dá (sem o km-conf registrado): `.env` é "dados" genéricos.
    let pasta = FileManager.default.temporaryDirectory.appendingPathComponent("km-conf-env-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: pasta) }
    var tipos: [String: String] = [:]
    for n in [".env", ".env.local", "producao.env"] {
        let u = pasta.appendingPathComponent(n)
        try Data("A=1\n".utf8).write(to: u)
        tipos[n] = try u.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier ?? "-"
    }
    #expect(tipos[".env"] == "public.data", "\(tipos)")
    #expect(tipos[".env.local"]?.hasPrefix("dyn.") == true || tipos[".env.local"] == "br.com.kogut.km-conf.env",
            "\(tipos)")
    #endif
}

// MARK: - Gravar: aspas e estilo

@Test func envGravarMantemAspas() throws {
    // sem aspas continua sem aspas quando cabe
    #expect(try troca("A=1\n", "A", "2") == "A=2\n")
    #expect(try troca("A=x # c\n", "A", "y") == "A=y # c\n")
    // não cabe sem aspas: duplas
    #expect(try troca("A=x # c\n", "A", "com espaço") == "A=\"com espaço\" # c\n")
    #expect(try troca("A=x\n", "A", "a#b") == "A=\"a#b\"\n")
    #expect(try troca("A=x\n", "A", "diz \"oi\"") == #"A="diz \"oi\"""# + "\n")
    #expect(try troca("A=x\n", "A", "it's") == "A=\"it's\"\n")
    #expect(try troca("A=x\n", "A", "a\nb") == #"A="a\nb""# + "\n")
    // vazio
    #expect(try troca("A=\n", "A", "v") == "A=v\n")
    #expect(try troca("A=   # c\n", "A", "v") == "A=v   # c\n")
    #expect(try troca("A=x # c\n", "A", "") == "A= # c\n")
    #expect(try troca("A=x\n", "A", "") == "A=\n")
    // simples continua simples; não cabe ('), vira duplas
    #expect(try troca("A='x'\n", "A", "y z") == "A='y z'\n")
    #expect(try troca("A='x'\n", "A", "a\\nb") == "A='a\\nb'\n")
    #expect(try troca("A='x'\n", "A", "it's") == "A=\"it's\"\n")
    #expect(try troca("A='x'\n", "A", "a\nb") == #"A="a\nb""# + "\n")
    // simples de várias linhas continua de várias linhas, com a quebra do arquivo
    #expect(try troca("A='x\r\ny'\r\n", "A", "x\ny\nz") == "A='x\r\ny\r\nz'\r\n")
    // duplas continuam duplas, escapando só o necessário
    #expect(try troca("A=\"x\"\n", "A", "y") == "A=\"y\"\n")
    #expect(try troca("A=\"x\"\n", "A", "c:\\dir") == #"A="c:\\dir""# + "\n")
    // duplas: começo e fim iguais copiados do original (escapes e barras desconhecidas inclusive)
    #expect(try troca(#"A="a\nb fim\"""# + "\n", "A", "a\nb meio fim\"") == #"A="a\nb meio fim\"""# + "\n")
    #expect(try troca(#"A="c:\pasta""# + "\n", "A", #"c:\outra"#) == #"A="c:\\outra""# + "\n")
    // export e comentário ficam
    #expect(try troca("export A=1 # c\n", "A", "2") == "export A=2 # c\n")
}

@Test func envSoTextoEhAceito() {
    var ed = Edicao(b("A=1\n"), formato: .env)
    #expect(throws: ErroGravar.self) { try ed.definir(k("A"), .valor(.inteiro(2))) }
    #expect(throws: ErroGravar.self) { try ed.definir(k("A"), .valor(.nulo)) }
    #expect(throws: ErroGravar.self) { try ed.definir(k("A"), .cru("x # y")) }
}

@Test func envEdicaoTrocarTexto() throws {
    var ed = Edicao(b("A=1\n"), formato: .env)
    #expect(throws: ErroLeitura.self) { try ed.trocarTexto(b("A=1\nB\n")) }
    try ed.trocarTexto(b("A=1\nB=2\n"))
    #expect(ed.documento?.entradas.count == 2)
}

// MARK: - Ida e volta e "só o trecho" (os mesmos testes do TOML em GravarTests)

private let envEspeciais: [String: [UInt8]] = [
    "vazio": [],
    "so-comentarios": b("# nada\n\n# aqui\n"),
    "sem-quebra-final": b("A=1\nB='dois'"),
    "crlf-bom-aspas": [0xEF, 0xBB, 0xBF] + b("# c\r\nA=\"x\\ny\" # z\r\n\r\nexport B='q'\r\nC=\r\n"),
    "indentado": b("  A = 1\n\tB=\t\"2\"\t# c\n"),
]

private func casoEnv(_ nome: String) -> [UInt8] {
    if let x = envEspeciais[nome] { return x }
    if nome == "exemplos/.env" { return Array(try! Data(contentsOf: raizProjeto.appendingPathComponent(nome))) }
    return FixturesEnv.bytes(nome)
}

private let casosEnv = FixturesEnv.todos + Array(envEspeciais.keys).sorted() + ["exemplos/.env"]

@Test(arguments: casosEnv)
func envSemAlteracaoMesmosBytes(_ caso: String) throws {
    let original = casoEnv(caso)
    var ed = Edicao(original, formato: .env)
    #expect(ed.erro == nil, "\(String(describing: ed.erro))")
    #expect(try ed.resultado() == original)
    #expect(!ed.temAlteracoes)
    for e in ed.documento?.entradas ?? [] {
        try ed.definir(e.caminho, .valor(e.valor))
        try ed.definir(e.caminho, .cru(ed.documento!.texto(e.intervalo)))
    }
    #expect(ed.alteracoes.isEmpty)
    #expect(try ed.resultado() == original)
}

@Test(arguments: casosEnv)
func envMudarCadaValor(_ caso: String) throws {
    let original = casoEnv(caso)
    let doc = try LeitorEnv.ler(original)
    for e in doc.entradas {
        guard case .texto(let t) = e.valor else { Issue.record("valor que não é texto"); continue }
        // três mudanças: cabe sem aspas, precisa de aspas e várias linhas
        for novo in [t + "x", t + " x'\"#$\\", "linha1\nlinha2" + t] {
            let saida: [UInt8]
            do { saida = try Gravar.aplicar(original, alteracoes: [e.caminho: .valor(.texto(novo))], formato: .env) } catch {
                Issue.record("\(caso) \(e.chaveEscrita): \(error)")
                continue
            }
            #expect(soOTrechoMudou(original, saida, e.intervalo), "\(caso) \(e.chaveEscrita): mudou fora do trecho")
            let relido = try LeitorEnv.ler(saida)
            #expect(relido.raiz == doc.raiz.substituindo(e.caminho, por: .texto(novo))!, "\(caso) \(e.chaveEscrita)")
            #expect(relido.entradas.map(\.comentarioFim) == doc.entradas.map(\.comentarioFim))
            #expect(relido.temBOM == doc.temBOM && relido.quebraDeLinha == doc.quebraDeLinha)
            // o tipo de aspas se mantém quando o valor cabe nele
            let antes = doc.bytes[e.intervalo].first, depois = relido.entrada(e.caminho).map { relido.bytes[$0.intervalo].first }
            if novo == t + "x", antes == 0x22 || antes == 0x27 { #expect(depois == antes, "\(caso) \(e.chaveEscrita)") }
        }
    }
}

// MARK: - Exemplo

@Test func exemploEnv() throws {
    let original = Array(try Data(contentsOf: raizProjeto.appendingPathComponent("exemplos/.env")))
    let doc = try LeitorEnv.ler(original)
    let campos = Dictionary(uniqueKeysWithValues: Campos.secoes(doc).flatMap(\.campos).map { ($0.id, $0) })
    #expect(campos["NIVEL_LOG"]?.tipo == .escolha(["debug", "info", "aviso", "erro"]))
    #expect(campos["BANCO_DRIVER"]?.tipo == .escolha(["firebird", "postgres"]))
    #expect(campos["APP_TITULO"]?.ajuda == "Nome que aparece no topo")
    #expect(campos["BANCO_POOL"]?.ajuda == "conexões simultâneas")
    #expect(campos["BACKUP_DESTINO"]?.valor == .texto("${HOME}/backup"))

    var ed = Edicao(original, formato: .env)
    try ed.definir(k("BANCO_POOL"), .valor(.texto("20")))
    try ed.definir(k("NIVEL_LOG"), .valor(.texto("aviso")))
    try ed.definir(k("APP_TITULO"), .valor(.texto("Painel Kogumelo 2")))
    try ed.definir(k("BANCO_SENHA"), .valor(.texto("nova senha")))
    let r = s(try ed.resultado())
    #expect(r == s(original).replacingOccurrences(of: "BANCO_POOL=12 ", with: "BANCO_POOL=20 ")
        .replacingOccurrences(of: "NIVEL_LOG=info", with: "NIVEL_LOG=aviso")
        .replacingOccurrences(of: "\"Painel Kogumelo\"", with: "\"Painel Kogumelo 2\"")
        .replacingOccurrences(of: "\"troque#esta senha\"", with: "\"nova senha\""))
    #expect(Diferenca.linhas(original, b(r)).count == 4)
}

// MARK: - JSON: recuos variados (critério de ida e volta)

@Test(arguments: [
    "{\n  \"a\": 1,\n  \"b\": [1, 2],\n  \"c\": {\"d\": \"x\"}\n}\n",
    "{\n    \"a\": 1,\n    \"b\": [\n        1,\n        2\n    ],\n    \"c\": {\n        \"d\": \"x\"\n    }\n}\n",
    "{\n\t\"a\": 1,\n\t\"b\": [\n\t\t1,\n\t\t2\n\t],\n\t\"c\": {\n\t\t\"d\": \"x\"\n\t}\n}",
    "{\"a\":1,\"b\":[1,2],\"c\":{\"d\":\"x\"}}",
    "{\r\n    \"a\": 1,\r\n    \"b\": [\r\n        1,\r\n        2\r\n    ],\r\n    \"c\": {\"d\": \"x\"}\r\n}\r\n",
])
func jsonRecuosIdaEVolta(_ texto: String) throws {
    let original = b(texto)
    let ed = Edicao(original, formato: .json)
    #expect(try ed.resultado() == original)
    let doc = try LeitorJSON.ler(original)
    for e in doc.entradas {
        guard let novo = mutado(e.valor), Formato.json.problema(novo) == nil else { continue }
        let saida = try Gravar.aplicar(doc, alteracoes: [e.caminho: .valor(novo)])
        #expect(soOTrechoMudou(original, saida, e.intervalo), "\(e.caminho.texto)")
        #expect(try LeitorJSON.ler(saida).valorRaiz.valor(em: e.caminho) == novo)
    }
}

@Test func exemploJSON() throws {
    let original = Array(try Data(contentsOf: raizProjeto.appendingPathComponent("exemplos/config.json")))
    let doc = try LeitorJSON.ler(original, estrito: true)
    #expect(doc.nomeFormato == "JSON")
    var ed = Edicao(original, formato: .json)
    try ed.definir([.chave("banco"), .chave("pool")], .valor(.inteiro(20)))
    try ed.definir([.chave("banco"), .chave("fator")], .valor(.decimal(2)))
    try ed.definir([.chave("banco"), .chave("limite")], .valor(.decimal(2500)))
    let r = s(try ed.resultado())
    #expect(r == s(original).replacingOccurrences(of: "\"pool\": 12,", with: "\"pool\": 20,")
        .replacingOccurrences(of: "\"fator\": 1.50,", with: "\"fator\": 2.00,")
        .replacingOccurrences(of: "\"limite\": 1e3,", with: "\"limite\": 2.5e3,"))
}
