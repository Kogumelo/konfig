import Foundation
import Testing
@testable import ConfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

/// Aplica uma alteração e devolve o texto novo.
private func troca(_ texto: String, _ caminho: Caminho, _ v: Valor) throws -> String {
    s(try Gravar.aplicar(b(texto), alteracoes: [caminho: .valor(v)]))
}

private func k(_ partes: String...) -> Caminho { partes.map { .chave($0) } }

// MARK: - Sanidade da comparação com a suíte

@Test func comparacaoDetectaDiferenca() throws {
    let doc = try Leitor.ler("a = 1\nb = \"x\"\n")
    let errado: [String: Any] = ["a": ["type": "integer", "value": "2"], "b": ["type": "string", "value": "x"]]
    #expect(!Comparar.tabela(doc.raiz, errado as NSDictionary, "").isEmpty)
    let certo: [String: Any] = ["a": ["type": "integer", "value": "1"], "b": ["type": "string", "value": "x"]]
    #expect(Comparar.tabela(doc.raiz, certo as NSDictionary, "").isEmpty)
}

// MARK: - Critério 2: abrir e salvar sem alteração não muda nenhum byte

let arquivosEspeciais: [String: [UInt8]] = [
    "comentarios": b("""
        # Cabeçalho do arquivo
        titulo = "Painel"   # comentário no fim

        # acima da tabela
        [servidor]   # depois do cabeçalho
          host = '0.0.0.0'
          portas = [ 8080,  8443, ]  # duas portas
        \t# tabulação antes
        [[t]]
        x = 1
        """),
    "crlf": b("a = 1\r\n# c\r\n[t]\r\nb = \"\"\"\r\nlinha1\r\nlinha2\"\"\"\r\nl = [\r\n  1,\r\n  2,\r\n]\r\n"),
    "bom": [0xEF, 0xBB, 0xBF] + b("# com BOM\nnome = \"ação\"\n[x]\ny = 2024-01-02\n"),
    "bom-crlf-sem-quebra-final": [0xEF, 0xBB, 0xBF] + b("a = 'b'\r\n[c]\r\nd = 1.5"),
    "vazio": [],
    "so-comentario": b("# nada aqui\n\n\n"),
]

@Test(arguments: Array(arquivosEspeciais.keys).sorted())
func semAlteracaoMesmosBytes(_ nome: String) throws {
    let original = arquivosEspeciais[nome]!
    var ed = EdicaoTOML(original)
    #expect(ed.erro == nil)
    #expect(try ed.resultado() == original)
    #expect(!ed.temAlteracoes)
    // Mesmo "alterando" cada valor para ele mesmo, nada muda.
    for e in ed.documento!.entradas {
        try ed.definir(e.caminho, .valor(e.valor))
        try ed.definir(e.caminho, .cru(ed.documento!.texto(e.intervalo)))
    }
    #expect(ed.alteracoes.isEmpty)
    #expect(try ed.resultado() == original)
}

@Test(arguments: Suite.validos)
func semAlteracaoMesmosBytesSuite(_ caso: String) throws {
    let original = Suite.bytes(caso)
    var ed = EdicaoTOML(original)
    for e in ed.documento!.entradas { try ed.definir(e.caminho, .valor(e.valor)) }
    #expect(try ed.resultado() == original)
}

// MARK: - Critério 3: mudar um valor altera só aquele trecho

/// Um valor diferente do mesmo tipo, para testar a gravação.
func mutado(_ v: Valor) -> Valor? {
    switch v {
    case .texto(let s): return .texto(s + "x'\"")
    case .inteiro(let n): return .inteiro(n == Int64.max ? n - 1 : n + 1)
    case .decimal(let d): return .decimal(d.isFinite ? d + 1.5 : 2.5)
    case .booleano(let x): return .booleano(!x)
    case .dataHora(var dh):
        if dh.temData { dh.dia = dh.dia == 1 ? 2 : 1 } else { dh.minuto = (dh.minuto + 1) % 60 }
        return .dataHora(dh)
    case .lista(let l):
        if let p = l.first { return .lista(l + [p]) }
        return .lista([.inteiro(1)])
    case .tabela(var t):
        t["km_toml_novo"] = .inteiro(7)
        return .tabela(t)
    }
}

