import Foundation

/// Leitor de JSON (RFC 8259) e JSONC que guarda a posição (em bytes UTF-8) de cada valor.
///
/// JSONC é JSON com comentários `//` e `/* */` e vírgula depois do último item
/// (o dialeto de `tsconfig.json` e `.vscode/settings.json`). Por padrão o leitor
/// aceita os dois; com `estrito: true`, só JSON puro. JSON5 não é aceito.
///
/// Como no TOML, cada membro de objeto vira uma `Entrada` (com o intervalo do
/// valor e os comentários acima e no fim da linha); objetos aninhados e objetos
/// dentro de listas viram seções (`Cabecalho`).
public enum LeitorJSON {
    /// Aninhamento máximo de listas e objetos. Comparar e liberar valores é recursivo;
    /// o limite protege a pilha das threads secundárias (512 KB).
    public static let profundidadeMaxima = 128

    public static func ler(_ bytes: [UInt8], estrito: Bool = false) throws(ErroLeitura) -> DocumentoConf {
        try AnalisadorJSON(bytes, estrito: estrito).documento()
    }

    public static func ler(_ texto: String, estrito: Bool = false) throws(ErroLeitura) -> DocumentoConf {
        try ler(Array(texto.utf8), estrito: estrito)
    }

    /// Lê um valor isolado, como `[1, 2]` ou `"abc"` (comentários permitidos).
    public static func lerValor(_ texto: String) throws(ErroLeitura) -> Valor {
        try ler(Array(texto.utf8)).valorRaiz
    }
}

// MARK: - Constantes

private let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09, ESP: UInt8 = 0x20
private let ASPA: UInt8 = 0x22, BARRA_INV: UInt8 = 0x5C, BARRA: UInt8 = 0x2F, ASTER: UInt8 = 0x2A
private let ABRE_COL: UInt8 = 0x5B, FECHA_COL: UInt8 = 0x5D, ABRE_CH: UInt8 = 0x7B, FECHA_CH: UInt8 = 0x7D
private let DOIS_PONTOS: UInt8 = 0x3A, VIRG: UInt8 = 0x2C, MENOS: UInt8 = 0x2D, PONTO: UInt8 = 0x2E

