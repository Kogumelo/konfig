import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func k(_ chaves: String...) -> Caminho { chaves.map { .chave($0) } }

/// Aplica uma alteração num YAML e devolve o texto novo.
private func troca(_ texto: String, _ c: Caminho, _ v: Valor) throws -> String {
    s(try Gravar.aplicar(b(texto), alteracoes: [c: .valor(v)], formato: .yaml))
}

private let raizProjeto = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

// MARK: - Leitura

@Test func yamlFormatoPeloNome() {
    #expect(Formato(nomeArquivo: "docker-compose.yml") == .yaml)
    #expect(Formato(nomeArquivo: "config.YAML") == .yaml)
    #expect(Formato(nomeArquivo: "pubspec.yaml") == .yaml)
    #expect(Formato.yaml.nome == "YAML")
}

@Test func yamlCoreSchema() throws {
    let doc = try LeitorYAML.ler("""
        a: yes
        b: no
        c: on
        d: off
        e: true
        f: False
        g: ~
        h:
        i: null
        j: 0x1F
        k: 0o17
        l: 010
        m: 1e3
        n: .inf
        o: -.Inf
        p: .NaN
        q: +12
        r: 1_000
        s: 0b101
        t: 2024-01-31
        u: 12:30
        v: "true"
        w: '1'
        x: 1.
        y: .5

        """)
    let t = doc.raiz
    #expect(t["a"] == .texto("yes") && t["b"] == .texto("no") && t["c"] == .texto("on") && t["d"] == .texto("off"),
            "YAML 1.2: yes/no/on/off são texto")
    #expect(t["e"] == .booleano(true) && t["f"] == .booleano(false))
    #expect(t["g"] == .nulo && t["h"] == .nulo && t["i"] == .nulo)
    #expect(t["j"] == .inteiro(31) && t["k"] == .inteiro(15))
    #expect(t["l"] == .inteiro(10), "YAML 1.2: 010 é dez (no 1.1 seria octal)")
    #expect(t["m"] == .decimal(1000))
    #expect(t["n"] == .decimal(.infinity) && t["o"] == .decimal(-.infinity))
    if case .decimal(let d)? = t["p"] { #expect(d.isNaN) } else { Issue.record("p") }
    #expect(t["q"] == .inteiro(12))
    #expect(t["r"] == .texto("1_000") && t["s"] == .texto("0b101"), "fora do core schema: texto")
    #expect(t["t"] == .texto("2024-01-31") && t["u"] == .texto("12:30"), "sem datas nem sexagesimais no 1.2")
    #expect(t["v"] == .texto("true") && t["w"] == .texto("1"), "entre aspas é sempre texto")
    #expect(t["x"] == .decimal(1) && t["y"] == .decimal(0.5))
}

@Test func yamlSecoesNaTela() throws {
    let doc = try LeitorYAML.ler(Array(try Data(contentsOf: raizProjeto.appendingPathComponent("exemplos/config.yaml"))))
    let secoes = Campos.secoes(doc)
    #expect(secoes.map(\.id) == ["raiz", "services", "services.web", "services.web.environment", "services.web.healthcheck",
                                 "services.banco", "services.banco.environment", "tarefas[0]", "tarefas[1]"])
    #expect(secoes.first { $0.id == "tarefas[0]" }?.titulo == "backup")
    #expect(secoes.first { $0.id == "tarefas[1]" }?.grupo == "tarefas")
    let campos = Dictionary(uniqueKeysWithValues: secoes.flatMap(\.campos).map { ($0.id, $0) })
    #expect(campos["nivel_log"]?.tipo == .escolha(["debug", "info", "aviso", "erro"]))
    #expect(campos["nivel_log"]?.ajuda == "Nível de detalhe do log\ndebug | info | aviso | erro")
    #expect(campos["services.web.restart"]?.tipo == .escolha(["no", "always", "on-failure", "unless-stopped"]))
    #expect(campos["services.web.ports"]?.tipo == .lista(.texto))
    #expect(campos["services.web.command"]?.tipo == .lista(.texto), "lista em linha só de textos: etiquetas")
    #expect(campos["services.web.healthcheck.test"]?.valor == .lista([.texto("CMD"), .texto("curl"), .texto("-f"), .texto("http://localhost")]))
    #expect(campos["services.web.environment.PAIS"]?.valor == .texto("no"))
    #expect(campos["services.web.environment.DEBUG"]?.tipo == .booleano)
    #expect(campos["manutencao"]?.valor == .texto("O painel está em manutenção.\nVolte em alguns minutos.\n"))
    #expect(campos["pool"]?.tipo == .inteiro && campos["pool"]?.ajuda == "conexões simultâneas com o banco")
    #expect(campos["limite_mb"]?.tipo == .decimal)
    #expect(secoes.first { $0.id == "services.web" }?.ajuda == "Servidor web na frente do painel")
}

