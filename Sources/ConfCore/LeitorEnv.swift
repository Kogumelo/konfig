import Foundation

/// Leitor de arquivos `.env` que guarda a posição (em bytes UTF-8) de cada valor.
///
/// Não há norma oficial; as regras seguem o `dotenv` do Node e do Ruby, com duas
/// diferenças de propósito (o editor prefere recusar a adivinhar): linha que não é
/// `CHAVE=valor`, comentário ou linha em branco é erro, e chave repetida também.
///
/// - `CHAVE=valor`, com `export ` opcional na frente e espaços em volta do `=`.
///   Chave: letras ASCII, dígitos, `_`, `.` e `-`.
/// - Sem aspas: o valor vai até o fim da linha ou até o primeiro `#` (dali em diante
///   é comentário); espaços nas pontas não fazem parte do valor.
/// - Aspas simples: texto literal, sem escapes.
/// - Aspas duplas: `\n`, `\r`, `\"` e `\\` são escapes; outra barra fica como está.
/// - Valores entre aspas podem ocupar várias linhas (CRLF dentro deles vira `\n`).
/// - `${VAR}` e `$VAR` não são expandidos: são texto.
/// - Comentários `#` em linhas próprias logo acima viram a ajuda do campo.
///
/// Todo valor é texto; não há seções (a raiz é uma tabela de textos).
public enum LeitorEnv {
    public static func ler(_ bytes: [UInt8]) throws(ErroLeitura) -> DocumentoConf {
        var a = AnalisadorEnv(bytes)
        return try a.documento()
    }

    public static func ler(_ texto: String) throws(ErroLeitura) -> DocumentoConf {
        try ler(Array(texto.utf8))
    }

    /// Lê um valor isolado como se escreve depois do `=`: `abc`, `'abc'` ou `"a\nb"`.
    public static func lerValor(_ texto: String) throws(ErroLeitura) -> Valor {
        let prefixo = "X="
        do throws(ErroLeitura) {
            let doc = try ler(prefixo + texto)
            guard doc.entradas.count == 1, let e = doc.entradas.first else {
                throw ErroLeitura(mensagem: "o valor precisa ficar numa linha só (ou entre aspas)",
                                  linha: 1, coluna: 1, deslocamento: 0, formato: .env)
            }
            if e.comentarioFim != nil {
                throw ErroLeitura(mensagem: "'#' começa um comentário; para usá-lo no valor, ponha o valor entre aspas",
                                  linha: 1, coluna: 1, deslocamento: 0, formato: .env)
            }
            return e.valor
        } catch {
            var e = error
            if e.linha == 1 { e.coluna = max(1, e.coluna - prefixo.count); e.deslocamento = max(0, e.deslocamento - prefixo.utf8.count) }
            throw e
        }
    }

    /// Caractere aceito no nome de uma variável.
    static func ehCaractereChave(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
            || c == 0x5F || c == 0x2E || c == 0x2D
    }
}

// MARK: - Constantes

private let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09, ESP: UInt8 = 0x20
private let ASPA: UInt8 = 0x22, APOS: UInt8 = 0x27, BARRA_INV: UInt8 = 0x5C, CERQUILHA: UInt8 = 0x23
private let IGUAL: UInt8 = 0x3D

// MARK: - Analisador

private struct AnalisadorEnv {
    let b: [UInt8]
    let inicio: Int
    var p: Int
    let iniciosDeLinha: [Int]

