import Foundation

/// Leitor de TOML 1.0 que guarda a posição (em bytes UTF-8) de cada valor.
///
/// Trabalha direto sobre os bytes: cada função de leitura consome um "token"
/// (chave, texto, número, data, pontuação) e a montagem da estrutura segue as
/// regras de redefinição do TOML 1.0.
public enum Leitor {
    /// Lê um arquivo TOML inteiro.
    public static func ler(_ bytes: [UInt8]) throws(ErroTOML) -> DocumentoTOML {
        let a = Analisador(bytes)
        return try a.documento()
    }

    public static func ler(_ texto: String) throws(ErroTOML) -> DocumentoTOML {
        try ler(Array(texto.utf8))
    }

    /// Lê um valor isolado (o lado direito de `chave = valor`), como `[1, 2]` ou `"abc"`.
    /// Aceita várias linhas quando o próprio valor permite (listas, textos `"""`).
    public static func lerValor(_ texto: String) throws(ErroTOML) -> Valor {
        let prefixo = "v = "
        let doc: DocumentoTOML
        do {
            doc = try ler(Array((prefixo + texto).utf8))
        } catch {
            var e = error
            if e.linha == 1 { e.coluna = max(1, e.coluna - prefixo.count) }
            e.deslocamento = max(0, e.deslocamento - prefixo.utf8.count)
            throw e
        }
        guard doc.cabecalhos.isEmpty, doc.entradas.count == 1, let v = doc.raiz["v"] else {
            throw ErroTOML(mensagem: "esperado um único valor", linha: 1, coluna: 1, deslocamento: 0)
        }
        return v
    }
}

// MARK: - Constantes

private let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09, ESP: UInt8 = 0x20
private let ASPA: UInt8 = 0x22, APOS: UInt8 = 0x27, BARRA: UInt8 = 0x5C, CERQ: UInt8 = 0x23
private let ABRE_COL: UInt8 = 0x5B, FECHA_COL: UInt8 = 0x5D, ABRE_CH: UInt8 = 0x7B, FECHA_CH: UInt8 = 0x7D
private let IGUAL: UInt8 = 0x3D, PONTO: UInt8 = 0x2E, VIRG: UInt8 = 0x2C