@Test func yamlListaEmLinhaMistaETabelaSaoTextoCru() throws {
    let doc = try LeitorYAML.ler("a: [1, x]\nb: {c: 1}\nc:\n  - 1\n  - [2]\nd:\n")
    let campos = Dictionary(uniqueKeysWithValues: Campos.secoes(doc).flatMap(\.campos).map { ($0.id, $0) })
    #expect(campos["a"]?.tipo == .cru && campos["b"]?.tipo == .cru && campos["c"]?.tipo == .cru && campos["d"]?.tipo == .cru)
    #expect(campos["b"]?.tipo.nome(em: .yaml) == "YAML")
}

@Test(arguments: [
    ("a: 1\na: 2\n", 2, "já apareceu"),
    ("a:\n\t- 1\n", 2, "tabulação"),
    ("a: 'x\n", 1, "aspas"),
    ("a: [1, 2\n", 1, "]"),
    ("a: b: c\n", 1, "mapa"),
    ("- a\nb: 1\n", 2, "inesperado"),
    ("a: \"\\q\"\n", 1, "escape"),
])
func yamlErros(_ caso: (String, Int, String)) {
    do {
        _ = try LeitorYAML.ler(caso.0)
        Issue.record("aceitou: \(caso.0)")
    } catch {
        #expect(!error.foraDoSubconjunto)
        #expect(error.linha == caso.1, "\(error)")
        #expect(error.mensagem.contains(caso.2), "\(error)")
    }
}

@Test(arguments: [
    ("base: &b {a: 1}\n", 1, "âncora"),
    ("a: 1\nb: *x\n", 2, "alias"),
    ("a:\n  <<: {b: 1}\n", 2, "mesclagem"),
    ("a: !Ref x\n", 1, "etiqueta"),
    ("a: !!str 1\n", 1, "etiqueta"),
    ("%YAML 1.2\n---\na: 1\n", 1, "diretiva"),
    ("a: 1\n---\nb: 2\n", 2, "mais de um documento"),
    ("a: 1\n...\nb: 2\n", 3, "mais de um documento"),
    ("? a\n: 1\n", 1, "chave complexa"),
    ("[a, b]: 1\n", 1, "chave complexa"),
    ("~: 1\n", 1, "chave nula"),
])
func yamlForaDoSubconjunto(_ caso: (String, Int, String)) {
    do {
        _ = try LeitorYAML.ler(caso.0)
        Issue.record("aceitou: \(caso.0)")
    } catch {
        #expect(error.foraDoSubconjunto, "\(error)")
        #expect(error.linha == caso.1, "\(error)")
        #expect(error.mensagem.contains(caso.2), "\(error)")
        #expect(error.errorDescription?.contains("fora do subconjunto") == true)
    }
}

