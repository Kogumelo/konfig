import Foundation

/// Leitor de arquivos INI que guarda a posição (em bytes UTF-8) de cada valor.
///
/// INI não tem norma; este é o dialeto aceito (detalhes e motivos no README):
///
/// - Comentário de linha: `;` ou `#` no começo (espaços antes são permitidos).
/// - Seção: `[nome]`, nome sem os espaços das pontas; pontos são literais (`[a.b]`
///   não é subseção). O nome vai até o primeiro `]` depois do qual só há espaços e
///   um comentário opcional: `[*.[ch]]` (EditorConfig) é a seção `*.[ch]`.
///   Seção repetida continua a primeira.
/// - Par: `chave = valor` ou `chave: valor` (vale o primeiro `=` ou `:` da linha).
/// - Valor sem aspas: espaços das pontas não fazem parte dele; `;` ou `#` depois de
///   espaço ou tabulação começa um comentário (`url = http://x/#a` fica inteiro).
///   `;` logo no começo do valor é comentário; `#` no começo é valor (`#DD0000` do php.ini).
/// - Valor entre aspas duplas ou simples, sem escapes, numa linha só; depois das
///   aspas, só espaços e um comentário opcional.
/// - Todo valor é texto.
/// - `chave[] = valor` em várias linhas forma uma lista (estilo PHP). `extension` e
///   `zend_extension` repetidas também (o PHP carrega uma extensão por linha).
///   Outra chave repetida na mesma seção é erro, para não editar a ocorrência errada.
/// - Linha que não é seção, par, comentário nem linha em branco é erro.
///
/// Chaves antes da primeira seção ficam na seção "Geral": na estrutura, sob a chave
/// `""` da raiz (nenhuma seção pode ter nome vazio, então não há colisão).
public enum LeitorINI {
    public static func ler(_ bytes: [UInt8]) throws(ErroLeitura) -> DocumentoConf {
        var a = AnalisadorINI(bytes)
        return try a.documento()
    }

    public static func ler(_ texto: String) throws(ErroLeitura) -> DocumentoConf {
        try ler(Array(texto.utf8))
    }

    /// Lê um valor isolado como se escreve depois do `=`: `abc`, `'a;b'` ou `"x y"`.
    public static func lerValor(_ texto: String) throws(ErroLeitura) -> Valor {
        let prefixo = "x="
        do throws(ErroLeitura) {
            let doc = try ler(prefixo + texto)
            guard doc.entradas.count == 1, let e = doc.entradas.first else {
                throw ErroLeitura(mensagem: "o valor precisa ficar numa linha só",
                                  linha: 1, coluna: 1, deslocamento: 0, formato: .ini)
            }
            if e.comentarioFim != nil {
                throw ErroLeitura(mensagem: "';' ou '#' depois de espaço começa um comentário; para usá-lo no valor, ponha o valor entre aspas",
                                  linha: 1, coluna: 1, deslocamento: 0, formato: .ini)
            }
            return e.valor
        } catch {
            var e = error
            if e.linha == 1 { e.coluna = max(1, e.coluna - prefixo.count); e.deslocamento = max(0, e.deslocamento - prefixo.utf8.count) }
            throw e
        }
    }

    /// Chaves que o PHP aceita repetidas, uma por linha, sem `[]`: viram lista.
    public static let chavesRepetiveis: Set<String> = ["extension", "zend_extension"]
}

// MARK: - Constantes

private let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09, ESP: UInt8 = 0x20
private let ASPA: UInt8 = 0x22, APOS: UInt8 = 0x27, PONTO_VIRGULA: UInt8 = 0x3B, CERQUILHA: UInt8 = 0x23
private let IGUAL: UInt8 = 0x3D, DOIS_PONTOS: UInt8 = 0x3A, ABRE: UInt8 = 0x5B, FECHA: UInt8 = 0x5D

@inline(__always) private func ehEspaco(_ c: UInt8) -> Bool { c == ESP || c == TAB }
@inline(__always) private func ehComentario(_ c: UInt8) -> Bool { c == PONTO_VIRGULA || c == CERQUILHA }

// MARK: - Analisador

private struct AnalisadorINI {
    let b: [UInt8]
    let inicio: Int
    let iniciosDeLinha: [Int]

