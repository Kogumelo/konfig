import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
/// Caminho de uma chave numa seção (`""` = Geral, antes da primeira seção).
private func k(_ secao: String, _ chave: String) -> Caminho { [.chave(secao), .chave(chave)] }

/// Aplica uma alteração num INI e devolve o texto novo.
private func troca(_ texto: String, _ c: Caminho, _ v: Valor) throws -> String {
    s(try Gravar.aplicar(b(texto), alteracoes: [c: .valor(v)], formato: .ini))
}
private func troca(_ texto: String, _ chave: String, _ v: String) throws -> String {
    try troca(texto, k("", chave), .texto(v))
}

private func valores(_ doc: DocumentoConf) -> [String: Valor] {
    var r: [String: Valor] = [:]
    for e in doc.entradas { r[e.caminho.map { if case .chave(let c) = $0 { return c }; return "" }.joined(separator: "/")] = e.valor }
    return r
}

enum FixturesINI {
    static let pasta = Suite.pasta.appendingPathComponent("ini")
    static let todos: [String] = (try? FileManager.default.contentsOfDirectory(atPath: pasta.path))?
        .filter { $0.hasSuffix(".ini") || $0.hasSuffix(".editorconfig") }.sorted() ?? []
    static func bytes(_ nome: String) -> [UInt8] {
        Array(try! Data(contentsOf: pasta.appendingPathComponent(nome)))
    }
}

private let raizProjeto = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

// MARK: - Regras de leitura

@Test func iniTemAsFixtures() {
    #expect(FixturesINI.todos == ["bom-crlf.ini", "editorconfig-core-go.editorconfig", "editorconfig-core-js.editorconfig",
                                  "listas.ini", "php.ini-production-trecho.ini", "regras.ini"])
}

@Test func iniRegras() throws {
    let doc = try LeitorINI.ler(FixturesINI.bytes("regras.ini"))
    let v = valores(doc)
    // antes da primeira seção: "Geral" (chave "" na estrutura)
    #expect(v["/antes_da_secao"] == .texto("vai para \"Geral\""))
    #expect(v["/dois_pontos"] == .texto("separador ':'"), "chave: valor")
    #expect(v["/recuada"] == .texto("espaços nas pontas não contam"))
    #expect(v["/vazia"] == .texto("") && v["/vazia_com_comentario"] == .texto(""))
    #expect(v["/ponto_e_virgula_colado"] == .texto("a;b"), "';' sem espaço antes é valor")
    #expect(v["/cerquilha_colada"] == .texto("a#b"))
    #expect(v["/url"] == .texto("http://x/#a"))
    #expect(v["/comentario_no_fim"] == .texto("valor"))
    #expect(v["/comentario_tab"] == .texto("valor"))
    #expect(v["/cor"] == .texto("#DD0000"), "'#' no começo do valor é valor")
    #expect(v["/igual_no_valor"] == .texto("a=b=c"))
    #expect(v["/dois_pontos_no_valor"] == .texto(#"c:\pasta"#), "vale o primeiro separador")
    #expect(v["/interpolacao"] == .texto("%(home)s/bin e ${HOME}"), "interpolação fica como texto")
    // seções
    #expect(v["seção com espaços/duplas"] == .texto("  com espaços ; e # dentro  "), "aspas duplas, sem escapes")
    #expect(v["seção com espaços/simples"] == .texto("aspas \"duplas\" dentro"))
    #expect(v["seção com espaços/duplas_comentario"] == .texto("x"))
    #expect(v["seção com espaços/duplas_vazias"] == .texto(""))
    #expect(v["seção com espaços/acentos"] == .texto("ação 😀"))
    #expect(v["a.b/x"] == .texto("1") && v["a.b/y"] == .texto("2"), "ponto literal; seção repetida continua a primeira")
    #expect(v["*.[ch]/indent_size"] == .texto("4"), "colchetes dentro do nome (EditorConfig)")
    #expect(v["remote \"origin\"/url"] == .texto("git@exemplo:repo.git"), "subseção do Git é só um nome")
    #expect(doc.cabecalhos.map(\.nomes) == [["seção com espaços"], ["a.b"], ["*.[ch]"], ["remote \"origin\""]])
    #expect(doc.raiz["a"] == nil, "[a.b] não cria a seção 'a'")

    // comentários
    let e = doc.entrada(k("", "antes_da_secao"))!
    #expect(e.comentarioAcima == ["comentário logo acima de uma chave vira ajuda"], "linha em branco separa; ';;' some")
    #expect(e.secao == nil && e.chaveEscrita == "antes_da_secao")
    #expect(doc.entrada(k("", "vazia_com_comentario"))?.comentarioFim == "só comentário")
    #expect(doc.entrada(k("", "comentario_no_fim"))?.comentarioFim == "comentário")
    #expect(doc.entrada(k("", "comentario_tab"))?.comentarioFim == "depois de tabulação")
    #expect(doc.entrada(k("", "url"))?.comentarioFim == nil)
    #expect(doc.cabecalhos[1].comentarioFim == "ponto é literal")
    #expect(doc.entrada(k("a.b", "y"))?.comentarioAcima == ["seção repetida continua a primeira"])
    // intervalos
    #expect(doc.texto(doc.entrada(k("", "recuada"))!.intervalo) == "espaços nas pontas não contam")
    #expect(doc.texto(doc.entrada(k("seção com espaços", "duplas"))!.intervalo) == "\"  com espaços ; e # dentro  \"")
    #expect(doc.entrada(k("", "vazia"))!.intervalo.isEmpty)
    #expect(doc.quebraDeLinha == "\n" && !doc.temBOM)
}

