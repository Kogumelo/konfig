import Testing
@testable import ConfCore

private func abertura(_ texto: String, _ formato: Formato = .toml) throws -> String? {
    Campos.comentarioDeAbertura(try formato.ler(Array(texto.utf8)))
}

private func troca(_ texto: String, _ novo: String, _ formato: Formato = .toml) throws -> String? {
    guard let r = Abertura.trocar(Array(texto.utf8), formato: formato, por: novo) else { return nil }
    _ = try formato.ler(r)   // continua válido
    return String(decoding: r, as: UTF8.self)
}

let calendario = """
    # O calendário dos desafios.
    #
    #   - um evento novo só começa em data futura
    #   - a chave é para sempre

    # Campos: chave, rotulo

    # O desafio de todo dia
    [[desafio]]
    chave = "azul"

    """

@Test func aberturaSeparadaPorLinhaEmBranco() throws {
    #expect(try abertura(calendario) == """
        O calendário dos desafios.

          - um evento novo só começa em data futura
          - a chave é para sempre

        Campos: chave, rotulo
        """)
    // o bloco colado ao cabeçalho continua sendo a ajuda da seção, e só dela
    let doc = try Leitor.ler(Array(calendario.utf8))
    #expect(Campos.secoes(doc).first { $0.grupo == "desafio" }?.ajuda == "O desafio de todo dia")
}

@Test func aberturaColadaEhAjudaDoCampo() throws {
    #expect(try abertura("# nome do painel\ntitulo = \"x\"\n") == nil)
    #expect(try abertura("titulo = \"x\"\n# depois\n") == nil)
    #expect(try abertura("") == nil)
    #expect(try abertura("\u{FEFF}# só comentário\r\n\r\na = 1\r\n") == "só comentário")
    #expect(try abertura("\n\n# solto\n\n\na = 1\n") == "solto")
}

@Test func aberturaOutrosFormatos() throws {
    #expect(try abertura("; Geral\n# ainda\n\n[s]\na = 1\n", .ini) == "Geral\nainda")
    #expect(try abertura("# segredos\n\nA=1\n", .env) == "segredos")
    #expect(try abertura("// tsconfig\n{\n  \"a\": 1\n}\n", .json) == "tsconfig")
    #expect(try abertura("# compose\n\n---\nname: x\n", .yaml) == "compose")
    #expect(try abertura("# compose\n---\nname: x\n", .yaml) == nil)   // ajuda de `name`
}

@Test func trocarSoAsLinhasQueMudaram() throws {
    let novo = """
        O calendário dos desafios.

          - um evento novo só começa em data FUTURA
          - a chave é para sempre

        Campos: chave, rotulo, idiomas
        """
    #expect(try troca(calendario, novo) == """
        # O calendário dos desafios.
        #
        #   - um evento novo só começa em data FUTURA
        #   - a chave é para sempre

        # Campos: chave, rotulo, idiomas

        # O desafio de todo dia
        [[desafio]]
        chave = "azul"

        """)
    // sem mudança: os mesmos bytes
    #expect(try troca(calendario, try #require(try abertura(calendario))) == calendario)
}

@Test func trocarAcrescentaEApaga() throws {
    #expect(try troca("# a\n\nx = 1\n", "a\nb\n\nc") == "# a\n# b\n#\n# c\n\nx = 1\n")
    #expect(try troca("# a\n# b\n\n# ajuda\nx = 1\n", "") == "# ajuda\nx = 1\n")
    #expect(try troca("x = 1\n", "novo") == nil)
}

@Test func trocarMantemMarcadorCRLFeBOM() throws {
    #expect(try troca("\u{FEFF}; velho\r\n\r\n[s]\r\na = 1\r\n", "novo\nsegunda", .ini)
            == "\u{FEFF}; novo\r\n; segunda\r\n\r\n[s]\r\na = 1\r\n")
    #expect(try troca("// velho\n{ \"a\": 1 }\n", "novo", .json) == "// novo\n{ \"a\": 1 }\n")
}