@Test func yamlForaDoSubconjuntoAbreSoComoTexto() throws {
    let texto = b("defaults: &d\n  a: 1\nprod:\n  <<: *d\n  b: 2\n")
    var ed = Edicao(texto, formato: .yaml)
    #expect(ed.documento == nil && ed.somenteTexto)
    #expect(try ed.resultado() == texto, "sem alteração: os mesmos bytes")
    // o texto pode ser trocado por outro também fora do subconjunto (gravado como está)
    let novo = b("defaults: &d\n  a: 2\nprod:\n  <<: *d\n")
    try ed.trocarTexto(novo)
    #expect(try ed.resultado() == novo && ed.somenteTexto)
    // e por um dentro do subconjunto, que volta a abrir no formulário
    try ed.trocarTexto(b("a: 1\n"))
    #expect(ed.documento != nil && !ed.somenteTexto)
    // texto com erro de verdade continua recusado
    #expect(throws: ErroLeitura.self) { try ed.trocarTexto(b("a: [1\n")) }
    // os outros formatos não mudam: erro é erro
    var ini = Edicao(b("a = 1\n"), formato: .ini)
    #expect(throws: ErroLeitura.self) { try ini.trocarTexto(b("lixo\n")) }
}

@Test func yamlLerValor() throws {
    #expect(try LeitorYAML.lerValor("[1, a]") == .lista([.inteiro(1), .texto("a")]))
    #expect(try LeitorYAML.lerValor("{a: 1}") == .tabela(Tabela(pares: [.init(chave: "a", valor: .inteiro(1))])))
    #expect(try LeitorYAML.lerValor("'x'") == .texto("x"))
    #expect(try LeitorYAML.lerValor("") == .nulo)
    #expect(try LeitorYAML.lerValor("42") == .inteiro(42))
    // texto de uma lista em bloco como está no arquivo (com o recuo)
    #expect(try LeitorYAML.lerValor("  - a\n  - b") == .lista([.texto("a"), .texto("b")]))
    #expect(throws: ErroLeitura.self) { try LeitorYAML.lerValor("[1,") }
}

// MARK: - Aspas de proteção (YAML 1.1)

@Test(arguments: ["no", "No", "NO", "yes", "on", "off", "y", "n", "true", "False", "null", "~", "1e3", "010", "0x1F",
                  "0b11", "1_000", "12:30", "8080:80", "1.5", ".5", ".inf", "-.inf", ".nan", "2024-01-31", "<<", "=", ""])
func yamlAspasDeProtecao(_ texto: String) throws {
    // valor sem aspas no original: o texto novo que outro leitor entenderia como outro tipo ganha aspas
    let r = try troca("pais: br\n", k("pais"), .texto(texto))
    #expect(r == "pais: \"\(texto)\"\n", "\(texto) → \(r)")
    #expect(try LeitorYAML.ler(r).raiz["pais"] == .texto(texto))
}

@Test func yamlSemAspasQuandoCabe() throws {
    #expect(try troca("a: x\n", k("a"), .texto("Noruega")) == "a: Noruega\n")
    #expect(try troca("a: x\n", k("a"), .texto("nginx:1.28")) == "a: nginx:1.28\n")
    #expect(try troca("a: x\n", k("a"), .texto("http://x/#a")) == "a: http://x/#a\n")
    // precisa de aspas: ': ', ' #', começo especial, espaços nas pontas
    #expect(try troca("a: x\n", k("a"), .texto("a: b")) == "a: \"a: b\"\n")
    #expect(try troca("a: x\n", k("a"), .texto("a #b")) == "a: \"a #b\"\n")
    #expect(try troca("a: x\n", k("a"), .texto("*x")) == "a: \"*x\"\n")
    #expect(try troca("a: x\n", k("a"), .texto("- x")) == "a: \"- x\"\n")
    #expect(try troca("a: x\n", k("a"), .texto(" x")) == "a: \" x\"\n")
    #expect(try troca("a: x\n", k("a"), .texto("x\ny")) == "a: \"x\\ny\"\n")
    // o tipo de aspas se mantém
    #expect(try troca("a: 'x'\n", k("a"), .texto("it's")) == "a: 'it''s'\n")
    #expect(try troca("a: 'x'\n", k("a"), .texto("no")) == "a: 'no'\n")
    #expect(try troca("a: \"x\"\n", k("a"), .texto("y")) == "a: \"y\"\n")
    #expect(try troca("a: 'x'\n", k("a"), .texto("x\ny")) == "a: \"x\\ny\"\n")
    // valor vazio: `a: novo`, não `a:novo`
    #expect(try troca("a:\nb: 1\n", k("a"), .texto("novo")) == "a: novo\nb: 1\n")
    #expect(try troca("a: # nota\n", k("a"), .inteiro(3)) == "a: 3 # nota\n")
}