@Test func iniSecoesNaTela() throws {
    let doc = try LeitorINI.ler(FixturesINI.bytes("regras.ini"))
    let secoes = Campos.secoes(doc)
    #expect(secoes.map(\.titulo) == ["Geral", "seção com espaços", "a.b", "*.[ch]", "remote \"origin\""])
    #expect(secoes.map(\.subtitulo).dropFirst() == ["[seção com espaços]", "[a.b]", "[*.[ch]]", "[remote \"origin\"]"])
    #expect(secoes[2].campos.map(\.rotulo) == ["x", "y"])
    #expect(Set(secoes.map(\.id)).count == secoes.count)
    let escolha = secoes[1].campos.first { $0.rotulo == "escolha" }
    #expect(escolha?.tipo == .escolha(["a", "b", "c"]))
    #expect(secoes[0].campos.first { $0.rotulo == "antes_da_secao" }?.ajuda == "comentário logo acima de uma chave vira ajuda")
    #expect(secoes[0].campos.allSatisfy { $0.tipo == .texto }, "todo valor é texto")
}

@Test func iniListas() throws {
    let doc = try LeitorINI.ler(FixturesINI.bytes("listas.ini"))
    let v = valores(doc)
    #expect(v["php/ext[]"] == .lista([.texto("curl"), .texto("gd"), .texto("intl")]), "'ext []' é a mesma lista")
    #expect(v["intercalada/item[]"] == .lista([.texto("a"), .texto("b")]))
    #expect(v["intercalada/outra"] == .texto("x"))
    #expect(v["extensoes/extension"] == .lista([.texto("curl"), .texto("gd")]), "extension repetida (PHP) é lista")
    #expect(v["extensoes/zend_extension"] == .lista([.texto("opcache")]))
    let ext = doc.entrada(k("php", "ext[]"))!
    #expect(ext.linha == 4 && ext.linhaFinal == 6)
    #expect(ext.comentarioAcima == ["extensões carregadas"])
    #expect(ext.posicao.itens.map { doc.texto($0.intervalo) } == ["curl", "\"gd\"", "intl"])
    let campo = Campos.secoes(doc).flatMap(\.campos).first { $0.rotulo == "ext[]" }
    #expect(campo?.tipo == .lista(.texto))
}

@Test func iniCRLFeBOM() throws {
    let doc = try LeitorINI.ler(FixturesINI.bytes("bom-crlf.ini"))
    #expect(doc.temBOM && doc.quebraDeLinha == "\r\n")
    let v = valores(doc)
    #expect(v["/nome"] == .texto("ação"))
    #expect(v["sec/lista[]"] == .lista([.texto("1"), .texto("2")]))
    #expect(v["sec/fim"] == .texto("sem quebra final"))
    #expect(doc.entrada(k("", "nome"))?.comentarioAcima == ["com BOM e CRLF"])
}