    init(_ bytes: [UInt8]) {
        b = bytes
        inicio = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        p = inicio
        var l = [0]
        for (i, c) in bytes.enumerated() where c == LF { l.append(i + 1) }
        iniciosDeLinha = l
    }

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
        return ErroLeitura(mensagem: msg, linha: l + 1, coluna: col, deslocamento: o, formato: .env)
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
            return String(format: "o caractere 0x%02X", c)
        }
    }

    var atual: UInt8? { p < b.count ? b[p] : nil }

    mutating func pulaEspacos() { while p < b.count, b[p] == ESP || b[p] == TAB { p += 1 } }

    /// Está no fim da linha (LF, CRLF ou fim do arquivo)?
    var noFimDaLinha: Bool {
        guard p < b.count else { return true }
        return b[p] == LF || (b[p] == CR && p + 1 < b.count && b[p + 1] == LF)
    }

    /// Consome a quebra de linha (precisa estar no fim da linha).
    mutating func consomeQuebra() throws(ErroLeitura) {
        guard p < b.count else { return }
        if b[p] == LF { p += 1; return }
        if b[p] == CR, p + 1 < b.count, b[p + 1] == LF { p += 2; return }
        throw erro("esperava o fim da linha, encontrei \(descreve(atual))")
    }

    /// Texto de um comentário a partir do `#` até o fim da linha, sem o `#` e sem espaços nas pontas.
    mutating func comentario() throws(ErroLeitura) -> String {
        p += 1
        let ini = p
        while p < b.count, b[p] != LF, !(b[p] == CR && p + 1 < b.count && b[p + 1] == LF) {
            if b[p] == CR { throw erro("CR sozinho (sem LF) não é quebra de linha aceita") }
            p += 1
        }
        return String(decoding: b[ini..<p], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // MARK: UTF-8

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

    // MARK: Documento

    mutating func documento() throws(ErroLeitura) -> DocumentoConf {
        try validaUTF8()
        var entradas: [Entrada] = []
        var raiz = Tabela()
        var linhaDaChave: [String: Int] = [:]
        var acima: [String] = []

        while p < b.count {
            pulaEspacos()
            if noFimDaLinha {
                try consomeQuebra()
                acima.removeAll()          // linha em branco separa o comentário da variável
                continue
            }
            if b[p] == CERQUILHA {
                acima.append(try comentario())
                try consomeQuebra()
                continue
            }
            let inicioLinha = p
            // `export ` na frente (mas `export=1` é a variável "export")
            if b[p...].starts(with: Array("export".utf8)), p + 6 < b.count, b[p + 6] == ESP || b[p + 6] == TAB {
                p += 6
                pulaEspacos()
                if !(atual.map(LeitorEnv.ehCaractereChave) ?? false) { p = inicioLinha }
            }
            let iniChave = p
            while p < b.count, LeitorEnv.ehCaractereChave(b[p]) { p += 1 }
            guard p > iniChave else {
                throw erro("esperava o nome de uma variável (letras, dígitos, '_', '.' ou '-'), encontrei \(descreve(atual))")
            }
            let fimChave = p
            let chave = String(decoding: b[iniChave..<fimChave], as: UTF8.self)
            pulaEspacos()
            guard atual == IGUAL else {
                if noFimDaLinha { throw erro("falta '=' e o valor depois de '\(chave)'") }
                throw erro("esperava '=' depois de '\(chave)', encontrei \(descreve(atual))")
            }
            p += 1
            let depoisDoIgual = p
            pulaEspacos()

            let valor: String
            let intervalo: Range<Int>
            var fimComentario: String?
            if let q = atual, q == ASPA || q == APOS {
                (valor, intervalo) = try entreAspas(q)
                pulaEspacos()
                if atual == CERQUILHA {
                    fimComentario = try comentario()
                } else if !noFimDaLinha {
                    throw erro("depois das aspas só pode vir um comentário '#', encontrei \(descreve(atual))")
                }
            } else {
                let ini = p
                while p < b.count, b[p] != CERQUILHA, b[p] != LF {
                    if b[p] == CR {
                        if p + 1 < b.count, b[p + 1] == LF { break }
                        throw erro("CR sozinho (sem LF) não é quebra de linha aceita")
                    }
                    p += 1
                }
                var fim = p
                while fim > ini, b[fim - 1] == ESP || b[fim - 1] == TAB { fim -= 1 }
                // valor vazio: o lugar dele é logo depois do '=' (antes de espaços e comentário)
                intervalo = fim > ini ? ini..<fim : depoisDoIgual..<depoisDoIgual
                valor = String(decoding: b[ini..<fim], as: UTF8.self)
                if atual == CERQUILHA { fimComentario = try comentario() }
            }
            let linhaFinal = linha(intervalo.upperBound)
            try consomeQuebra()

            if let l = linhaDaChave[chave] {
                throw erro("a variável '\(chave)' já foi definida na linha \(l); chave repetida não é aceita", em: iniChave)
            }
            let linhaChave = linha(iniChave)
            linhaDaChave[chave] = linhaChave
            raiz[chave] = .texto(valor)
            entradas.append(Entrada(caminho: [.chave(chave)], chaveEscrita: chave, valor: .texto(valor),
                                    posicao: Posicao(intervalo: intervalo), intervaloChave: iniChave..<fimChave,
                                    linha: linhaChave, linhaFinal: linhaFinal,
                                    comentarioAcima: acima, comentarioFim: fimComentario, secao: nil))
            acima.removeAll()
        }

        var quebra = "\n"
        if let i = b.firstIndex(of: LF), i > 0, b[i - 1] == CR { quebra = "\r\n" }
        return DocumentoConf(formato: .env, bytes: b, raiz: .tabela(raiz), entradas: entradas, cabecalhos: [],
                             quebraDeLinha: quebra, temBOM: inicio == 3)
    }

    /// Valor entre aspas simples (literal) ou duplas (com escapes). Pode ocupar várias linhas.
    mutating func entreAspas(_ q: UInt8) throws(ErroLeitura) -> (String, Range<Int>) {
        let ini = p
        p += 1
        var s: [UInt8] = []
        while true {
            guard p < b.count else {
                throw erro(q == ASPA ? "aspas duplas abertas aqui e nunca fechadas" : "aspas simples abertas aqui e nunca fechadas",
                           em: ini)
            }
            let c = b[p]
            if c == q { p += 1; break }
            if q == ASPA, c == BARRA_INV, p + 1 < b.count {
                switch b[p + 1] {
                case 0x6E: s.append(LF); p += 2           // \n
                case 0x72: s.append(CR); p += 2           // \r
                case ASPA: s.append(ASPA); p += 2         // \"
                case BARRA_INV: s.append(BARRA_INV); p += 2
                default: s.append(BARRA_INV); p += 1      // outra barra fica como está
                }
                continue
            }
            if c == CR, p + 1 < b.count, b[p + 1] == LF {
                s.append(LF); p += 2
                continue
            }
            s.append(c)
            p += 1
        }
        return (String(decoding: s, as: UTF8.self), ini..<p)
    }
}