@Test func yamlNumerosMantemAForma() throws {
    #expect(try troca("a: 0x1F\n", k("a"), .inteiro(255)) == "a: 0xFF\n")
    #expect(try troca("a: 0o17\n", k("a"), .inteiro(8)) == "a: 0o10\n")
    #expect(try troca("a: +5\n", k("a"), .inteiro(6)) == "a: +6\n")
    #expect(try troca("a: 1.50\n", k("a"), .decimal(2.25)) == "a: 2.25\n")
    #expect(try troca("a: 1.5e3\n", k("a"), .decimal(2000)) == "a: 2.0e3\n")
    #expect(try troca("a: .Inf\n", k("a"), .decimal(-.infinity)) == "a: -.Inf\n")
    #expect(try troca("a: True\n", k("a"), .booleano(false)) == "a: False\n")
    #expect(try troca("a: 1\n", k("a"), .decimal(2.5)) == "a: 2.5\n")
    #expect(throws: ErroGravar.self) {
        try troca("a: 1\n", k("a"), .dataHora(DataHora(tipo: .data)))
    }
}

// MARK: - Listas em bloco

@Test func yamlListaCresce() throws {
    let texto = "portas:\n  - 80   # http\n  - \"443\"\nfim: 1\n"
    let r = try troca(texto, k("portas"), .lista([.inteiro(80), .texto("443"), .texto("8443")]))
    #expect(r == "portas:\n  - 80   # http\n  - \"443\"\n  - \"8443\"\nfim: 1\n")
    let d = Diferenca.linhas(b(texto), b(r))
    #expect(d.count == 1 && d[0].removidas.isEmpty && d[0].adicionadas == ["  - \"8443\""])
    // vários itens novos, recuo zero (lista no mesmo recuo da chave)
    let r2 = try troca("a:\n- x\nb: 2\n", k("a"), .lista([.texto("x"), .texto("w"), .texto("no")]))
    #expect(r2 == "a:\n- x\n- w\n- \"no\"\nb: 2\n", "'no' ganha aspas de proteção")
    // item novo de outro tipo
    let r3 = try troca("a:\n  - x\n", k("a"), .lista([.texto("x"), .inteiro(3)]))
    #expect(r3 == "a:\n  - x\n  - 3\n")
}

@Test func yamlListaEncolhe() throws {
    let texto = "l:\n  - a\n  # sobre b\n  - b\n  - c  # c\nfim: 1\n"
    #expect(try troca(texto, k("l"), .lista([.texto("a"), .texto("c")])) == "l:\n  - a\n  # sobre b\n  - c  # c\nfim: 1\n")
    #expect(try troca(texto, k("l"), .lista([.texto("b"), .texto("c")])) == "l:\n  # sobre b\n  - b\n  - c  # c\nfim: 1\n")
    #expect(try troca(texto, k("l"), .lista([.texto("a"), .texto("b")])) == "l:\n  - a\n  # sobre b\n  - b\nfim: 1\n")
    #expect(try troca(texto, k("l"), .lista([])) == "l:\n  []\nfim: 1\n")
    // trocar um item e tirar outro: o último sai, o primeiro muda no lugar
    #expect(try troca(texto, k("l"), .lista([.texto("A"), .texto("b")])) == "l:\n  - A\n  # sobre b\n  - b\nfim: 1\n")
}

@Test func yamlListaEmLinha() throws {
    #expect(try troca("a: [x, w]\n", k("a"), .lista([.texto("x"), .texto("w"), .texto("z w")])) == "a: [x, w, z w]\n")
    #expect(try troca("a: [x, w]\n", k("a"), .lista([.texto("x"), .texto("a,b")])) == "a: [x, \"a,b\"]\n")
    #expect(try troca("a: ['x', \"w\"]\n", k("a"), .lista([.texto("x2"), .texto("w")])) == "a: ['x2', \"w\"]\n")
    #expect(try troca("a: {b, c: 1}\n", k("a"), .tabela(Tabela(pares: [.init(chave: "b", valor: .nulo)]))) == "a: {b: null}\n")
    #expect(try troca("a: [1, 2]\n", k("a"), .lista([.inteiro(1)])) == "a: [1]\n")
}