@Test(arguments: [
    ("a = 1\nb\n", 2, 1, "não é seção"),
    ("chave sem separador\n", 1, 1, "não é seção"),
    ("= 1\n", 1, 1, "falta o nome da chave"),
    ("[a]\nx = 1\n\nx = 2\n", 4, 1, "já apareceu na linha 2 na seção [a]"),
    ("x = 1\nx = 2\n", 2, 1, "antes da primeira seção"),
    ("[a]\nx = 1\n[b]\n[a]\nx = 2\n", 5, 1, "já apareceu na linha 2"),
    ("[sem fim\n", 1, 1, "sem ']'"),
    ("[a] b\n", 1, 1, "sem ']'"),
    ("[  ]\n", 1, 1, "seção sem nome"),
    ("a = \"x\n", 1, 5, "não fechadas"),
    ("a = 'x\" \n", 1, 5, "não fechadas"),
    ("a = \"x\" y\n", 1, 9, "depois das aspas"),
    ("a = 1\rb = 2\n", 1, 6, "CR sozinho"),
    ("[]= 1\n", 1, 1, "sem ']'"),
    ("  [] = 1\n", 1, 3, "sem ']'"),
    ("x[] = 1\nx = 2\n", 2, 1, "não é aceita"),
    ("x = 1\nx[] = 2\n", 2, 1, "não é aceita"),
    ("    continuação de valor\n", 1, 5, "não é seção"),
])
func iniRecusaComLinhaEColuna(_ caso: (String, Int, Int, String)) {
    do {
        let doc = try LeitorINI.ler(caso.0)
        Issue.record("aceitou \(caso.0.debugDescription): \(valores(doc))")
    } catch {
        #expect(error.linha == caso.1 && error.coluna == caso.2, "\(caso.0.debugDescription): \(error)")
        #expect(error.mensagem.contains(caso.3), "\(error)")
        #expect(error.formato == .ini)
    }
}

@Test func iniUTF8Invalido() {
    #expect(throws: ErroLeitura.self) { try LeitorINI.ler([0x61, 0x3D, 0xE7, 0x0A]) }
}

@Test func iniLerValor() throws {
    #expect(try LeitorINI.lerValor("abc") == .texto("abc"))
    #expect(try LeitorINI.lerValor("'a;b'") == .texto("a;b"))
    #expect(try LeitorINI.lerValor("  x y  ") == .texto("x y"))
    #expect(throws: ErroLeitura.self) { try LeitorINI.lerValor("abc ; x") }
    #expect(throws: ErroLeitura.self) { try LeitorINI.lerValor("\"abc") }
    #expect(throws: ErroLeitura.self) { try LeitorINI.lerValor("a\nb = 2") }
}

@Test func formatoINIPeloNome() {
    #expect(Formato(nomeArquivo: "php.ini") == .ini)
    #expect(Formato(nomeArquivo: "desktop.INI") == .ini)
    #expect(Formato(nomeArquivo: ".editorconfig") == .ini)
    #expect(Formato(nomeArquivo: "config.ini.bak") == nil)
    #expect(Formato.ini.nome == "INI")
}

// MARK: - Arquivos reais

@Test func iniEditorConfigReal() throws {
    let js = try LeitorINI.ler(FixturesINI.bytes("editorconfig-core-js.editorconfig"))
    let v = valores(js)
    #expect(v["/root"] == .texto("true"))
    #expect(v["*/indent_style"] == .texto("space"))
    #expect(v["*/block_comment_start"] == .texto("/**"))
    #expect(v["*/block_comment"] == .texto("*"))
    #expect(v["*.md/indent_size"] == .texto("4"))
    let go = try LeitorINI.ler(FixturesINI.bytes("editorconfig-core-go.editorconfig"))
    #expect(go.cabecalhos.map { $0.nomes[0] } == ["*", "{Makefile,*.go,.gitmodules}", "go.{mod,work,work.sum,sum}",
                                                  "*.md", "Dockerfile"])
    #expect(valores(go)["*.md/eclint_indent_style"] == .texto("unset"))
}