    init(_ bytes: [UInt8]) {
        b = bytes
        inicio = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
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

    func erro(_ msg: String, em off: Int) -> ErroLeitura {
        let o = min(max(off, 0), b.count)
        let l = indiceLinha(o)
        var ini = iniciosDeLinha[l]
        if l == 0 { ini = max(ini, inicio) }
        var col = 1
        if ini < o { for i in ini..<o where b[i] & 0xC0 != 0x80 { col += 1 } }
        return ErroLeitura(mensagem: msg, linha: l + 1, coluna: col, deslocamento: o, formato: .ini)
    }

    func texto(_ r: Range<Int>) -> String { String(decoding: b[r], as: UTF8.self) }

    /// Intervalo sem os espaços e tabulações das pontas.
    func aparado(_ r: Range<Int>) -> Range<Int> {
        var i = r.lowerBound, f = r.upperBound
        while i < f, ehEspaco(b[i]) { i += 1 }
        while f > i, ehEspaco(b[f - 1]) { f -= 1 }
        return i..<f
    }

    /// Texto de um comentário a partir da marca (`;` ou `#`): sem as marcas repetidas
    /// do começo (`;;;;`) e sem espaços nas pontas.
    func comentario(_ r: Range<Int>) -> String {
        var i = r.lowerBound
        let marca = b[i]
        while i < r.upperBound, b[i] == marca { i += 1 }
        return texto(i..<r.upperBound).trimmingCharacters(in: .whitespaces)
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

    /// Uma seção na estrutura: índice em `cabecalhos` (`nil` = Geral) e os pares, em ordem.
    struct SecaoLida {
        var cabecalho: Int?
        var nome: String
        var tabela = Tabela()
        /// Linha da primeira ocorrência de cada chave (para a mensagem de chave repetida).
        var linhaDaChave: [String: Int] = [:]
        /// Chave de lista → índice em `entradas`.
        var listas: [String: Int] = [:]
    }

    mutating func documento() throws(ErroLeitura) -> DocumentoConf {
        try validaUTF8()
        var entradas: [Entrada] = []
        var cabecalhos: [Cabecalho] = []
        var secoes: [SecaoLida] = [SecaoLida(cabecalho: nil, nome: "")]
        var secaoPeloNome: [String: Int] = [:]
        var atual = 0
        var acima: [String] = []

        var p = inicio
        while p < b.count {
            // limites da linha: [p, fim) sem a quebra; `proxima` é o começo da linha seguinte
            var fim = p
            while fim < b.count, b[fim] != LF {
                if b[fim] == CR, !(fim + 1 < b.count && b[fim + 1] == LF) {
                    throw erro("CR sozinho (sem LF) não é quebra de linha aceita", em: fim)
                }
                fim += 1
            }
            let proxima = fim < b.count ? fim + 1 : fim
            if fim > p, b[fim - 1] == CR { fim -= 1 }
            defer { p = proxima }

            var i = p
            while i < fim, ehEspaco(b[i]) { i += 1 }
            if i == fim {
                acima.removeAll()          // linha em branco separa o comentário da chave
                continue
            }
            if ehComentario(b[i]) {
                acima.append(comentario(i..<fim))
                continue
            }
            let numeroLinha = linha(p)

            if b[i] == ABRE {
                // `]` que fecha: o primeiro depois do qual só há espaços e comentário opcional
                var fecha: Int? = nil
                var fimComentario: String? = nil
                var k = i + 1
                while k < fim {
                    if b[k] == FECHA {
                        var j = k + 1
                        while j < fim, ehEspaco(b[j]) { j += 1 }
                        if j == fim { fecha = k; break }
                        if ehComentario(b[j]) { fecha = k; fimComentario = comentario(j..<fim); break }
                    }
                    k += 1
                }
                guard let f = fecha else {
                    throw erro("seção sem ']' no fim (depois do ']' só pode vir um comentário ';' ou '#')", em: i)
                }
                let nomeR = aparado((i + 1)..<f)
                guard !nomeR.isEmpty else { throw erro("seção sem nome", em: i) }
                let nome = texto(nomeR)
                if let s = secaoPeloNome[nome] {
                    atual = s                 // seção repetida: continua a primeira
                } else {
                    cabecalhos.append(Cabecalho(caminho: [.chave(nome)], nomes: [nome], ehListaDeTabelas: false,
                                                intervalo: i..<(f + 1), linha: numeroLinha,
                                                comentarioAcima: acima, comentarioFim: fimComentario))
                    secoes.append(SecaoLida(cabecalho: cabecalhos.count - 1, nome: nome))
                    atual = secoes.count - 1
                    secaoPeloNome[nome] = atual
                }
                acima.removeAll()
                continue
            }

            // par: chave até o primeiro '=' ou ':'
            var sep = i
            while sep < fim, b[sep] != IGUAL, b[sep] != DOIS_PONTOS { sep += 1 }
            guard sep < fim else {
                throw erro("a linha não é seção ([nome]), par (chave = valor) nem comentário (; ou #)", em: i)
            }
            let chaveR = aparado(i..<sep)
            guard !chaveR.isEmpty else {
                throw erro("falta o nome da chave antes de '\(String(UnicodeScalar(b[sep])))'", em: sep)
            }
            var chave = texto(chaveR)
            let ehListaPHP = chave.hasSuffix("[]")
            if ehListaPHP {
                chave = String(chave.dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                guard !chave.isEmpty else { throw erro("falta o nome da lista antes de '[]'", em: chaveR.lowerBound) }
                chave += "[]"
            }

            // valor
            let depoisDoSep = sep + 1
            var v = depoisDoSep
            while v < fim, ehEspaco(b[v]) { v += 1 }
            let valor: String
            let intervalo: Range<Int>
            var fimComentario: String? = nil
            if v < fim, b[v] == ASPA || b[v] == APOS {
                let q = b[v]
                var f = v + 1
                while f < fim, b[f] != q { f += 1 }
                guard f < fim else {
                    throw erro(q == ASPA ? "aspas duplas abertas aqui e não fechadas na mesma linha"
                                         : "aspas simples abertas aqui e não fechadas na mesma linha", em: v)
                }
                valor = texto((v + 1)..<f)
                intervalo = v..<(f + 1)
                var j = f + 1
                while j < fim, ehEspaco(b[j]) { j += 1 }
                if j < fim {
                    guard ehComentario(b[j]) else {
                        throw erro("depois das aspas só pode vir um comentário ';' ou '#'", em: j)
                    }
                    fimComentario = comentario(j..<fim)
                }
            } else {
                var c = fim
                if v < fim, b[v] == PONTO_VIRGULA {
                    c = v
                } else if v < fim {
                    var j = v + 1
                    while j < fim {
                        if ehComentario(b[j]), ehEspaco(b[j - 1]) { c = j; break }
                        j += 1
                    }
                }
                let r = aparado(v..<c)
                // valor vazio: o lugar dele é logo depois do separador
                intervalo = r.isEmpty ? depoisDoSep..<depoisDoSep : r
                valor = texto(r)
                if c < fim { fimComentario = comentario(c..<fim) }
            }

            // chave repetida, lista
            var s = secoes[atual]
            let ehLista = ehListaPHP || LeitorINI.chavesRepetiveis.contains(chave)
            if ehLista, let iEntrada = s.listas[chave] {
                var e = entradas[iEntrada]
                guard case .lista(var itens) = e.valor else { continue }
                itens.append(.texto(valor))
                e.valor = .lista(itens)
                e.posicao.itens.append(Posicao(intervalo: intervalo))
                e.posicao.intervalo = e.posicao.intervalo.lowerBound..<fim
                e.linhaFinal = numeroLinha
                entradas[iEntrada] = e
                s.tabela[chave] = e.valor
            } else {
                // `x` e `x[]` também colidem: o PHP ficaria com uma delas
                let nomeBase = ehListaPHP ? String(chave.dropLast(2)) : chave
                if let l = s.linhaDaChave[nomeBase] {
                    let onde = s.cabecalho == nil ? "antes da primeira seção" : "na seção [\(s.nome)]"
                    throw erro("a chave '\(nomeBase)' já apareceu na linha \(l) \(onde); chave repetida não é aceita (para uma lista, use '\(nomeBase)[]' em todas as linhas)",
                               em: chaveR.lowerBound)
                }
                let caminho: Caminho = [.chave(s.nome), .chave(chave)]
                let entrada: Entrada
                if ehLista {
                    // a lista ocupa as linhas inteiras dos itens: assim dá para acrescentar e tirar linhas
                    entrada = Entrada(caminho: caminho, chaveEscrita: chave, valor: .lista([.texto(valor)]),
                                      posicao: Posicao(intervalo: p..<fim, itens: [Posicao(intervalo: intervalo)]),
                                      intervaloChave: chaveR, linha: numeroLinha, linhaFinal: numeroLinha,
                                      comentarioAcima: acima, comentarioFim: fimComentario, secao: s.cabecalho)
                    s.listas[chave] = entradas.count
                } else {
                    entrada = Entrada(caminho: caminho, chaveEscrita: chave, valor: .texto(valor),
                                      posicao: Posicao(intervalo: intervalo), intervaloChave: chaveR,
                                      linha: numeroLinha, linhaFinal: numeroLinha,
                                      comentarioAcima: acima, comentarioFim: fimComentario, secao: s.cabecalho)
                }
                s.linhaDaChave[nomeBase] = numeroLinha
                s.tabela[chave] = entrada.valor
                entradas.append(entrada)
            }
            secoes[atual] = s
            acima.removeAll()
        }

        var raiz = Tabela()
        for s in secoes where s.cabecalho != nil || !s.tabela.pares.isEmpty {
            raiz[s.nome] = .tabela(s.tabela)
        }
        var quebra = "\n"
        if let i = b.firstIndex(of: LF), i > 0, b[i - 1] == CR { quebra = "\r\n" }
        return DocumentoConf(formato: .ini, bytes: b, raiz: .tabela(raiz), entradas: entradas, cabecalhos: cabecalhos,
                             quebraDeLinha: quebra, temBOM: inicio == 3)
    }
}