/// Confere que só o intervalo do valor mudou: tudo antes e depois fica igual, byte a byte.
func soOTrechoMudou(_ antes: [UInt8], _ depois: [UInt8], _ r: Range<Int>) -> Bool {
    let sufixo = antes.count - r.upperBound
    guard depois.count >= r.lowerBound + sufixo else { return false }
    return depois.prefix(r.lowerBound).elementsEqual(antes.prefix(r.lowerBound))
        && depois.suffix(sufixo).elementsEqual(antes.suffix(sufixo))
}

@Test(arguments: Suite.validos + Array(arquivosEspeciais.keys).sorted())
func mudarCadaValor(_ caso: String) throws {
    let original = arquivosEspeciais[caso] ?? Suite.bytes(caso)
    let doc = try Leitor.ler(original)
    for e in doc.entradas {
        guard let novo = mutado(e.valor) else { continue }
        let saida: [UInt8]
        do { saida = try Gravar.aplicar(original, alteracoes: [e.caminho: .valor(novo)]) } catch {
            Issue.record("\(e.caminho.texto): \(error)")
            continue
        }
        #expect(soOTrechoMudou(original, saida, e.intervalo), "\(e.caminho.texto): mudou fora do trecho")
        let relido = try Leitor.ler(saida)
        #expect(relido.raiz == doc.raiz.substituindo(e.caminho, por: novo)!, "\(e.caminho.texto)")
        #expect(relido.raiz.valor(em: e.caminho) == novo)
    }
}

@Test func mudarVariosDeUmaVez() throws {
    let t = "a = 1 # um\nb = \"x\"\n[s]\nc = true\nd = 2.5\n"
    let r = s(try Gravar.aplicar(b(t), alteracoes: [
        k("a"): .valor(.inteiro(10)), k("s", "c"): .valor(.booleano(false)), k("s", "d"): .valor(.decimal(3)),
    ]))
    #expect(r == "a = 10 # um\nb = \"x\"\n[s]\nc = false\nd = 3.0\n")
}

// MARK: - Estilo de cada tipo

@Test func textoMantemAspas() throws {
    #expect(try troca("a = \"x\"\n", k("a"), .texto("y\"z")) == "a = \"y\\\"z\"\n")
    #expect(try troca("a = 'x'\n", k("a"), .texto("c:\\pasta")) == "a = 'c:\\pasta'\n")
    // não cabe em literal: vira aspas normais com escape
    #expect(try troca("a = 'x'\n", k("a"), .texto("it's")) == "a = \"it's\"\n")
    #expect(try troca("a = 'x'\n", k("a"), .texto("l1\nl2")) == "a = \"l1\\nl2\"\n")
    #expect(try troca("a = \"\"\"\nx\"\"\"\n", k("a"), .texto("um\ndois")) == "a = \"\"\"\num\ndois\"\"\"\n")
    #expect(try troca("a = '''x'''\n", k("a"), .texto("c:\\x")) == "a = '''c:\\x'''\n")
    #expect(try troca("a = '''x'''\n", k("a"), .texto("a'''b")) == "a = \"\"\"a'''b\"\"\"\n")
    #expect(try troca("a = \"\"\"x\"\"\"\n", k("a"), .texto("\"\"\"")) == "a = \"\"\"\\\"\\\"\\\"\"\"\"\n")
    // CRLF dentro de texto de várias linhas segue o arquivo
    #expect(try troca("a = \"\"\"\r\nx\"\"\"\r\n", k("a"), .texto("1\n2")) == "a = \"\"\"\r\n1\r\n2\"\"\"\r\n")
}

@Test func inteiroMantemBase() throws {
    #expect(try troca("a = 0xff\n", k("a"), .inteiro(4096)) == "a = 0x1000\n")
    #expect(try troca("a = 0xFF\n", k("a"), .inteiro(171)) == "a = 0xAB\n")
    #expect(try troca("a = 0x00ff\n", k("a"), .inteiro(16)) == "a = 0x0010\n")
    #expect(try troca("a = 0o755\n", k("a"), .inteiro(0o644)) == "a = 0o644\n")
    #expect(try troca("a = 0b1010\n", k("a"), .inteiro(3)) == "a = 0b0011\n")
    #expect(try troca("a = 1_000\n", k("a"), .inteiro(1234567)) == "a = 1_234_567\n")
    #expect(try troca("a = +5\n", k("a"), .inteiro(6)) == "a = +6\n")
    // negativo não existe em hex: vira decimal
    #expect(try troca("a = 0xff\n", k("a"), .inteiro(-1)) == "a = -1\n")
}

