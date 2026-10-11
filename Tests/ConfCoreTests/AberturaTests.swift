import Testing
@testable import ConfCore

private func abertura(_ texto: String, _ formato: Formato = .toml) throws -> String? {
    Campos.comentarioDeAbertura(try formato.ler(Array(texto.utf8)))
}

@Test func aberturaSeparadaPorLinhaEmBranco() throws {
    let t = """
        # O calendário dos desafios.
        #
        #   - um evento novo só começa em data futura
        #   - a chave é para sempre

        # Campos: chave, rotulo

        # O desafio de todo dia
        [[desafio]]
        chave = "azul"
        """
    #expect(try abertura(t) == """
        O calendário dos desafios.

          - um evento novo só começa em data futura
          - a chave é para sempre

        Campos: chave, rotulo
        """)
    // o bloco colado ao cabeçalho continua sendo a ajuda da seção, e só dela
    let doc = try Leitor.ler(Array(t.utf8))
    #expect(Campos.secoes(doc).first { $0.grupo == "desafio" }?.ajuda == "O desafio de todo dia")
}

@Test func aberturaColadaEhAjudaDoCampo() throws {
    #expect(try abertura("# nome do painel\ntitulo = \"x\"\n") == nil)
    #expect(try abertura("titulo = \"x\"\n# depois\n") == nil)
    #expect(try abertura("") == nil)
    #expect(try abertura("\u{FEFF}# só comentário\r\n\r\na = 1\r\n") == "só comentário")
}

@Test func aberturaOutrosFormatos() throws {
    #expect(try abertura("; Geral\n# ainda\n\n[s]\na = 1\n", .ini) == "Geral\nainda")
    #expect(try abertura("# segredos\n\nA=1\n", .env) == "segredos")
    #expect(try abertura("// tsconfig\n{\n  \"a\": 1\n}\n", .json) == "tsconfig")
    #expect(try abertura("# compose\n\n---\nname: x\n", .yaml) == "compose")
    #expect(try abertura("# compose\n---\nname: x\n", .yaml) == nil)   // ajuda de `name`
    #expect(try abertura("# nome\nname: x\n", .yaml) == nil)
}