@Test func iniPHPReal() throws {
    let doc = try LeitorINI.ler(FixturesINI.bytes("php.ini-production-trecho.ini"))
    let v = valores(doc)
    #expect(v["PHP/engine"] == .texto("On"))
    #expect(v["PHP/error_reporting"] == .texto("E_ALL & ~E_DEPRECATED"))
    #expect(v["PHP/variables_order"] == .texto("GPCS"))
    #expect(v["PHP/auto_prepend_file"] == .texto(""))
    #expect(v["Session/session.trans_sid_tags"] == .texto("a=href,area=href,frame=src,form="))
    #expect(v["Session/session.cookie_path"] == .texto("/"))
    #expect(doc.cabecalhos.map { $0.nomes[0] }.contains("CLI Server"))
    // as extensões vêm comentadas (`;extension=…`): nenhuma vira chave
    #expect(doc.entradas.allSatisfy { $0.chaveEscrita != "extension" })
}

// MARK: - Gravar: aspas e estilo

@Test func iniGravarMantemAspas() throws {
    // sem aspas continua sem aspas quando cabe
    #expect(try troca("a = 1\n", "a", "2") == "a = 2\n")
    #expect(try troca("a: x ; c\n", "a", "y") == "a: y ; c\n")
    #expect(try troca("a=x\n", "a", "http://x/#b") == "a=http://x/#b\n")
    #expect(try troca("a=x\n", "a", "a#b") == "a=a#b\n")
    // não cabe sem aspas: duplas
    #expect(try troca("a = x ; c\n", "a", "a;b") == "a = \"a;b\" ; c\n")
    #expect(try troca("a = x\n", "a", "a #b") == "a = \"a #b\"\n")
    #expect(try troca("a = x\n", "a", "#DD0000") == "a = \"#DD0000\"\n")
    #expect(try troca("a = x\n", "a", " pontas ") == "a = \" pontas \"\n")
    #expect(try troca("a = x\n", "a", "\"oi\"") == "a = '\"oi\"'\n", "com aspas duplas: simples")
    #expect(try troca("a = x\n", "a", "it's") == "a = it's\n", "aspa no meio cabe sem aspas")
    // simples continua simples; duplas continua duplas; troca se o texto tiver a aspa
    #expect(try troca("a = 'x'\n", "a", "y z") == "a = 'y z'\n")
    #expect(try troca("a = 'x'\n", "a", "it's") == "a = \"it's\"\n")
    #expect(try troca("a = \"x\"\n", "a", "y") == "a = \"y\"\n")
    #expect(try troca("a = \"x\"  ; c\n", "a", "diz \"oi\"") == "a = 'diz \"oi\"'  ; c\n")
    #expect(try troca("a = \"x\"\n", "a", "") == "a = \"\"\n")
    // valor vazio
    #expect(try troca("a =\n", "a", "v") == "a = v\n")
    #expect(try troca("a=\n", "a", "v") == "a=v\n")
    #expect(try troca("a =   ; c\n", "a", "v") == "a = v   ; c\n")
    #expect(try troca("a =; c\n", "a", "v") == "a = v ; c\n")
    #expect(try troca("a = x ; c\n", "a", "") == "a =  ; c\n")
    // CRLF e seção
    #expect(try troca("[s]\r\nk = 1\r\n", k("s", "k"), .texto("2")) == "[s]\r\nk = 2\r\n")
}

@Test func iniRecusaOQueNaoCabe() {
    var ed = Edicao(b("a = 1\nl[] = x\n"), formato: .ini)
    #expect(throws: ErroGravar.self) { try ed.definir(k("", "a"), .valor(.inteiro(2))) }
    #expect(throws: ErroGravar.self) { try ed.definir(k("", "a"), .valor(.texto("a\nb"))) }
    #expect(throws: ErroGravar.self) { try ed.definir(k("", "a"), .valor(.texto("'a;b\""))) }
    #expect(throws: ErroGravar.self) { try ed.definir(k("", "l[]"), .valor(.lista([]))) }
    #expect(throws: ErroGravar.self) { try ed.definir(k("", "l[]"), .valor(.lista([.inteiro(1)]))) }
    #expect(throws: ErroGravar.self) { try ed.definir(k("", "a"), .cru("x ; y")) }
    #expect(throws: ErroLeitura.self) { try ed.trocarTexto(b("a = 1\na = 2\n")) }
}

// MARK: - Listas: acrescentar e tirar linhas