@inline(__always) private func ehDigito(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

private func valorHex(_ c: UInt8) -> UInt32? {
    switch c {
    case 0x30...0x39: return UInt32(c - 0x30)
    case 0x41...0x46: return UInt32(c - 0x41 + 10)
    case 0x61...0x66: return UInt32(c - 0x61 + 10)
    default: return nil
    }
}

// MARK: - Árvore com posições

private final class NoJSON {
    enum Tipo { case escalar, lista, objeto }

    /// Um item de lista ou membro de objeto, com os comentários em volta.
    struct Filho {
        var no: NoJSON
        var chave: String = ""
        var intervaloChave: Range<Int> = 0..<0
        var acima: [String] = []
        var fim: String?
    }

    let tipo: Tipo
    var valor: Valor = .nulo
    var intervalo: Range<Int> = 0..<0
    var filhos: [Filho] = []
    /// Comentário logo depois de `{` ou `[`, na mesma linha.
    var fimAbertura: String?

    init(_ t: Tipo) { tipo = t }

    var ehListaDeObjetos: Bool {
        tipo == .lista && !filhos.isEmpty && filhos.allSatisfy { $0.no.tipo == .objeto }
    }

    var posicao: Posicao {
        Posicao(intervalo: intervalo, itens: tipo == .lista ? filhos.map(\.no.posicao) : [])
    }
}

/// Comentários e linhas em branco entre dois elementos.
private struct Lacuna {
    struct Comentario {
        var linhas: [String]
        var inicio: Int
        /// Só espaços antes dele na linha.
        var proprioLinha: Bool
        /// Havia uma linha em branco antes dele (desde o elemento ou comentário anterior).
        var linhaVaziaAntes: Bool
    }

    var comentarios: [Comentario] = []
    var linhaVaziaNoFim = false

    /// Bloco de comentários em linhas próprias logo acima do próximo elemento.
    var acima: [String] {
        if linhaVaziaNoFim { return [] }
        var bloco: [String] = []
        for c in comentarios {
            if c.linhaVaziaAntes || !c.proprioLinha { bloco = [] }
            if c.proprioLinha { bloco += c.linhas }
        }
        return bloco
    }
}

// MARK: - Analisador

private final class AnalisadorJSON {
    let b: [UInt8]
    let estrito: Bool
    let inicio: Int
    var p = 0
    var usouExtensao = false

    lazy var iniciosDeLinha: [Int] = {
        var r = [0]
        for (i, c) in b.enumerated() where c == LF { r.append(i + 1) }
        return r
    }()

    init(_ bytes: [UInt8], estrito: Bool) {
        b = bytes
        self.estrito = estrito
        inicio = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
    }

    // MARK: Utilidades

    @inline(__always) var atual: UInt8? { p < b.count ? b[p] : nil }
    @inline(__always) func olha(_ k: Int) -> UInt8? { p + k < b.count ? b[p + k] : nil }

    func indiceLinha(_ off: Int) -> Int {
        var lo = 0, hi = iniciosDeLinha.count - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if iniciosDeLinha[m] <= off { lo = m } else { hi = m - 1 }
        }
        return lo
    }

    func linha(_ off: Int) -> Int { indiceLinha(min(max(off, 0), b.count)) + 1 }

    func erro(_ msg: String, em off: Int? = nil) -> ErroLeitura {
        let o = min(max(off ?? p, 0), b.count)
        let l = indiceLinha(o)
        var ini = iniciosDeLinha[l]
        if l == 0 { ini = max(ini, inicio) }
        var col = 1
        if ini < o { for i in ini..<o where b[i] & 0xC0 != 0x80 { col += 1 } }
        return ErroLeitura(mensagem: msg, linha: l + 1, coluna: col, deslocamento: o, formato: .json)
    }

    func descreve(_ c: UInt8?) -> String {
        guard let c else { return "fim do arquivo" }
        switch c {
        case LF, CR: return "fim de linha"
        case TAB: return "tabulação"
        case ESP: return "espaço"
        case 0x21...0x7E: return "'\(String(UnicodeScalar(c)))'"
        default:
            if c >= 0x80, let s = String(bytes: b[p...].prefix(4), encoding: .utf8)?.first { return "'\(s)'" }
            return String(format: "byte 0x%02X", c)
        }
    }

    /// Só espaços e tabulações entre o começo da linha e `off`.
    func soEspacosAntes(_ off: Int) -> Bool {
        var i = off
        while i > inicio, b[i - 1] == ESP || b[i - 1] == TAB { i -= 1 }
        return i == inicio || b[i - 1] == LF || b[i - 1] == CR
    }

    func temQuebra(_ r: Range<Int>) -> Bool { r.lowerBound < r.upperBound && b[r].contains(LF) }

    // MARK: Validação de UTF-8

    func validaUTF8() throws(ErroLeitura) {
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c < 0x80 { i += 1; continue }
            var tam = 0, minimo: UInt32 = 0, v: UInt32 = 0
            if c & 0xE0 == 0xC0 { tam = 2; minimo = 0x80; v = UInt32(c & 0x1F) }
            else if c & 0xF0 == 0xE0 { tam = 3; minimo = 0x800; v = UInt32(c & 0x0F) }
            else if c & 0xF8 == 0xF0 { tam = 4; minimo = 0x10000; v = UInt32(c & 0x07) }
            else { throw erro("UTF-8 inválido (o arquivo precisa estar em UTF-8)", em: i) }
            guard i + tam <= n else { throw erro("UTF-8 inválido (sequência incompleta)", em: i) }
            for k in 1..<tam {
                let d = b[i + k]
                guard d & 0xC0 == 0x80 else { throw erro("UTF-8 inválido (o arquivo precisa estar em UTF-8)", em: i) }
                v = (v << 6) | UInt32(d & 0x3F)
            }
            if v < minimo || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) {
                throw erro("UTF-8 inválido", em: i)
            }
            i += tam
        }
    }

    // MARK: Espaços e comentários

    func extensao(_ o_que: String, em off: Int) throws(ErroLeitura) {
        if estrito { throw erro("\(o_que) não é permitido em JSON puro (só em JSONC)", em: off) }
        usouExtensao = true
    }

    /// Espaços, quebras de linha e comentários até o próximo elemento.
    func lacuna() throws(ErroLeitura) -> Lacuna {
        var r = Lacuna()
        var quebras = 0
        while let c = atual {
            if c == ESP || c == TAB || c == CR { p += 1; continue }
            if c == LF { quebras += 1; p += 1; continue }
            guard c == BARRA, olha(1) == BARRA || olha(1) == ASTER else { break }
            let ini = p
            try extensao("comentário", em: ini)
            var linhas: [String]
            if olha(1) == BARRA {
                p += 2
                while let d = atual, d != LF, d != CR { p += 1 }
                var t = b[(ini + 2)..<p]
                while t.first == BARRA { t = t.dropFirst() }
                linhas = [String(decoding: t, as: UTF8.self).trimmingCharacters(in: .whitespaces)]
            } else {
                p += 2
                var fim: Int? = nil
                while p + 1 < b.count {
                    if b[p] == ASTER && b[p + 1] == BARRA { fim = p; break }
                    p += 1
                }
                guard let f = fim else { throw erro("comentário '/*' sem '*/'", em: ini) }
                p = f + 2
                linhas = String(decoding: b[(ini + 2)..<f], as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { l in
                        var s = l.trimmingCharacters(in: .whitespacesAndNewlines)
                        while s.hasPrefix("*") { s.removeFirst() }
                        return s.trimmingCharacters(in: .whitespaces)
                    }
                while linhas.first?.isEmpty == true { linhas.removeFirst() }
                while linhas.last?.isEmpty == true { linhas.removeLast() }
            }
            r.comentarios.append(.init(linhas: linhas, inicio: ini, proprioLinha: soEspacosAntes(ini),
                                       linhaVaziaAntes: quebras >= 2))
            quebras = 0
        }
        r.linhaVaziaNoFim = quebras >= 2
        return r
    }

    /// Primeiro comentário na mesma linha em que terminou o elemento anterior (em `fimDoAnterior`).
    func comentarioNaLinha(_ l: Lacuna, depoisDe fimDoAnterior: Int) -> String? {
        for c in l.comentarios where !c.proprioLinha {
            if temQuebra(fimDoAnterior..<c.inicio) { return nil }
            let t = c.linhas.joined(separator: " ")
            return t.isEmpty ? nil : t
        }
        return nil
    }

    // MARK: Valores

    /// Lê um valor completo. Listas e objetos são lidos com uma pilha explícita (sem
    /// recursão), para que arquivos muito aninhados não estourem a pilha da thread.
    func valor() throws(ErroLeitura) -> NoJSON {
        /// Lista ou objeto aberto, com o item (ou membro) que está sendo lido.
        struct Aberto {
            var no: NoJSON
            var ini: Int
            var pendente: NoJSON.Filho
        }
        var pilha: [Aberto] = []
        var pronto: NoJSON? = nil

        /// Depois de `{` ou `,` num objeto: chave, `:` e espaços até o valor.
        func chave(_ a: inout Aberto, _ lac: Lacuna) throws(ErroLeitura) {
            guard atual == ASPA else {
                throw erro(atual == 0x27 ? "chave entre aspas simples não é JSON; use aspas duplas"
                           : "esperada chave entre aspas, encontrado \(descreve(atual))")
            }
            let kIni = p
            a.pendente.chave = try texto()
            a.pendente.intervaloChave = kIni..<p
            a.pendente.acima = lac.acima
            _ = try lacuna()
            guard atual == DOIS_PONTOS else { throw erro("esperado ':' depois da chave, encontrado \(descreve(atual))") }
            p += 1
            _ = try lacuna()
        }

        func fecha(_ a: Aberto) -> NoJSON {
            let n = a.no
            n.intervalo = a.ini..<p
            if n.tipo == .objeto {
                // chave repetida: vale a última (como em JavaScript), na posição da primeira
                var t = Tabela()
                for f in n.filhos { t[f.chave] = f.no.valor }
                n.valor = .tabela(t)
            } else {
                n.valor = .lista(n.filhos.map(\.no.valor))
            }
            return n
        }

        while true {
            if let feito = pronto {
                // um valor terminou: entra no topo da pilha, ou é o resultado
                guard var a = pilha.popLast() else { return feito }
                let objeto = a.no.tipo == .objeto
                let fechamento = objeto ? FECHA_CH : FECHA_COL
                var f = a.pendente
                f.no = feito
                let fimValor = feito.intervalo.upperBound
                let depois = try lacuna()
                f.fim = comentarioNaLinha(depois, depoisDe: fimValor)
                if atual == VIRG {
                    let v = p
                    p += 1
                    let lac = try lacuna()
                    if f.fim == nil { f.fim = comentarioNaLinha(lac, depoisDe: fimValor) }
                    a.no.filhos.append(f)
                    if atual == fechamento {
                        try extensao("vírgula depois do último item", em: v)
                        p += 1
                        pronto = fecha(a)
                        continue
                    }
                    a.pendente = NoJSON.Filho(no: a.no)
                    if objeto { try chave(&a, lac) } else { a.pendente.acima = lac.acima }
                    pilha.append(a)
                    pronto = nil
                    continue
                }
                a.no.filhos.append(f)
                if atual == fechamento {
                    p += 1
                    pronto = fecha(a)
                    continue
                }
                throw erro("esperado ',' ou '\(objeto ? "}" : "]")', encontrado \(descreve(atual))")
            }

            guard let c = atual else { throw erro("valor esperado, encontrado fim do arquivo") }
            switch c {
            case ABRE_CH, ABRE_COL:
                guard pilha.count < LeitorJSON.profundidadeMaxima else {
                    throw erro("aninhamento demais (mais de \(LeitorJSON.profundidadeMaxima) níveis)")
                }
                let objeto = c == ABRE_CH
                let n = NoJSON(objeto ? .objeto : .lista)
                var a = Aberto(no: n, ini: p, pendente: NoJSON.Filho(no: n))
                p += 1
                let lac = try lacuna()
                n.fimAbertura = comentarioNaLinha(lac, depoisDe: a.ini + 1)
                if atual == (objeto ? FECHA_CH : FECHA_COL) {
                    p += 1
                    pronto = fecha(a)
                    continue
                }
                if objeto { try chave(&a, lac) } else { a.pendente.acima = lac.acima }
                pilha.append(a)
            case ASPA:
                let n = NoJSON(.escalar)
                let ini = p
                n.valor = .texto(try texto())
                n.intervalo = ini..<p
                pronto = n
            case MENOS, 0x30...0x39: pronto = try numero()
            case 0x74: pronto = try literal("true", .booleano(true))
            case 0x66: pronto = try literal("false", .booleano(false))
            case 0x6E: pronto = try literal("null", .nulo)
            case 0x27: throw erro("texto entre aspas simples não é JSON; use aspas duplas")
            default: throw erro("valor esperado, encontrado \(descreve(c))")
            }
        }
    }

    func literal(_ palavra: String, _ v: Valor) throws(ErroLeitura) -> NoJSON {
        let ini = p
        for u in palavra.utf8 {
            guard atual == u else { throw erro("valor inválido; esperado '\(palavra)'", em: ini) }
            p += 1
        }
        let n = NoJSON(.escalar)
        n.valor = v
        n.intervalo = ini..<p
        return n
    }

    func numero() throws(ErroLeitura) -> NoJSON {
        let ini = p
        if atual == MENOS { p += 1 }
        guard let c = atual, ehDigito(c) else { throw erro("número inválido: falta dígito", em: ini) }
        p += 1
        if c == 0x30 {
            if let d = atual, ehDigito(d) { throw erro("número com zero à esquerda não é JSON", em: ini) }
        } else {
            while let d = atual, ehDigito(d) { p += 1 }
        }
        var inteiro = true
        if atual == PONTO {
            p += 1
            guard let d = atual, ehDigito(d) else { throw erro("número inválido: falta dígito depois do ponto") }
            while let d = atual, ehDigito(d) { p += 1 }
            inteiro = false
        }
        if atual == 0x65 || atual == 0x45 {
            p += 1
            if atual == 0x2B || atual == MENOS { p += 1 }
            guard let d = atual, ehDigito(d) else { throw erro("número inválido: falta dígito no expoente") }
            while let d = atual, ehDigito(d) { p += 1 }
            inteiro = false
        }
        let t = String(decoding: b[ini..<p], as: UTF8.self)
        let n = NoJSON(.escalar)
        n.intervalo = ini..<p
        // Inteiro que não cabe em 64 bits fica como decimal (aproximado; só muda se for editado).
        if inteiro, let x = Int64(t) { n.valor = .inteiro(x) } else { n.valor = .decimal(Double(t) ?? .nan) }
        return n
    }

    /// Texto entre aspas (o cursor está na aspa de abertura).
    func texto() throws(ErroLeitura) -> String {
        let ini = p
        p += 1
        var r: [UInt8] = []
        func poe(_ v: UInt32) {
            let u = UnicodeScalar(v)!
            r.append(contentsOf: Array(String(Character(u)).utf8))
        }
        while true {
            guard let c = atual else { throw erro("texto sem aspas de fechamento", em: ini) }
            if c == ASPA { p += 1; break }
            if c < 0x20 {
                throw erro(c == LF || c == CR ? "quebra de linha dentro de texto; use \\n"
                           : "caractere de controle dentro de texto; use um escape como \\t ou \\u00XX")
            }
            if c != BARRA_INV { r.append(c); p += 1; continue }
            let esc = p
            guard let e = olha(1) else { throw erro("texto sem aspas de fechamento", em: ini) }
            p += 2
            switch e {
            case ASPA: r.append(ASPA)
            case BARRA_INV: r.append(BARRA_INV)
            case BARRA: r.append(BARRA)
            case 0x62: r.append(0x08)
            case 0x66: r.append(0x0C)
            case 0x6E: r.append(LF)
            case 0x72: r.append(CR)
            case 0x74: r.append(TAB)
            case 0x75:
                let alto = try hex4(esc)
                if alto >= 0xD800 && alto <= 0xDBFF {
                    guard atual == BARRA_INV, olha(1) == 0x75 else {
                        throw erro("escape \\u de surrogate alto sem o par baixo", em: esc)
                    }
                    let esc2 = p
                    p += 2
                    let baixo = try hex4(esc2)
                    guard baixo >= 0xDC00 && baixo <= 0xDFFF else {
                        throw erro("escape \\u de surrogate alto seguido de algo que não é o par baixo", em: esc2)
                    }
                    poe(0x10000 + ((alto - 0xD800) << 10) + (baixo - 0xDC00))
                } else if alto >= 0xDC00 && alto <= 0xDFFF {
                    throw erro("escape \\u de surrogate baixo sozinho", em: esc)
                } else {
                    poe(alto)
                }
            default:
                throw erro("escape inválido '\\\(String(UnicodeScalar(e)))'", em: esc)
            }
        }
        return String(decoding: r, as: UTF8.self)
    }

    func hex4(_ esc: Int) throws(ErroLeitura) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard let c = atual, let h = valorHex(c) else { throw erro("escape \\u precisa de 4 dígitos hexadecimais", em: esc) }
            v = v << 4 | h
            p += 1
        }
        return v
    }

    // MARK: Documento

    var entradas: [Entrada] = []
    var cabecalhos: [Cabecalho] = []

    func documento() throws(ErroLeitura) -> DocumentoConf {
        try validaUTF8()
        p = inicio
        let antes = try lacuna()
        guard atual != nil else { throw erro("arquivo sem valor JSON") }
        let raiz = try valor()
        _ = try lacuna()
        if atual != nil { throw erro("texto depois do fim do valor JSON: \(descreve(atual))") }

        switch raiz.tipo {
        case .objeto:
            percorrer(raiz, caminho: [], nomes: [], secao: nil)
        case .lista where raiz.ehListaDeObjetos:
            itensDeLista(raiz, caminho: [], nomes: [], acimaDaLista: antes.acima, fimDaLista: nil)
        default:
            let r = raiz.intervalo
            entradas.append(Entrada(caminho: [], chaveEscrita: "(raiz)", valor: raiz.valor, posicao: raiz.posicao,
                                    intervaloChave: r.lowerBound..<r.lowerBound, linha: linha(r.lowerBound),
                                    linhaFinal: linha(r.upperBound - 1), comentarioAcima: antes.acima,
                                    comentarioFim: raiz.fimAbertura, secao: nil))
        }
        var quebra = "\n"
        if let i = b.firstIndex(of: LF), i > 0, b[i - 1] == CR { quebra = "\r\n" }
        return DocumentoConf(formato: .json, bytes: b, raiz: raiz.valor, entradas: entradas, cabecalhos: cabecalhos,
                             quebraDeLinha: quebra, temBOM: inicio == 3, usaExtensoesJSONC: usouExtensao)
    }

    /// Membros de um objeto: valores simples viram entradas; objetos e listas de objetos, seções.
    func percorrer(_ obj: NoJSON, caminho: Caminho, nomes: [String], secao: Int?) {
        // com chave repetida, só a última ocorrência vale (e é editável)
        var ultima: [[UInt32]: Int] = [:]
        for (i, f) in obj.filhos.enumerated() { ultima[f.chave.unicodeScalars.map(\.value)] = i }
        for (i, f) in obj.filhos.enumerated() where ultima[f.chave.unicodeScalars.map(\.value)] == i {
            let cam = caminho + [.chave(f.chave)]
            if f.no.tipo == .objeto {
                let idx = cabecalhos.count
                cabecalhos.append(Cabecalho(caminho: cam, nomes: nomes + [f.chave], ehListaDeTabelas: false,
                                            intervalo: f.no.intervalo, linha: linha(f.intervaloChave.lowerBound),
                                            comentarioAcima: f.acima, comentarioFim: f.fim ?? f.no.fimAbertura))
                percorrer(f.no, caminho: cam, nomes: nomes + [f.chave], secao: idx)
            } else if f.no.ehListaDeObjetos {
                itensDeLista(f.no, caminho: cam, nomes: nomes + [f.chave], acimaDaLista: f.acima,
                             fimDaLista: f.no.fimAbertura ?? f.fim)
            } else {
                entradas.append(Entrada(caminho: cam, chaveEscrita: f.chave, valor: f.no.valor, posicao: f.no.posicao,
                                        intervaloChave: f.intervaloChave, linha: linha(f.intervaloChave.lowerBound),
                                        linhaFinal: linha(f.no.intervalo.upperBound - 1), comentarioAcima: f.acima,
                                        comentarioFim: f.fim, secao: secao))
            }
        }
    }

    /// Cada objeto de uma lista de objetos vira uma seção, como um item de `[[lista]]` do TOML.
    func itensDeLista(_ l: NoJSON, caminho: Caminho, nomes: [String], acimaDaLista: [String], fimDaLista: String?) {
        let daLista = acimaDaLista + [fimDaLista].compactMap { $0 }
        for (j, item) in l.filhos.enumerated() {
            let cam = caminho + [.indice(j)]
            let idx = cabecalhos.count
            let fim = [item.fim, item.no.fimAbertura].compactMap { $0 }.joined(separator: "\n")
            cabecalhos.append(Cabecalho(caminho: cam, nomes: nomes, ehListaDeTabelas: true, intervalo: item.no.intervalo,
                                        linha: linha(item.no.intervalo.lowerBound),
                                        comentarioAcima: daLista + item.acima, comentarioFim: fim.isEmpty ? nil : fim))
            percorrer(item.no, caminho: cam, nomes: nomes, secao: idx)
        }
    }
}