@Test func decimalBoolData() throws {
    #expect(try troca("a = 1.5\n", k("a"), .decimal(2)) == "a = 2.0\n")
    #expect(try troca("a = 1.5\n", k("a"), .decimal(.infinity)) == "a = inf\n")
    #expect(try troca("a = 1.5\n", k("a"), .decimal(1e-7)) == "a = 1e-07\n")
    #expect(try troca("a = true\n", k("a"), .booleano(false)) == "a = false\n")
    var d = try #require({ if case .dataHora(let x) = try Leitor.lerValor("1979-05-27 07:32:00z") { return x }; return nil }())
    d.hora = 8
    #expect(try troca("a = 1979-05-27 07:32:00z\n", k("a"), .dataHora(d)) == "a = 1979-05-27 08:32:00z\n")
    var h = DataHora(tipo: .hora); h.hora = 9; h.minuto = 5
    #expect(try troca("a = 07:32:00.500\n", k("a"), .dataHora(h)) == "a = 09:05:00\n")
    var l = DataHora(tipo: .local); l.ano = 2026; l.mes = 12; l.dia = 31; l.hora = 23; l.minuto = 59
    #expect(try troca("a = 2026-01-01T00:00:00\n", k("a"), .dataHora(l)) == "a = 2026-12-31T23:59:00\n")
    var f = DataHora(tipo: .comFuso); f.ano = 2026; f.mes = 3; f.dia = 4; f.fusoMinutos = -180; f.fusoZ = false
    #expect(try troca("a = 2026-01-01T00:00:00Z\n", k("a"), .dataHora(f)) == "a = 2026-03-04T00:00:00-03:00\n")
}

@Test func listaDeUmaLinha() throws {
    let t = "portas = [ 8080, 8443 ]  # web\n"
    #expect(try troca(t, k("portas"), .lista([.inteiro(8080), .inteiro(9000)])) == "portas = [ 8080, 9000 ]  # web\n")
    #expect(try troca(t, k("portas"), .lista([.inteiro(8080), .inteiro(8443), .inteiro(1)])) == "portas = [ 8080, 8443, 1 ]  # web\n")
    #expect(try troca(t, k("portas"), .lista([.inteiro(1)])) == "portas = [ 1 ]  # web\n")
    #expect(try troca("a = ['x','y',]\n", k("a"), .lista([.texto("z")])) == "a = ['z',]\n")
    #expect(try troca("a = []\n", k("a"), .lista([.texto("z")])) == "a = [\"z\"]\n")
    #expect(try troca("a = [1, 2]\n", k("a"), .lista([])) == "a = []\n")
}

@Test func listaDeVariasLinhas() throws {
    let t = "a = [\n  \"um\",\n  \"dois\",\n]\nb = 1\n"
    #expect(try troca(t, k("a"), .lista([.texto("um"), .texto("dois"), .texto("três")]))
            == "a = [\n  \"um\",\n  \"dois\",\n  \"três\",\n]\nb = 1\n")
    #expect(try troca(t, k("a"), .lista([.texto("só")])) == "a = [\n  \"só\",\n]\nb = 1\n")
    // sem vírgula final e com recuo de 4
    let u = "a = [\n    1,\n    2\n]\n"
    #expect(try troca(u, k("a"), .lista([.inteiro(1), .inteiro(2), .inteiro(3)])) == "a = [\n    1,\n    2,\n    3\n]\n")
    // mesmo número de itens: troca só o item, comentários internos ficam
    let c = "a = [\n  1, # um\n  2, # dois\n]\n"
    #expect(try troca(c, k("a"), .lista([.inteiro(1), .inteiro(20)])) == "a = [\n  1, # um\n  20, # dois\n]\n")
    // CRLF
    let w = "a = [\r\n  1,\r\n]\r\n"
    #expect(try troca(w, k("a"), .lista([.inteiro(1), .inteiro(2)])) == "a = [\r\n  1,\r\n  2,\r\n]\r\n")
}

@Test func valorCruValidado() throws {
    let t = "m = [1, \"a\"] # misto\n"
    let r = s(try Gravar.aplicar(b(t), alteracoes: [k("m"): .cru("[1, \"a\", 2.5]")]))
    #expect(r == "m = [1, \"a\", 2.5] # misto\n")
    #expect(throws: ErroGravar.self) { try Gravar.aplicar(b(t), alteracoes: [k("m"): .cru("[1, ")]) }
    #expect(throws: ErroGravar.self) { try Gravar.aplicar(b(t), alteracoes: [k("m"): .cru("1\nx = 2")]) }
}