@Test func iniListaAcrescentaUmaLinha() throws {
    let texto = "[php]\next[] = curl\next[] = \"gd\" ; c\nmemory_limit = 128M\n"
    let c = k("php", "ext[]")
    let r = try troca(texto, c, .lista([.texto("curl"), .texto("gd"), .texto("intl")]))
    #expect(r == "[php]\next[] = curl\next[] = \"gd\" ; c\next[] = \"intl\"\nmemory_limit = 128M\n")
    let difs = Diferenca.linhas(b(texto), b(r))
    #expect(difs.count == 1 && difs[0].removidas.isEmpty && difs[0].adicionadas == ["ext[] = \"intl\""])
    // recuo e separador copiados; CRLF
    #expect(try troca("[a]\r\n  x[]=1\r\n", k("a", "x[]"), .lista([.texto("1"), .texto("2")]))
        == "[a]\r\n  x[]=1\r\n  x[]=2\r\n")
    // último item vazio com espaço antes do '='
    #expect(try troca("x[] =\n", k("", "x[]"), .lista([.texto(""), .texto("b")])) == "x[] =\nx[] = b\n")
    // último sem quebra final
    #expect(try troca("x[] = a", k("", "x[]"), .lista([.texto("a"), .texto("b")])) == "x[] = a\nx[] = b")
    // extension= do PHP
    #expect(try troca("extension=curl\nextension=gd\n", k("", "extension"), .lista([.texto("curl"), .texto("gd"), .texto("intl")]))
        == "extension=curl\nextension=gd\nextension=intl\n")
}

@Test func iniListaTiraUmaLinha() throws {
    let texto = "; topo\nx[] = a\n; sobre b\nx[] = b\nx[] = c\nfim = 1\n"
    let c = k("", "x[]")
    #expect(try troca(texto, c, .lista([.texto("b"), .texto("c")])) == "; topo\n; sobre b\nx[] = b\nx[] = c\nfim = 1\n")
    #expect(try troca(texto, c, .lista([.texto("a"), .texto("c")])) == "; topo\nx[] = a\n; sobre b\nx[] = c\nfim = 1\n")
    #expect(try troca(texto, c, .lista([.texto("a"), .texto("b")])) == "; topo\nx[] = a\n; sobre b\nx[] = b\nfim = 1\n")
    // o comentário acima de um item tirado fica
    #expect(try troca(texto, c, .lista([.texto("a")])) == "; topo\nx[] = a\n; sobre b\nfim = 1\n")
    #expect(try troca(texto, c, .lista([.texto("c")])) == "; topo\n; sobre b\nx[] = c\nfim = 1\n")
    #expect(try troca("x[] = a\r\nx[] = b", c, .lista([.texto("a")])) == "x[] = a")
    #expect(try troca("x[] = a\r\nx[] = b\r\n", c, .lista([.texto("b")])) == "x[] = b\r\n")
    for (antes, depois) in [(texto, try troca(texto, c, .lista([.texto("a"), .texto("c")])))] {
        let difs = Diferenca.linhas(b(antes), b(depois))
        #expect(difs.count == 1 && difs[0].removidas == ["x[] = b"] && difs[0].adicionadas.isEmpty)
    }
}

@Test func iniListaMudaUmItem() throws {
    let texto = "x[] = a\nx[] = 'b' ; c\nx[] = c\n"
    let r = try troca(texto, k("", "x[]"), .lista([.texto("a"), .texto("B 2"), .texto("c")]))
    #expect(r == "x[] = a\nx[] = 'B 2' ; c\nx[] = c\n")
    // mistura: muda um e acrescenta outro
    let r2 = try troca(texto, k("", "x[]"), .lista([.texto("A"), .texto("b"), .texto("c"), .texto("d")]))
    #expect(r2 == "x[] = A\nx[] = 'b' ; c\nx[] = c\nx[] = d\n")
}

@Test func iniListaIntercaladaComOutraChave() throws {
    // a lista ocupa as linhas de 'a' a 'b', e 'outra' fica no meio: as duas alterações
    // se cruzam e são aplicadas uma de cada vez
    let original = FixturesINI.bytes("listas.ini")
    var ed = Edicao(original, formato: .ini)
    try ed.definir(k("intercalada", "outra"), .valor(.texto("y")))
    try ed.definir(k("intercalada", "item[]"), .valor(.lista([.texto("a"), .texto("b"), .texto("c")])))
    let r = s(try ed.resultado())
    #expect(r == s(original).replacingOccurrences(of: "outra = x", with: "outra = y")
        .replacingOccurrences(of: "item[] = b\n", with: "item[] = b\nitem[] = c\n"))
}