// MARK: - Blocos | e >

@Test func yamlBlocoLiteral() throws {
    let texto = "msg: |  # nota\n  linha 1\n  linha 2\nfim: 1\n"
    #expect(try troca(texto, k("msg"), .texto("um\ndois\ntrês\n")) == "msg: |  # nota\n  um\n  dois\n  três\nfim: 1\n")
    // sem quebra no fim: indicador '-'; com várias: '+'
    #expect(try troca(texto, k("msg"), .texto("um")) == "msg: |-  # nota\n  um\nfim: 1\n")
    #expect(try troca(texto, k("msg"), .texto("um\n\n")) == "msg: |+  # nota\n  um\n\nfim: 1\n")
    // linhas em branco no meio ficam vazias (sem espaços)
    #expect(try troca(texto, k("msg"), .texto("a\n\nb\n")) == "msg: |  # nota\n  a\n\n  b\nfim: 1\n")
    // primeira linha com espaço precisaria de indicador de recuo: vira aspas
    #expect(try troca(texto, k("msg"), .texto("  x\n")) == "msg: \"  x\\n\"\nfim: 1\n")
    // o recuo do original se mantém, também em item de lista
    #expect(try troca("l:\n    - |\n        a\n", k("l"), .lista([.texto("b\n")])) == "l:\n    - |\n        b\n")
    // no fim do arquivo, sem quebra final
    #expect(try troca("a: |\n  x", k("a"), .texto("y\n")) == "a: |\n  y\n")
    #expect(try troca("a: |\n  x", k("a"), .texto("y\n\n")) == "a: |+\n  y\n\n")
}

@Test func yamlBlocoDobrado() throws {
    let texto = "msg: >\n  um texto\n  longo\n\n  outro\nfim: 1\n"
    #expect(try LeitorYAML.ler(texto).raiz["msg"] == .texto("um texto longo\noutro\n"))
    #expect(try troca(texto, k("msg"), .texto("a b\nc\n")) == "msg: >\n  a b\n\n  c\nfim: 1\n")
    // linha com espaço no começo não é dobrada: vira literal
    #expect(try troca(texto, k("msg"), .texto("a\n  b\n")) == "msg: |\n  a\n    b\nfim: 1\n")
    // com indicador de recuo (a linha com espaço no começo também faz o `>` virar `|`)
    let r = try troca("a: >2\n   x\n", k("a"), .texto(" y\n"))
    #expect(r == "a: |2\n   y\n")
    #expect(try LeitorYAML.ler(r).raiz["a"] == .texto(" y\n"))
}

@Test func yamlBlocoComMaisAntesDeLinhasEmBranco() throws {
    // texto novo com '+' e linhas em branco depois do bloco: seriam lidas como parte do valor
    let r = try troca("a: |\n  x\n\nb: 1\n", k("a"), .texto("y\n\n"))
    #expect(try LeitorYAML.ler(r).raiz["a"] == .texto("y\n\n"))
    #expect(r.hasSuffix("\n\nb: 1\n"))
}

// MARK: - CRLF e BOM

@Test func yamlCRLFeBOM() throws {
    let texto: [UInt8] = [0xEF, 0xBB, 0xBF] + b("# c\r\na: 1\r\nl:\r\n  - x\r\nm: |\r\n  um\r\n  dois\r\nz: fim\r\n")
    let doc = try LeitorYAML.ler(texto)
    #expect(doc.temBOM && doc.quebraDeLinha == "\r\n")
    #expect(doc.raiz["m"] == .texto("um\ndois\n"), "CRLF dentro do bloco vira \\n")
    #expect(doc.entrada(k("a"))?.comentarioAcima == ["c"])
    var ed = Edicao(texto, formato: .yaml)
    #expect(try ed.resultado() == texto)
    try ed.definir(k("l"), .valor(.lista([.texto("x"), .texto("w")])))
    try ed.definir(k("m"), .valor(.texto("um\ndois\ntrês\n")))
    try ed.definir(k("a"), .valor(.inteiro(2)))
    let r = try ed.resultado()
    #expect(r == [0xEF, 0xBB, 0xBF] + b("# c\r\na: 2\r\nl:\r\n  - x\r\n  - w\r\nm: |\r\n  um\r\n  dois\r\n  três\r\nz: fim\r\n"))
}