@Test func caminhoInexistente() {
    #expect(throws: ErroGravar.self) { try Gravar.aplicar(b("a = 1\n"), alteracoes: [k("b"): .valor(.inteiro(1))]) }
}

@Test func itemDeListaDeTabelas() throws {
    let t = "[[t]]\nnome = \"a\"\n[[t]]\nnome = \"b\"\n"
    let r = try troca(t, [.chave("t"), .indice(1), .chave("nome")], .texto("c"))
    #expect(r == "[[t]]\nnome = \"a\"\n[[t]]\nnome = \"c\"\n")
}

@Test func bomECrlfPreservados() throws {
    let t: [UInt8] = [0xEF, 0xBB, 0xBF] + b("a = 1\r\nb = 2\r\n")
    let r = try Gravar.aplicar(t, alteracoes: [k("b"): .valor(.inteiro(3))])
    #expect(r == [0xEF, 0xBB, 0xBF] + b("a = 1\r\nb = 3\r\n"))
}

// MARK: - Edição (estado do documento)

@Test func edicaoTextoEDesfazer() throws {
    var ed = EdicaoTOML(b("a = 1\n"))
    try ed.definir(k("a"), .valor(.inteiro(2)))
    let antes = ed.instantaneo
    try ed.trocarTexto(b("a = 2\nb = 3\n"))
    #expect(ed.alteracoes.isEmpty)
    #expect(try ed.resultado() == b("a = 2\nb = 3\n"))
    #expect(throws: ErroTOML.self) { try ed.trocarTexto(b("a = \n")) }
    ed.restaurar(antes)
    #expect(try ed.resultado() == b("a = 2\n"))
    ed.gravado(try ed.resultado())
    #expect(!ed.temAlteracoes)
    #expect(ed.disco == b("a = 2\n"))
    // voltar ao valor antigo depois de gravar é uma alteração nova
    try ed.definir(k("a"), .valor(.inteiro(1)))
    #expect(ed.temAlteracoes)
}

@Test func diferencaPorLinhas() {
    let d = Diferenca.linhas(b("a\nb\nc\n"), b("a\nB\nc\nd\n"))
    #expect(d == [Trecho(linhaAntes: 2, linhaDepois: 2, removidas: ["b"], adicionadas: ["B"]),
                  Trecho(linhaAntes: 4, linhaDepois: 4, removidas: [], adicionadas: ["d"])])
    #expect(Diferenca.linhas(b("x\n"), b("x\n")).isEmpty)
}

// MARK: - Campos

@Test func camposDoExemplo() throws {
    let t = """
    titulo = "Painel"
    [servidor]
    # debug | info | aviso | erro
    nivel = "info"
    tls = true # exige certificado
    portas = [8080, 8443]
    misto = [1, "a"]
    pt = { x = 1 }
    quando = 2026-12-31T23:59:00
    [[tarefas]]
    nome = "backup"
    [[tarefas]]
    cron = "0 4 * * 0"
    """
    let secoes = Campos.secoes(try Leitor.ler(t))
    #expect(secoes.map(\.titulo) == ["Raiz", "servidor", "backup", "item 2"])
    #expect(secoes[2].grupo == "tarefas" && secoes[2].totalItens == 2 && secoes[3].indiceItem == 1)
    let s = secoes[1].campos
    #expect(s[0].tipo == .escolha(["debug", "info", "aviso", "erro"]))
    #expect(s[1].tipo == .booleano && s[1].ajuda == "exige certificado")
    #expect(s[2].tipo == .lista(.inteiro))
    #expect(s[3].tipo == .cru && s[4].tipo == .cru)
    #expect(s[5].tipo == .data(.local))
}

@Test func alteracaoDuranteGravacaoNaoSePerde() throws {
    var ed = EdicaoTOML(b("a = 1\nb = 1\n"))
    try ed.definir(k("a"), .valor(.inteiro(2)))
    let gravando = try ed.resultado()
    try ed.definir(k("b"), .valor(.inteiro(3)))  // chega enquanto grava
    ed.gravado(gravando)
    #expect(ed.disco == b("a = 2\nb = 1\n"))
    #expect(try ed.resultado() == b("a = 2\nb = 3\n"))
    #expect(ed.temAlteracoes)
}