@Test func iniEdicaoDesfazerVoltaAoOriginal() throws {
    let original = FixturesINI.bytes("listas.ini")
    var ed = Edicao(original, formato: .ini)
    let c = k("php", "ext[]")
    let antes = ed.efetivo(c)!
    try ed.definir(c, .valor(.lista([.texto("curl"), .texto("gd"), .texto("intl"), .texto("zip")])))
    #expect(try ed.resultado() != original)
    try ed.definir(c, antes)
    #expect(try ed.resultado() == original)
}

// MARK: - Critério 2 e 3 em todos os arquivos (os mesmos testes do TOML, do JSON e do .env)

private let iniEspeciais: [String: [UInt8]] = [
    "vazio": [],
    "so-comentarios": b("; nada\n\n# aqui\n"),
    "sem-quebra-final": b("a = 1\n[s]\nb = 'dois'"),
    "crlf-bom-listas": [0xEF, 0xBB, 0xBF] + b("; c\r\na = \"x y\" ; z\r\n\r\n[s]\r\nl[] = 1\r\nl[] =\r\nc =\r\n"),
    "indentado": b("  a = 1\n\tb:\t\"2\"\t# c\n [s] \n  c=3\n"),
    "so-secoes": b("[a]\n[b]\n"),
]

private func casoINI(_ nome: String) -> [UInt8] {
    if let x = iniEspeciais[nome] { return x }
    if nome.hasPrefix("exemplos/") { return Array(try! Data(contentsOf: raizProjeto.appendingPathComponent(nome))) }
    return FixturesINI.bytes(nome)
}

private let casosINI = FixturesINI.todos + Array(iniEspeciais.keys).sorted() + ["exemplos/config.ini"]

@Test(arguments: casosINI)
func iniSemAlteracaoMesmosBytes(_ caso: String) throws {
    let original = casoINI(caso)
    var ed = Edicao(original, formato: .ini)
    #expect(ed.erro == nil, "\(String(describing: ed.erro))")
    #expect(try ed.resultado() == original)
    #expect(!ed.temAlteracoes)
    for e in ed.documento?.entradas ?? [] {
        try ed.definir(e.caminho, .valor(e.valor))
        if case .texto = e.valor { try ed.definir(e.caminho, .cru(ed.documento!.texto(e.intervalo))) }
    }
    #expect(ed.alteracoes.isEmpty)
    #expect(try ed.resultado() == original)
}