@inline(__always) private func ehDigito(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(__always) private func ehHex(_ c: UInt8) -> Bool {
    ehDigito(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
}
/// Caracteres de controle proibidos em comentários e textos (tab é permitido).
@inline(__always) private func ehControleProibido(_ c: UInt8) -> Bool {
    (c < 0x20 && c != TAB) || c == 0x7F
}

// MARK: - Árvore em construção

private typealias Nome = [UInt8]

private final class NoTabela {
    var ordem: [Nome] = []
    var itens: [Nome: NoItem] = [:]

    func converte() -> Tabela {
        Tabela(pares: ordem.map { n in
            Tabela.Par(chave: String(decoding: n, as: UTF8.self), valor: itens[n]!.converte())
        })
    }
}

private enum NoItem {
    case valor(Valor)
    case tabela(NoTabela)
    case lista(NoLista)

    func converte() -> Valor {
        switch self {
        case .valor(let v): return v
        case .tabela(let t): return .tabela(t.converte())
        case .lista(let l): return .lista(l.tabelas.map { .tabela($0.converte()) })
        }
    }
}

private final class NoLista {
    var tabelas: [NoTabela] = []
}

/// Marcas de "já definida" e "imutável" por caminho de nomes (sem índices),
/// no mesmo esquema do tomli: uma `[[lista]]` nova limpa as marcas do item anterior.
private final class Bandeiras {
    enum Tipo { case congelada, explicita }

    final class No {
        var marcas = Set<Tipo>()
        var recursivas = Set<Tipo>()
        var filhos: [Nome: No] = [:]
    }

    let raiz = No()
    var pendentes: [([Nome], Tipo)] = []

    func pendente(_ k: [Nome], _ t: Tipo) { pendentes.append((k, t)) }

    func finalizaPendentes() {
        for (k, t) in pendentes { define(k, t, recursiva: false) }
        pendentes.removeAll()
    }

    func limpaTudo(_ k: [Nome]) {
        var no = raiz
        for x in k.dropLast() {
            guard let n = no.filhos[x] else { return }
            no = n
        }
        no.filhos[k.last!] = nil
    }

    func define(_ k: [Nome], _ t: Tipo, recursiva: Bool) {
        var no = raiz
        for x in k {
            if let n = no.filhos[x] { no = n } else { let n = No(); no.filhos[x] = n; no = n }
        }
        if recursiva { no.recursivas.insert(t) } else { no.marcas.insert(t) }
    }

    func tem(_ k: [Nome], _ t: Tipo) -> Bool {
        guard let ultimo = k.last else { return false }
        var no = raiz
        for x in k.dropLast() {
            guard let n = no.filhos[x] else { return false }
            if n.recursivas.contains(t) { return true }
            no = n
        }
        guard let n = no.filhos[ultimo] else { return false }
        return n.marcas.contains(t) || n.recursivas.contains(t)
    }
}

// MARK: - Analisador

private final class Analisador {
    let b: [UInt8]
    var p = 0
    let inicio: Int

    let raiz = NoTabela()
    let bandeiras = Bandeiras()
    /// Nomes do cabeçalho atual (sem índices) e caminho concreto da tabela atual.
    var cabecalhoNomes: [Nome] = []
    var secaoAtual: Int? = nil

    var entradas: [Entrada] = []
    var cabecalhos: [Cabecalho] = []
    var comentariosAcima: [String] = []

    /// Início de cada linha, para converter deslocamento em linha/coluna.
    lazy var iniciosDeLinha: [Int] = {
        var r = [0]
        for (i, c) in b.enumerated() where c == LF { r.append(i + 1) }
        return r
    }()

    init(_ bytes: [UInt8]) {
        b = bytes
        inicio = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
    }

    // MARK: Utilidades

    @inline(__always) var atual: UInt8? { p < b.count ? b[p] : nil }
    @inline(__always) func olha(_ k: Int) -> UInt8? { p + k < b.count ? b[p + k] : nil }

    func linhaColuna(_ off: Int) -> (Int, Int) {
        let off = min(max(off, 0), b.count)
        // busca binária pela linha
        var lo = 0, hi = iniciosDeLinha.count - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if iniciosDeLinha[m] <= off { lo = m } else { hi = m - 1 }
        }
        var ini = iniciosDeLinha[lo]
        if lo == 0 { ini = max(ini, inicio) }
        var col = 1
        if ini < off {
            for i in ini..<off where b[i] & 0xC0 != 0x80 { col += 1 }
        }
        return (lo + 1, col)
    }

    func erro(_ msg: String, em off: Int? = nil) -> ErroTOML {
        let o = off ?? p
        let (l, c) = linhaColuna(o)
        return ErroTOML(mensagem: msg, linha: l, coluna: c, deslocamento: o)
    }

    func descreve(_ c: UInt8?) -> String {
        guard let c else { return "fim do arquivo" }
        switch c {
        case LF, CR: return "fim de linha"
        case TAB: return "tabulação"
        case ESP: return "espaço"
        case 0x21...0x7E: return "'\(String(UnicodeScalar(c)))'"
        default: return String(format: "byte 0x%02X", c)
        }
    }

    func pulaEspacos() {
        while p < b.count, b[p] == ESP || b[p] == TAB { p += 1 }
    }

    /// Consome uma quebra de linha (LF ou CRLF).
    func novaLinha() throws(ErroTOML) {
        if atual == LF { p += 1; return }
        if atual == CR {
            if olha(1) == LF { p += 2; return }
            throw erro("CR (\\r) sozinho; use LF ou CRLF como quebra de linha")
        }
        throw erro("esperada quebra de linha, encontrado \(descreve(atual))")
    }

    /// Lê um comentário começando no `#`. Devolve o texto sem `#` e sem espaços nas pontas.
    func comentario() throws(ErroTOML) -> String {
        p += 1
        let ini = p
        while p < b.count {
            let c = b[p]
            if c == LF { break }
            if c == CR {
                if olha(1) == LF { break }
                throw erro("CR (\\r) sozinho dentro de comentário")
            }
            if ehControleProibido(c) { throw erro("caractere de controle não permitido em comentário") }
            p += 1
        }
        return String(decoding: b[ini..<p], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// Depois de um valor ou cabeçalho: espaços, comentário opcional e fim de linha.
    func fimDeLinha() throws(ErroTOML) -> String? {
        pulaEspacos()
        var c: String? = nil
        if atual == CERQ { c = try comentario() }
        if atual == nil { return c }
        if atual == LF || atual == CR {
            try novaLinha()
            return c
        }
        throw erro("esperado fim de linha depois do valor, encontrado \(descreve(atual))")
    }

    /// Espaços, quebras de linha e comentários (dentro de listas).
    func pulaEspacosLinhasComentarios() throws(ErroTOML) {
        while let c = atual {
            if c == ESP || c == TAB { p += 1 }
            else if c == LF || c == CR { try novaLinha() }
            else if c == CERQ { _ = try comentario() }
            else { break }
        }
    }

    // MARK: Validação de UTF-8

    func validaUTF8() throws(ErroTOML) {
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c < 0x80 { i += 1; continue }
            var tam = 0, minimo: UInt32 = 0, v: UInt32 = 0
            if c & 0xE0 == 0xC0 { tam = 2; minimo = 0x80; v = UInt32(c & 0x1F) }
            else if c & 0xF0 == 0xE0 { tam = 3; minimo = 0x800; v = UInt32(c & 0x0F) }
            else if c & 0xF8 == 0xF0 { tam = 4; minimo = 0x10000; v = UInt32(c & 0x07) }
            else { throw erro("UTF-8 inválido", em: i) }
            guard i + tam <= n else { throw erro("UTF-8 inválido (sequência incompleta)", em: i) }
            for k in 1..<tam {
                let d = b[i + k]
                guard d & 0xC0 == 0x80 else { throw erro("UTF-8 inválido", em: i) }
                v = (v << 6) | UInt32(d & 0x3F)
            }
            if v < minimo || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) {
                throw erro("UTF-8 inválido", em: i)
            }
            i += tam
        }
    }

    // MARK: Documento

    func documento() throws(ErroTOML) -> DocumentoTOML {
        try validaUTF8()
        p = inicio
        while true {
            pulaEspacos()
            guard let c = atual else { break }
            switch c {
            case CERQ:
                comentariosAcima.append(try comentario())
                if atual != nil { try novaLinha() }
            case LF, CR:
                try novaLinha()
                comentariosAcima.removeAll()
            case ABRE_COL:
                bandeiras.finalizaPendentes()
                try cabecalho()
            default:
                try parChaveValor()
            }
        }
        var quebra = "\n"
        if let i = b.firstIndex(of: LF), i > 0, b[i - 1] == CR { quebra = "\r\n" }
        return DocumentoTOML(bytes: b, raiz: raiz.converte(), entradas: entradas, cabecalhos: cabecalhos,
                             quebraDeLinha: quebra, temBOM: inicio == 3)
    }

    // MARK: Chaves

    struct ChaveLida {
        var partes: [Nome]
        var intervalo: Range<Int>
        var texto: String
    }

    func chave() throws(ErroTOML) -> ChaveLida {
        var partes: [Nome] = []
        pulaEspacos()
        let ini = p
        var fim = p
        while true {
            pulaEspacos()
            partes.append(try chaveSimples())
            fim = p
            pulaEspacos()
            if atual == PONTO { p += 1; continue }
            break
        }
        return ChaveLida(partes: partes, intervalo: ini..<fim, texto: String(decoding: b[ini..<fim], as: UTF8.self))
    }

    func chaveSimples() throws(ErroTOML) -> Nome {
        guard let c = atual else { throw erro("chave esperada, encontrado fim do arquivo") }
        if c == ASPA {
            if olha(1) == ASPA && olha(2) == ASPA { throw erro("texto de várias linhas não pode ser chave") }
            return Array(try textoBasico().utf8)
        }
        if c == APOS {
            if olha(1) == APOS && olha(2) == APOS { throw erro("texto de várias linhas não pode ser chave") }
            return Array(try textoLiteral().utf8)
        }
        let ini = p
        while let d = atual, ehCaractereChaveSimples(d) { p += 1 }
        if p == ini { throw erro("chave esperada, encontrado \(descreve(c))") }
        return Array(b[ini..<p])
    }

    func nomeLegivel(_ k: [Nome]) -> String {
        k.map { Segmento.chaveFormatada(String(decoding: $0, as: UTF8.self)) }.joined(separator: ".")
    }

    // MARK: Estrutura

    /// Anda (criando tabelas implícitas) até o caminho; em `[[listas]]` entra no último item.
    func criaOuObtem(_ k: [Nome], em base: NoTabela? = nil, acessaListas: Bool = true,
                     erroEm: Int) throws(ErroTOML) -> (NoTabela, Caminho) {
        var t = base ?? raiz
        var cam: Caminho = []
        for (i, n) in k.enumerated() {
            cam.append(.chave(String(decoding: n, as: UTF8.self)))
            switch t.itens[n] {
            case nil:
                let novo = NoTabela()
                t.itens[n] = .tabela(novo)
                t.ordem.append(n)
                t = novo
            case .tabela(let x)?:
                t = x
            case .lista(let l)? where acessaListas:
                cam.append(.indice(l.tabelas.count - 1))
                t = l.tabelas[l.tabelas.count - 1]
            default:
                throw erro("'\(nomeLegivel(Array(k[...i])))' já tem um valor que não é tabela", em: erroEm)
            }
        }
        return (t, cam)
    }

    func cabecalho() throws(ErroTOML) {
        let ini = p
        let ehLista = olha(1) == ABRE_COL
        p += ehLista ? 2 : 1
        let k = try chave()
        pulaEspacos()
        if ehLista {
            guard atual == FECHA_COL, olha(1) == FECHA_COL else {
                throw erro("esperado ']]' no fim do cabeçalho, encontrado \(descreve(atual))")
            }
            p += 2
        } else {
            guard atual == FECHA_COL else { throw erro("esperado ']' no fim do cabeçalho, encontrado \(descreve(atual))") }
            p += 1
        }
        let fim = p
        let nome = nomeLegivel(k.partes)
        var caminho: Caminho
        if ehLista {
            if bandeiras.tem(k.partes, .congelada) {
                throw erro("'\(nome)' é uma lista ou tabela escrita direto no valor e não pode ser estendida", em: k.intervalo.lowerBound)
            }
            bandeiras.limpaTudo(k.partes)
            bandeiras.define(k.partes, .explicita, recursiva: false)
            let (pai, cam) = try criaOuObtem(Array(k.partes.dropLast()), erroEm: k.intervalo.lowerBound)
            let ultimo = k.partes.last!
            caminho = cam + [.chave(String(decoding: ultimo, as: UTF8.self))]
            switch pai.itens[ultimo] {
            case nil:
                let l = NoLista()
                l.tabelas.append(NoTabela())
                pai.itens[ultimo] = .lista(l)
                pai.ordem.append(ultimo)
                caminho.append(.indice(0))
            case .lista(let l)?:
                l.tabelas.append(NoTabela())
                caminho.append(.indice(l.tabelas.count - 1))
            default:
                throw erro("'\(nome)' já foi definido e não é uma lista de tabelas", em: k.intervalo.lowerBound)
            }
        } else {
            if bandeiras.tem(k.partes, .explicita) || bandeiras.tem(k.partes, .congelada) {
                throw erro("a tabela '\(nome)' já foi definida", em: k.intervalo.lowerBound)
            }
            bandeiras.define(k.partes, .explicita, recursiva: false)
            (_, caminho) = try criaOuObtem(k.partes, erroEm: k.intervalo.lowerBound)
        }
        cabecalhoNomes = k.partes
        let comentarioFim = try fimDeLinha()
        cabecalhos.append(Cabecalho(
            caminho: caminho,
            nomes: k.partes.map { String(decoding: $0, as: UTF8.self) },
            ehListaDeTabelas: ehLista,
            intervalo: ini..<fim,
            linha: linhaColuna(ini).0,
            comentarioAcima: comentariosAcima,
            comentarioFim: comentarioFim))
        comentariosAcima.removeAll()
        secaoAtual = cabecalhos.count - 1
    }

    func parChaveValor() throws(ErroTOML) {
        let k = try chave()
        pulaEspacos()
        guard atual == IGUAL else { throw erro("esperado '=' depois da chave, encontrado \(descreve(atual))") }
        p += 1
        pulaEspacos()
        let (v, pos) = try valor()

        let pai = Array(k.partes.dropLast()), ultimo = k.partes.last!
        let paiAbs = cabecalhoNomes + pai
        if k.partes.count > 1 {
            for i in 1..<k.partes.count {
                let cont = cabecalhoNomes + Array(k.partes[0..<i])
                if bandeiras.tem(cont, .explicita) {
                    throw erro("a tabela '\(nomeLegivel(cont))' já foi definida e não pode ser redefinida com chave pontilhada",
                               em: k.intervalo.lowerBound)
                }
                bandeiras.pendente(cont, .explicita)
            }
        }
        if bandeiras.tem(paiAbs, .congelada) {
            throw erro("'\(nomeLegivel(paiAbs))' é uma tabela escrita direto no valor e não aceita novas chaves",
                       em: k.intervalo.lowerBound)
        }
        let (t, cam) = try criaOuObtem(paiAbs, erroEm: k.intervalo.lowerBound)
        if t.itens[ultimo] != nil {
            throw erro("a chave '\(nomeLegivel(cabecalhoNomes + k.partes))' já foi definida", em: k.intervalo.lowerBound)
        }
        switch v {
        case .lista, .tabela: bandeiras.define(cabecalhoNomes + k.partes, .congelada, recursiva: true)
        default: break
        }
        t.itens[ultimo] = .valor(v)
        t.ordem.append(ultimo)

        let fimValor = p
        let comentarioFim = try fimDeLinha()
        entradas.append(Entrada(
            caminho: cam + [.chave(String(decoding: ultimo, as: UTF8.self))],
            chaveEscrita: k.texto,
            valor: v,
            posicao: pos,
            intervaloChave: k.intervalo,
            linha: linhaColuna(k.intervalo.lowerBound).0,
            linhaFinal: linhaColuna(fimValor).0,
            comentarioAcima: comentariosAcima,
            comentarioFim: comentarioFim,
            secao: secaoAtual))
        comentariosAcima.removeAll()
    }

    // MARK: Valores

    func valor() throws(ErroTOML) -> (Valor, Posicao) {
        guard let c = atual else { throw erro("valor esperado, encontrado fim do arquivo") }
        let ini = p
        let v: Valor
        var itens: [Posicao] = []
        switch c {
        case ASPA:
            if olha(1) == ASPA && olha(2) == ASPA { v = .texto(try textoMultiBasico()) }
            else { v = .texto(try textoBasico()) }
        case APOS:
            if olha(1) == APOS && olha(2) == APOS { v = .texto(try textoMultiLiteral()) }
            else { v = .texto(try textoLiteral()) }
        case 0x74 /* t */:
            try palavra("true"); v = .booleano(true)
        case 0x66 /* f */:
            try palavra("false"); v = .booleano(false)
        case ABRE_COL:
            let (l, pos) = try lista(); v = .lista(l); itens = pos
        case ABRE_CH:
            v = .tabela(try tabelaEmbutida())
        case LF, CR, CERQ:
            throw erro("valor esperado depois de '='")
        default:
            v = try numeroOuData()
        }
        return (v, Posicao(intervalo: ini..<p, itens: itens))
    }

    func palavra(_ s: String) throws(ErroTOML) {
        let u = Array(s.utf8)
        guard p + u.count <= b.count, Array(b[p..<(p + u.count)]) == u else {
            throw erro("valor inválido (esperado \(s))")
        }
        p += u.count
    }

    // MARK: Textos

    func escape(_ saida: inout [UInt8]) throws(ErroTOML) {
        let ini = p
        p += 1 // barra
        guard let c = atual else { throw erro("escape incompleto no fim do arquivo") }
        p += 1
        switch c {
        case 0x62: saida.append(0x08)          // \b
        case 0x74: saida.append(TAB)           // \t
        case 0x6E: saida.append(LF)            // \n
        case 0x66: saida.append(0x0C)          // \f
        case 0x72: saida.append(CR)            // \r
        case ASPA: saida.append(ASPA)
        case BARRA: saida.append(BARRA)
        case 0x75, 0x55:                        // \uXXXX, \UXXXXXXXX
            let n = c == 0x75 ? 4 : 8
            guard p + n <= b.count else { throw erro("escape \\\(UnicodeScalar(c)) incompleto", em: ini) }
            var v: UInt32 = 0
            for k in 0..<n {
                let d = b[p + k]
                guard ehHex(d) else { throw erro("escape \\\(UnicodeScalar(c)) com dígito hexadecimal inválido", em: ini) }
                v = v * 16 + UInt32(hexValor(d))
            }
            p += n
            guard let u = UnicodeScalar(v) else {
                throw erro("escape \\\(UnicodeScalar(c)) não é um caractere Unicode válido", em: ini)
            }
            saida.append(contentsOf: Array(String(Character(u)).utf8))
        default:
            throw erro("escape inválido '\\\(descreveSemAspas(c))'", em: ini)
        }
    }

    func descreveSemAspas(_ c: UInt8) -> String {
        (0x21...0x7E).contains(c) ? String(UnicodeScalar(c)) : String(format: "0x%02X", c)
    }

    func hexValor(_ d: UInt8) -> UInt8 {
        if ehDigito(d) { return d - 0x30 }
        if d >= 0x61 { return d - 0x61 + 10 }
        return d - 0x41 + 10
    }

    func textoBasico() throws(ErroTOML) -> String {
        let ini = p
        p += 1
        var s: [UInt8] = []
        while true {
            guard let c = atual else { throw erro("texto sem aspas de fechamento", em: ini) }
            if c == ASPA { p += 1; break }
            if c == BARRA { try escape(&s); continue }
            if c == LF || c == CR { throw erro("texto sem aspas de fechamento antes do fim da linha", em: ini) }
            if ehControleProibido(c) { throw erro("caractere de controle não permitido em texto") }
            s.append(c); p += 1
        }
        return String(decoding: s, as: UTF8.self)
    }

    func textoLiteral() throws(ErroTOML) -> String {
        let ini = p
        p += 1
        let iniConteudo = p
        while true {
            guard let c = atual else { throw erro("texto sem apóstrofo de fechamento", em: ini) }
            if c == APOS { break }
            if c == LF || c == CR { throw erro("texto sem apóstrofo de fechamento antes do fim da linha", em: ini) }
            if ehControleProibido(c) { throw erro("caractere de controle não permitido em texto") }
            p += 1
        }
        let s = String(decoding: b[iniConteudo..<p], as: UTF8.self)
        p += 1
        return s
    }

    /// Pula a quebra de linha logo depois do `"""`/`'''` de abertura.
    func pulaQuebraInicial() throws(ErroTOML) {
        if atual == LF { p += 1 }
        else if atual == CR && olha(1) == LF { p += 2 }
    }

    func textoMultiBasico() throws(ErroTOML) -> String {
        let ini = p
        p += 3
        try pulaQuebraInicial()
        var s: [UInt8] = []
        while true {
            guard let c = atual else { throw erro("texto de várias linhas sem \"\"\" de fechamento", em: ini) }
            if c == ASPA {
                var q = 0
                while olha(q) == ASPA { q += 1 }
                if q >= 3 {
                    if q > 5 { throw erro("aspas demais no fim do texto de várias linhas") }
                    s.append(contentsOf: [UInt8](repeating: ASPA, count: q - 3))
                    p += q
                    break
                }
                s.append(contentsOf: [UInt8](repeating: ASPA, count: q))
                p += q
                continue
            }
            if c == BARRA {
                // barra no fim da linha: junta com a próxima, descartando espaços e quebras
                var k = 1
                while let d = olha(k), d == ESP || d == TAB { k += 1 }
                if olha(k) == LF || (olha(k) == CR && olha(k + 1) == LF) {
                    p += k
                    while let d = atual {
                        if d == ESP || d == TAB { p += 1 }
                        else if d == LF || d == CR { try novaLinha() }
                        else { break }
                    }
                    continue
                }
                try escape(&s)
                continue
            }
            if c == LF { s.append(LF); p += 1; continue }
            if c == CR {
                guard olha(1) == LF else { throw erro("CR (\\r) sozinho dentro de texto") }
                s.append(LF); p += 2; continue
            }
            if ehControleProibido(c) { throw erro("caractere de controle não permitido em texto") }
            s.append(c); p += 1
        }
        return String(decoding: s, as: UTF8.self)
    }

    func textoMultiLiteral() throws(ErroTOML) -> String {
        let ini = p
        p += 3
        try pulaQuebraInicial()
        var s: [UInt8] = []
        while true {
            guard let c = atual else { throw erro("texto de várias linhas sem ''' de fechamento", em: ini) }
            if c == APOS {
                var q = 0
                while olha(q) == APOS { q += 1 }
                if q >= 3 {
                    if q > 5 { throw erro("apóstrofos demais no fim do texto de várias linhas") }
                    s.append(contentsOf: [UInt8](repeating: APOS, count: q - 3))
                    p += q
                    break
                }
                s.append(contentsOf: [UInt8](repeating: APOS, count: q))
                p += q
                continue
            }
            if c == LF { s.append(LF); p += 1; continue }
            if c == CR {
                guard olha(1) == LF else { throw erro("CR (\\r) sozinho dentro de texto") }
                s.append(LF); p += 2; continue
            }
            if ehControleProibido(c) { throw erro("caractere de controle não permitido em texto") }
            s.append(c); p += 1
        }
        return String(decoding: s, as: UTF8.self)
    }

    // MARK: Listas e tabelas embutidas

    func lista() throws(ErroTOML) -> ([Valor], [Posicao]) {
        let ini = p
        p += 1
        var vs: [Valor] = []
        var ps: [Posicao] = []
        while true {
            try pulaEspacosLinhasComentarios()
            if atual == FECHA_COL { p += 1; break }
            if atual == nil { throw erro("lista sem ']' de fechamento", em: ini) }
            let (v, pos) = try valor()
            vs.append(v); ps.append(pos)
            try pulaEspacosLinhasComentarios()
            if atual == VIRG { p += 1; continue }
            if atual == FECHA_COL { p += 1; break }
            if atual == nil { throw erro("lista sem ']' de fechamento", em: ini) }
            throw erro("esperado ',' ou ']' na lista, encontrado \(descreve(atual))")
        }
        return (vs, ps)
    }

    func tabelaEmbutida() throws(ErroTOML) -> Tabela {
        let ini = p
        p += 1
        let t = NoTabela()
        let marcas = Bandeiras()
        pulaEspacos()
        if atual == FECHA_CH { p += 1; return t.converte() }
        while true {
            let k = try chave()
            pulaEspacos()
            guard atual == IGUAL else { throw erro("esperado '=' depois da chave, encontrado \(descreve(atual))") }
            p += 1
            pulaEspacos()
            let (v, _) = try valor()
            if marcas.tem(k.partes, .congelada) {
                throw erro("'\(nomeLegivel(k.partes))' não pode ser estendida", em: k.intervalo.lowerBound)
            }
            let (pai, _) = try criaOuObtem(Array(k.partes.dropLast()), em: t, acessaListas: false,
                                           erroEm: k.intervalo.lowerBound)
            let ultimo = k.partes.last!
            if pai.itens[ultimo] != nil {
                throw erro("a chave '\(nomeLegivel(k.partes))' já foi definida nesta tabela", em: k.intervalo.lowerBound)
            }
            pai.itens[ultimo] = .valor(v)
            pai.ordem.append(ultimo)
            switch v {
            case .lista, .tabela: marcas.define(k.partes, .congelada, recursiva: true)
            default: break
            }
            pulaEspacos()
            if atual == VIRG {
                p += 1
                pulaEspacos()
                if atual == FECHA_CH { throw erro("vírgula no fim de tabela embutida não é permitida no TOML 1.0") }
                continue
            }
            if atual == FECHA_CH { p += 1; break }
            if atual == nil { throw erro("tabela embutida sem '}' de fechamento", em: ini) }
            throw erro("esperado ',' ou '}' na tabela embutida, encontrado \(descreve(atual))")
        }
        return t.converte()
    }

    // MARK: Números e datas

    func numeroOuData() throws(ErroTOML) -> Valor {
        let ini = p
        func ehDoToken(_ c: UInt8) -> Bool {
            ehDigito(c) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x5F || c == 0x2B || c == 0x2D || c == PONTO || c == 0x3A
        }
        while let c = atual, ehDoToken(c) { p += 1 }
        // data seguida de espaço e hora: `1979-05-27 07:32:00`
        if p - ini == 10, atual == ESP, let h1 = olha(1), let h2 = olha(2), ehDigito(h1), ehDigito(h2), olha(3) == 0x3A,
           b[ini + 4] == 0x2D, b[ini + 7] == 0x2D {
            p += 1
            while let c = atual, ehDoToken(c) { p += 1 }
        }
        if p == ini { throw erro("valor inválido: \(descreve(atual))") }
        let tok = Array(b[ini..<p])
        if tok.count >= 10, tok[4] == 0x2D, tok[0..<4].allSatisfy(ehDigito) {
            return .dataHora(try dataHora(tok, ini))
        }
        if tok.count >= 5, tok[2] == 0x3A, ehDigito(tok[0]), ehDigito(tok[1]) {
            return .dataHora(try soHora(tok, ini))
        }
        return try numero(tok, ini)
    }

    /// Tira os `_` checando que cada um está entre dois dígitos válidos.
    func semSublinhados(_ s: ArraySlice<UInt8>, _ ehValido: (UInt8) -> Bool, _ off: Int) throws(ErroTOML) -> [UInt8] {
        var r: [UInt8] = []
        var anterior: UInt8? = nil
        for c in s {
            if c == 0x5F {
                guard let a = anterior, a != 0x5F else { throw erro("'_' precisa ficar entre dois dígitos", em: off) }
            } else {
                guard ehValido(c) else { throw erro("número inválido: '\(String(decoding: s, as: UTF8.self))'", em: off) }
                r.append(c)
            }
            anterior = c
        }
        if anterior == 0x5F { throw erro("'_' precisa ficar entre dois dígitos", em: off) }
        if r.isEmpty { throw erro("número sem dígitos", em: off) }
        return r
    }

    func numero(_ tok: [UInt8], _ off: Int) throws(ErroTOML) -> Valor {
        let s = String(decoding: tok, as: UTF8.self)
        switch s {
        case "inf", "+inf": return .decimal(.infinity)
        case "-inf": return .decimal(-.infinity)
        case "nan", "+nan": return .decimal(.nan)
        case "-nan": return .decimal(-.nan)
        default: break
        }
        // bases 16, 8 e 2: sem sinal
        if tok.count > 2, tok[0] == 0x30, tok[1] == 0x78 || tok[1] == 0x6F || tok[1] == 0x62 {
            let base: UInt64, valido: (UInt8) -> Bool
            switch tok[1] {
            case 0x78: base = 16; valido = ehHex
            case 0x6F: base = 8; valido = { $0 >= 0x30 && $0 <= 0x37 }
            default: base = 2; valido = { $0 == 0x30 || $0 == 0x31 }
            }
            let dig = try semSublinhados(tok[2...], valido, off)
            var v: UInt64 = 0
            for d in dig {
                let (m, o1) = v.multipliedReportingOverflow(by: base)
                let (a, o2) = m.addingReportingOverflow(UInt64(hexValor(d)))
                if o1 || o2 || a > UInt64(Int64.max) { throw erro("inteiro fora do limite de 64 bits", em: off) }
                v = a
            }
            return .inteiro(Int64(v))
        }
        var i = 0
        var negativo = false
        if tok.first == 0x2B || tok.first == 0x2D { negativo = tok.first == 0x2D; i = 1 }
        // parte inteira
        var j = i
        while j < tok.count, ehDigito(tok[j]) || tok[j] == 0x5F { j += 1 }
        guard j > i else { throw erro("valor inválido: '\(s)'", em: off) }
        let inteiro = try semSublinhados(tok[i..<j], ehDigito, off)
        if inteiro.count > 1 && inteiro[0] == 0x30 { throw erro("zeros à esquerda não são permitidos: '\(s)'", em: off) }
        if j == tok.count {
            // inteiro decimal
            var v: Int64 = 0
            for d in inteiro {
                let dv = Int64(d - 0x30)
                let (m, o1) = v.multipliedReportingOverflow(by: 10)
                let (a, o2) = negativo ? m.subtractingReportingOverflow(dv) : m.addingReportingOverflow(dv)
                if o1 || o2 { throw erro("inteiro fora do limite de 64 bits", em: off) }
                v = a
            }
            return .inteiro(v)
        }
        // decimal: fração e/ou expoente
        var texto = (negativo ? "-" : "") + String(decoding: inteiro, as: UTF8.self)
        if tok[j] == PONTO {
            var k = j + 1
            while k < tok.count, ehDigito(tok[k]) || tok[k] == 0x5F { k += 1 }
            guard k > j + 1 else { throw erro("decimal precisa de dígitos depois do ponto: '\(s)'", em: off) }
            texto += "." + String(decoding: try semSublinhados(tok[(j + 1)..<k], ehDigito, off), as: UTF8.self)
            j = k
        }
        if j < tok.count, tok[j] == 0x65 || tok[j] == 0x45 {
            var k = j + 1
            var sinal = ""
            if k < tok.count, tok[k] == 0x2B || tok[k] == 0x2D { sinal = tok[k] == 0x2D ? "-" : "+"; k += 1 }
            guard k < tok.count else { throw erro("expoente sem dígitos: '\(s)'", em: off) }
            texto += "e" + sinal + String(decoding: try semSublinhados(tok[k...], ehDigito, off), as: UTF8.self)
            j = tok.count
        }
        guard j == tok.count, let d = Double(texto) else { throw erro("número inválido: '\(s)'", em: off) }
        return .decimal(d)
    }

    func doisDigitos(_ t: [UInt8], _ i: Int) -> Int? {
        guard i + 1 < t.count, ehDigito(t[i]), ehDigito(t[i + 1]) else { return nil }
        return Int(t[i] - 0x30) * 10 + Int(t[i + 1] - 0x30)
    }

    /// Lê `HH:MM:SS(.frac)?` a partir de `i`; devolve a posição seguinte.
    func lerHora(_ t: [UInt8], _ i: Int, _ dh: inout DataHora, _ off: Int) throws(ErroTOML) -> Int {
        guard let h = doisDigitos(t, i), i + 2 < t.count, t[i + 2] == 0x3A,
              let m = doisDigitos(t, i + 3), i + 5 < t.count, t[i + 5] == 0x3A,
              let s = doisDigitos(t, i + 6) else {
            throw erro("hora inválida (use HH:MM:SS)", em: off)
        }
        guard h <= 23, m <= 59, s <= 60 else { throw erro("hora fora do intervalo", em: off) }
        dh.hora = h; dh.minuto = m; dh.segundo = s
        var j = i + 8
        if j < t.count, t[j] == PONTO {
            j += 1
            let iniF = j
            while j < t.count, ehDigito(t[j]) { j += 1 }
            guard j > iniF else { throw erro("fração de segundo sem dígitos", em: off) }
            let dig = t[iniF..<j]
            dh.casasFracao = dig.count
            var n = 0
            for (k, d) in dig.prefix(9).enumerated() { _ = k; n = n * 10 + Int(d - 0x30) }
            for _ in 0..<max(0, 9 - dig.count) { n *= 10 }
            dh.nanos = n
        }
        return j
    }

    func soHora(_ t: [UInt8], _ off: Int) throws(ErroTOML) -> DataHora {
        var dh = DataHora(tipo: .hora)
        let j = try lerHora(t, 0, &dh, off)
        guard j == t.count else { throw erro("hora inválida: '\(String(decoding: t, as: UTF8.self))'", em: off) }
        return dh
    }

    func dataHora(_ t: [UInt8], _ off: Int) throws(ErroTOML) -> DataHora {
        let invalida = erro("data inválida: '\(String(decoding: t, as: UTF8.self))'", em: off)
        guard t.count >= 10, t[0..<4].allSatisfy(ehDigito), t[4] == 0x2D,
              let mes = doisDigitos(t, 5), t[7] == 0x2D, let dia = doisDigitos(t, 8) else { throw invalida }
        let ano = t[0..<4].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        let bissexto = (ano % 4 == 0 && ano % 100 != 0) || ano % 400 == 0
        let dias = [31, bissexto ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard mes >= 1, mes <= 12, dia >= 1, dia <= dias[mes - 1] else {
            throw erro("data fora do calendário: '\(String(decoding: t, as: UTF8.self))'", em: off)
        }
        var dh = DataHora(tipo: .data)
        dh.ano = ano; dh.mes = mes; dh.dia = dia
        if t.count == 10 { return dh }
        guard t[10] == 0x54 || t[10] == 0x74 || t[10] == ESP else { throw invalida }
        dh.tipo = .local
        var j = try lerHora(t, 11, &dh, off)
        if j == t.count { return dh }
        dh.tipo = .comFuso
        if t[j] == 0x5A || t[j] == 0x7A {
            dh.fusoZ = true
            dh.fusoMinutos = 0
            j += 1
        } else if t[j] == 0x2B || t[j] == 0x2D {
            guard let fh = doisDigitos(t, j + 1), j + 3 < t.count, t[j + 3] == 0x3A,
                  let fm = doisDigitos(t, j + 4), fh <= 23, fm <= 59 else { throw invalida }
            dh.fusoZ = false
            dh.fusoMinutos = (fh * 60 + fm) * (t[j] == 0x2D ? -1 : 1)
            j += 6
        } else {
            throw invalida
        }
        guard j == t.count else { throw invalida }
        return dh
    }
}