// MARK: - Critérios 2 e 3: em todos os casos aceitos da suíte, no exemplo e em casos próprios

private let yamlEspeciais: [String: [UInt8]] = [
    "vazio": [],
    "so-comentarios": b("# nada\n\n# aqui\n"),
    "sem-quebra-final": b("a: 1\nb: 'dois'"),
    "crlf-bom": [0xEF, 0xBB, 0xBF] + b("# c\r\na: \"x y\" # z\r\n\r\nl:\r\n  - 1\r\n  -\r\n  - [a, b]\r\nc:\r\nd: |-\r\n  t\r\n"),
    "docker-compose": b("""
        services:
          app:
            image: "app:1"
            ports: ["80:80"]
            depends_on:
              - db
          db:
            image: postgres
        """),
    "github-actions": b("""
        name: CI
        on:
          push:
            branches: [ main ]
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - name: Test
                run: |
                  swift build
                  swift test

        """),
    "kubernetes": b("""
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
          labels: {app: web, tier: "frontend"}
        spec:
          replicas: 3
          template:
            spec:
              containers:
                - name: web
                  image: nginx:1.27
                  args: ["--port", "8080"]
                  env:
                    - name: MODO
                      value: "producao"
                  resources:
                    limits:
                      cpu: 500m
                      memory: 128Mi

        """),
    "pubspec": b("""
        name: km_lib
        description: >-
          Biblioteca comum dos apps
          Kogumelo.
        version: 1.2.3+4
        publish_to: none

        environment:
          sdk: '>=3.0.0 <4.0.0'

        dependencies:
          flutter:
            sdk: flutter
          intl: ^0.19.0
        """),
    "openapi": b("""
        openapi: 3.0.3
        info:
          title: API do painel
          description: |
            Linha 1.

            Linha 3, depois de uma em branco.
          version: "2.0"
        paths:
          /tarefas/{id}:
            get:
              parameters:
                - in: path
                  name: id
                  required: true
                  schema: {type: integer, minimum: 1}
              responses:
                '200':
                  description: OK

        """),
    "raiz-lista": b("- a\n- b: 1\n- [x]\n"),
    "raiz-escalar": b("--- texto solto\n...\n"),
    "explicito": b("---\na: 1\n...\n# fim\n"),
]

private func casoYAML(_ nome: String) -> [UInt8] {
    if let x = yamlEspeciais[nome] { return x }
    if nome.hasPrefix("exemplos/") { return Array(try! Data(contentsOf: raizProjeto.appendingPathComponent(nome))) }
    return SuiteYAML.bytes(nome)
}

private let casosYAML = SuiteYAML.dentro + Array(yamlEspeciais.keys).sorted() + ["exemplos/config.yaml"]