@Test(arguments: casosINI)
func iniMudarCadaValor(_ caso: String) throws {
    let original = casoINI(caso)
    let doc = try LeitorINI.ler(original)
    func confere(_ e: Entrada, _ novo: Valor, _ faixa: Range<Int>, _ nome: String) throws {
        let saida: [UInt8]
        do { saida = try Gravar.aplicar(original, alteracoes: [e.caminho: .valor(novo)], formato: .ini) } catch {
            Issue.record("\(caso) \(e.chaveEscrita) \(nome): \(error)")
            return
        }
        #expect(soOTrechoMudou(original, saida, faixa), "\(caso) \(e.chaveEscrita) \(nome): mudou fora do trecho")
        let relido = try LeitorINI.ler(saida)
        #expect(relido.valorRaiz == doc.valorRaiz.substituindo(e.caminho, por: novo)!, "\(caso) \(e.chaveEscrita)")
        #expect(relido.entradas.map(\.comentarioFim) == doc.entradas.map(\.comentarioFim), "\(caso) \(e.chaveEscrita)")
        #expect(relido.temBOM == doc.temBOM && relido.quebraDeLinha == doc.quebraDeLinha)
    }
    for e in doc.entradas {
        switch e.valor {
        case .texto(let t):
            // cabe sem aspas, precisa de aspas, tem aspas duplas
            for novo in [t + "x", t + " ;x# ", "diz \"oi\"" + t] {
                try confere(e, .texto(novo), e.intervalo, novo)
            }
            // o tipo de aspas se mantém quando o valor cabe nele
            let saida = try Gravar.aplicar(original, alteracoes: [e.caminho: .valor(.texto(t + "x"))], formato: .ini)
            let relido = try LeitorINI.ler(saida)
            let antes = doc.bytes[e.intervalo].first, depois = relido.entrada(e.caminho).map { relido.bytes[$0.intervalo].first }
            if antes == 0x22 || antes == 0x27 { #expect(depois == antes, "\(caso) \(e.chaveEscrita)") }
        case .lista(let itens):
            // cada item: muda só o trecho dele
            for i in itens.indices {
                guard case .texto(let t) = itens[i] else { continue }
                var l = itens
                l[i] = .texto(t + " ;x")
                try confere(e, .lista(l), e.posicao.itens[i].intervalo, "item \(i)")
            }
            // acrescentar: uma linha a mais, nada removido
            let mais = try Gravar.aplicar(original, alteracoes: [e.caminho: .valor(.lista(itens + [.texto("novo")]))], formato: .ini)
            let difs = Diferenca.linhas(original, mais)
            #expect(difs.count == 1 && difs[0].removidas.isEmpty && difs[0].adicionadas.count == 1, "\(caso) \(e.chaveEscrita): \(difs)")
            try confere(e, .lista(itens + [.texto("novo")]), e.intervalo, "acrescentar")
            // tirar cada item: uma linha a menos
            if itens.count > 1 {
                for i in itens.indices {
                    var l = itens
                    l.remove(at: i)
                    let menos = try Gravar.aplicar(original, alteracoes: [e.caminho: .valor(.lista(l))], formato: .ini)
                    let d = Diferenca.linhas(original, menos)
                    #expect(d.count == 1 && d[0].removidas.count == 1 && d[0].adicionadas.isEmpty, "\(caso) \(e.chaveEscrita) -\(i): \(d)")
                    try confere(e, .lista(l), e.intervalo, "tirar \(i)")
                }
            }
        default:
            Issue.record("valor que não é texto nem lista")
        }
    }
}

// MARK: - Exemplo

@Test func exemploINI() throws {
    let original = Array(try Data(contentsOf: raizProjeto.appendingPathComponent("exemplos/config.ini")))
    #expect(original.contains(0x0D), "o exemplo usa CRLF")
    let doc = try LeitorINI.ler(original)
    #expect(doc.quebraDeLinha == "\r\n")
    let secoes = Campos.secoes(doc)
    #expect(secoes.map(\.titulo) == ["Geral", "servidor", "banco", "php", "log.arquivo"])
    let campos = Dictionary(uniqueKeysWithValues: secoes.flatMap(\.campos).map { ($0.id, $0) })
    #expect(campos["servidor.nivel_log"]?.tipo == .escolha(["debug", "info", "aviso", "erro"]))
    #expect(campos["banco.driver"]?.tipo == .escolha(["firebird", "postgres"]))
    #expect(campos["servidor.url"]?.valor == .texto("http://x/#a"))
    #expect(campos["banco.pool"]?.ajuda == "conexões simultâneas")
    #expect(campos["php.\"extensoes[]\""]?.tipo == .lista(.texto))
    #expect(campos["php.cor"]?.valor == .texto("#DD0000"))

    var ed = Edicao(original, formato: .ini)
    try ed.definir(k("banco", "pool"), .valor(.texto("20")))
    try ed.definir(k("servidor", "nivel_log"), .valor(.texto("aviso")))
    try ed.definir(k("servidor", "titulo"), .valor(.texto("Painel Kogumelo 2")))
    try ed.definir(k("php", "extensoes[]"), .valor(.lista([.texto("curl"), .texto("gd"), .texto("intl"), .texto("zip")])))
    let r = s(try ed.resultado())
    #expect(r == s(original).replacingOccurrences(of: "pool = 12 ", with: "pool = 20 ")
        .replacingOccurrences(of: "nivel_log = info", with: "nivel_log = aviso")
        .replacingOccurrences(of: "\"Painel Kogumelo\"", with: "\"Painel Kogumelo 2\"")
        .replacingOccurrences(of: "extensoes[] = intl\r\n", with: "extensoes[] = intl\r\nextensoes[] = zip\r\n"))
    // nivel_log e titulo estão em linhas vizinhas: um trecho só
    let difs = Diferenca.linhas(original, b(r))
    #expect(difs.count == 3, "\(difs)")
    // 3 linhas trocadas e 1 acrescentada (o item da lista)
    #expect(difs.flatMap(\.removidas).count == 3 && difs.flatMap(\.adicionadas).count == 4, "\(difs)")
}