@Test(arguments: casosYAML)
func yamlSemAlteracaoMesmosBytes(_ caso: String) throws {
    let original = casoYAML(caso)
    var ed = Edicao(original, formato: .yaml)
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

/// Valor alterado para o teste: textos ganham aspas e um caractere que pede aspas duplas.
private func mutadoYAML(_ v: Valor) -> Valor {
    switch v {
    case .nulo: return .texto("no")
    case .decimal(let d) where !d.isFinite: return .decimal(2.5)
    default: return mutado(v)!
    }
}

@Test(arguments: casosYAML)
func yamlMudarCadaValor(_ caso: String) throws {
    let original = casoYAML(caso)
    let doc = try LeitorYAML.ler(original)
    func confere(_ e: Entrada, _ novo: Valor, _ faixa: Range<Int>, _ nome: String) {
        let saida: [UInt8]
        do { saida = try Gravar.aplicar(doc, alteracoes: [e.caminho: .valor(novo)]) } catch {
            Issue.record("\(caso) \(e.caminho.texto) \(nome): \(error)")
            return
        }
        #expect(soOTrechoMudou(original, saida, faixa), "\(caso) \(e.caminho.texto) \(nome): mudou fora do trecho")
        guard let relido = try? LeitorYAML.ler(saida) else { Issue.record("\(caso): releitura"); return }
        #expect(relido.valorRaiz == doc.valorRaiz.substituindo(e.caminho, por: novo)!, "\(caso) \(e.caminho.texto) \(nome)")
        #expect(relido.temBOM == doc.temBOM && relido.quebraDeLinha == doc.quebraDeLinha)
    }
    for e in doc.entradas {
        let novo = mutadoYAML(e.valor)
        confere(e, novo, e.intervalo, "mutado")
        switch e.valor {
        case .texto(let t):
            // textos que um leitor YAML 1.1 leria como outro tipo; texto de várias linhas
            for x in ["no", "on", "1e3", "010", "null", t + "\nlinha 2\n"] { confere(e, .texto(x), e.intervalo, x) }
        case .lista(let itens) where !itens.isEmpty:
            // cada item: muda só o trecho dele
            for i in itens.indices where itens[i].tipo != .lista && itens[i].tipo != .tabela {
                var l = itens
                l[i] = mutadoYAML(itens[i])
                confere(e, .lista(l), e.posicao.itens[i].intervalo, "item \(i)")
            }
            let emBloco = doc.bytes[e.intervalo].first { $0 != 0x20 } == 0x2D
            guard emBloco else { break }
            // acrescentar: uma linha a mais, nada removido
            if let saida = try? Gravar.aplicar(doc, alteracoes: [e.caminho: .valor(.lista(itens + [.texto("novo")]))]) {
                let d = Diferenca.linhas(original, saida)
                #expect(d.count == 1 && d[0].removidas.isEmpty && d[0].adicionadas.count == 1, "\(caso) \(e.caminho.texto): \(d)")
            }
            confere(e, .lista(itens + [.texto("novo")]), e.intervalo, "acrescentar")
            // tirar cada item: só as linhas dele
            if itens.count > 1 {
                for i in itens.indices {
                    var l = itens
                    l.remove(at: i)
                    confere(e, .lista(l), e.intervalo, "tirar \(i)")
                    if let saida = try? Gravar.aplicar(doc, alteracoes: [e.caminho: .valor(.lista(l))]) {
                        let d = Diferenca.linhas(original, saida)
                        #expect(d.count == 1 && d[0].adicionadas.isEmpty, "\(caso) \(e.caminho.texto) -\(i): \(d)")
                    }
                }
            }
        default: break
        }
    }
}

// MARK: - Exemplo

@Test func exemploYAML() throws {
    let original = Array(try Data(contentsOf: raizProjeto.appendingPathComponent("exemplos/config.yaml")))
    var ed = Edicao(original, formato: .yaml)
    try ed.definir(k("pool"), .valor(.inteiro(20)))
    try ed.definir(k("nivel_log"), .valor(.texto("aviso")))
    try ed.definir(k("services", "web", "restart"), .valor(.texto("no")))
    try ed.definir(k("services", "web", "ports"), .valor(.lista([.texto("8080:80"), .texto("8443:443"), .texto("9000:9000")])))
    try ed.definir(k("manutencao"), .valor(.texto("Voltamos às 14h.\n")))
    let r = s(try ed.resultado())
    #expect(r == s(original).replacingOccurrences(of: "pool: 12", with: "pool: 20")
        .replacingOccurrences(of: "nivel_log: info", with: "nivel_log: aviso")
        .replacingOccurrences(of: "restart: unless-stopped", with: "restart: \"no\"")
        .replacingOccurrences(of: "      - \"8443:443\"\n", with: "      - \"8443:443\"\n      - \"9000:9000\"\n")
        .replacingOccurrences(of: "  O painel está em manutenção.\n  Volte em alguns minutos.\n", with: "  Voltamos às 14h.\n"))
    let difs = Diferenca.linhas(original, b(r))
    #expect(difs.count == 5, "\(difs)")
}
