import Foundation

/// Leitor de YAML 1.2 que guarda a posição (em bytes UTF-8) de cada valor.
///
/// Lê o subconjunto que aparece em arquivos de configuração (docker-compose, GitHub
/// Actions, Kubernetes, `pubspec.yaml`, OpenAPI); detalhes e motivos no README:
///
/// - um documento por arquivo, com `---` opcional no começo e `...` opcional no fim;
/// - mapas e listas em bloco (recuo só com espaços), inclusive lista de mapas
///   (`- nome: x`) e lista no mesmo recuo da chave (`chave:\n- a`);
/// - valores sem aspas (de uma ou várias linhas), entre aspas simples e duplas (com os
///   escapes da norma) e em bloco (`|` e `>`, com os indicadores `-`, `+` e de recuo);
/// - coleções em linha (`[a, b]`, `{a: 1}`), também em várias linhas;
/// - comentários `#`.
///
/// Os tipos seguem o *core schema* do YAML 1.2: `true`/`false`, `null`/`~`/vazio,
/// inteiros (com `0x` e `0o`), decimais, `.inf` e `.nan`; todo o resto é texto
/// (`yes`, `no`, `on` e `off` inclusive).
///
/// Fora do subconjunto — âncoras e aliases (`&x`, `*x`), mesclagem (`<<:`), etiquetas
/// (`!!str`, `!Ref`), vários documentos, chaves complexas (`? `, `[a]: b`), chave vazia
/// ou nula e diretivas (`%YAML`) — o leitor para com um `ErroLeitura` marcado
/// `foraDoSubconjunto`, com a linha: o arquivo abre só no modo Texto, nunca lido pela metade.
public enum LeitorYAML {
    public static func ler(_ bytes: [UInt8]) throws(ErroLeitura) -> DocumentoConf {
        try AnalisadorYAML(bytes).documento()
    }

    public static func ler(_ texto: String) throws(ErroLeitura) -> DocumentoConf {
        try ler(Array(texto.utf8))
    }

    /// Lê um valor isolado (o texto de um campo cru): `[1, a]`, `{a: 1}`, `"x"`, uma lista em
    /// bloco (como está no arquivo, com o recuo)… Texto vazio é nulo, como `chave:`.
    public static func lerValor(_ texto: String) throws(ErroLeitura) -> Valor {
        let doc = try ler(Array(texto.utf8))
        return doc.vazio ? .nulo : doc.valorRaiz
    }

    /// Tipo de um valor sem aspas pelo *core schema* do YAML 1.2.
    public static func resolver(_ s: String) -> Valor {
        switch s {
        case "", "~", "null", "Null", "NULL": return .nulo
        case "true", "True", "TRUE": return .booleano(true)
        case "false", "False", "FALSE": return .booleano(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .decimal(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .decimal(-.infinity)
        case ".nan", ".NaN", ".NAN": return .decimal(.nan)
        default: break
        }
        let u = Array(s.utf8)
        func digito(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        if u.count > 2, u[0] == 0x30, u[1] == 0x6F || u[1] == 0x78 {            // 0o, 0x
            let resto = u[2...]
            let hex = u[1] == 0x78
            let ok = resto.allSatisfy { c in
                hex ? (digito(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)) : (c >= 0x30 && c <= 0x37)
            }
            if ok {
                let t = String(decoding: resto, as: UTF8.self)
                if let n = Int64(t, radix: hex ? 16 : 8) { return .inteiro(n) }
                if let n = UInt64(t, radix: hex ? 16 : 8) { return .decimal(Double(n)) }
                return .decimal(Double(t.utf8.reduce(0.0) { $0 * (hex ? 16 : 8) + Double(Int(String(UnicodeScalar($1)), radix: 16)!) }))
            }
        }
        // [-+]? ( \.[0-9]+ | [0-9]+ ( \.[0-9]* )? ) ( [eE] [-+]? [0-9]+ )?
        var i = 0
        if i < u.count, u[i] == 0x2B || u[i] == 0x2D { i += 1 }
        var antes = 0, depois = 0, ponto = false, expoente = false
        while i < u.count, digito(u[i]) { i += 1; antes += 1 }
        if i < u.count, u[i] == 0x2E {
            ponto = true
            i += 1
            while i < u.count, digito(u[i]) { i += 1; depois += 1 }
        }
        guard antes > 0 || depois > 0 else { return .texto(s) }
        if i < u.count, u[i] == 0x65 || u[i] == 0x45 {
            expoente = true
            i += 1
            if i < u.count, u[i] == 0x2B || u[i] == 0x2D { i += 1 }
            var d = 0
            while i < u.count, digito(u[i]) { i += 1; d += 1 }
            guard d > 0 else { return .texto(s) }
        }
        guard i == u.count else { return .texto(s) }
        if !ponto && !expoente {
            if let n = Int64(s) { return .inteiro(n) }
            return .decimal(Double(s) ?? .nan)
        }
        // `Double` não aceita "1." nem ".5" com sinal em todas as plataformas: normaliza
        var t = s
        if ponto && depois == 0 { t = t.replacingOccurrences(of: ".", with: ".0") }
        if ponto && antes == 0 { t = t.replacingOccurrences(of: ".", with: "0.") }
        return .decimal(Double(t) ?? .nan)
    }
}

extension DocumentoConf {
    /// YAML sem nenhum documento (arquivo vazio ou só com comentários).
    var vazio: Bool { formato == .yaml && cabecalhos.isEmpty && entradas.isEmpty }
}

// MARK: - Constantes

private let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09, ESP: UInt8 = 0x20
private let ASPA: UInt8 = 0x22, APOS: UInt8 = 0x27, CERQUILHA: UInt8 = 0x23, DOIS_PONTOS: UInt8 = 0x3A
private let HIFEN: UInt8 = 0x2D, VIRGULA: UInt8 = 0x2C, BARRA_INV: UInt8 = 0x5C, PONTO: UInt8 = 0x2E
private let ABRE_COL: UInt8 = 0x5B, FECHA_COL: UInt8 = 0x5D, ABRE_CHAVE: UInt8 = 0x7B, FECHA_CHAVE: UInt8 = 0x7D

@inline(__always) private func ehBranco(_ c: UInt8) -> Bool { c == ESP || c == TAB }
@inline(__always) private func ehQuebra(_ c: UInt8) -> Bool { c == LF || c == CR }
@inline(__always) private func ehIndicadorFluxo(_ c: UInt8) -> Bool {
    c == VIRGULA || c == ABRE_COL || c == FECHA_COL || c == ABRE_CHAVE || c == FECHA_CHAVE
}

// MARK: - Árvore

/// Um nó lido, com o intervalo de bytes e, para coleções, os filhos.
private final class NoYAML {
    enum Forma { case plano, simples, duplas, literal, dobrado, vazio, mapaBloco, listaBloco, mapaFluxo, listaFluxo }

    struct Membro {
        var chave: String
        var intervaloChave: Range<Int>
        var no: NoYAML
        var acima: [String]
        var fim: String?
    }

    struct Item {
        var no: NoYAML
        var acima: [String]
        var fim: String?
    }

    var forma: Forma
    var valor: Valor
    var intervalo: Range<Int>
    var membros: [Membro] = []
    var itens: [Item] = []
    /// Texto de um escalar antes de resolver o tipo (para chaves sem aspas: `1: a` tem a chave "1").
    var texto = ""
    /// Comentário na linha do indicador de bloco (`chave: | # nota`).
    var comentarioCabecalho: String?

    init(_ forma: Forma, _ valor: Valor, _ intervalo: Range<Int>) {
        self.forma = forma
        self.valor = valor
        self.intervalo = intervalo
    }

    var ehMapaBloco: Bool { forma == .mapaBloco }
    var ehMapa: Bool { forma == .mapaBloco || forma == .mapaFluxo }
    /// Lista em bloco só de mapas em bloco: vira um grupo de seções, como `[[lista]]` no TOML.
    var ehListaDeMapas: Bool { forma == .listaBloco && !itens.isEmpty && itens.allSatisfy { $0.no.ehMapaBloco } }

    var posicao: Posicao { Posicao(intervalo: intervalo, itens: itens.map(\.no.posicao)) }
}

// MARK: - Analisador

private final class AnalisadorYAML {
    let b: [UInt8]
    let inicio: Int
    var p = 0

    /// Comentários em linhas próprias logo acima do próximo elemento (sem linha em branco no meio).
    var pendentes: [String] = []
    /// Depois de `lacuna()`: se ela passou para outra linha, o recuo (só espaços) dessa
    /// linha e se havia tabulação entre o recuo e o conteúdo.
    var cruzouLinha = false
    var tabNoRecuo = false

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

    @inline(__always) func c(_ i: Int) -> UInt8 { i < b.count && i >= 0 ? b[i] : 0 }
    /// Fim do arquivo, espaço, tabulação ou quebra de linha na posição.
    @inline(__always) func vazioEm(_ i: Int) -> Bool { i >= b.count || ehBranco(b[i]) || ehQuebra(b[i]) }

    func indiceLinha(_ off: Int) -> Int {
        var lo = 0, hi = iniciosDeLinha.count - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if iniciosDeLinha[m] <= off { lo = m } else { hi = m - 1 }
        }
        return lo
    }

    func linha(_ off: Int) -> Int { indiceLinha(min(max(off, 0), b.count)) + 1 }

    func inicioDaLinha(_ off: Int) -> Int {
        var i = min(off, b.count)
        while i > inicio, b[i - 1] != LF { i -= 1 }
        return max(i, i == 0 ? inicio : i)
    }

    /// Coluna em bytes (o recuo antes dos nós é sempre ASCII).
    func coluna(_ off: Int) -> Int { off - inicioDaLinha(off) }

    func fimDaLinha(_ off: Int) -> Int {
        var i = off
        while i < b.count, !ehQuebra(b[i]) { i += 1 }
        return i
    }

    /// `---` ou `...` na coluna 0, seguido de espaço, quebra ou fim.
    func marcador(_ i: Int) -> UInt8? {
        guard i + 3 <= b.count, coluna(i) == 0 else { return nil }
        let x = b[i]
        guard x == HIFEN || x == PONTO, b[i + 1] == x, b[i + 2] == x, vazioEm(i + 3) else { return nil }
        return x
    }

    func erro(_ msg: String, em off: Int) -> ErroLeitura {
        let o = min(max(off, 0), b.count)
        let l = indiceLinha(o)
        var ini = iniciosDeLinha[l]
        if l == 0 { ini = max(ini, inicio) }
        var col = 1
        if ini < o { for i in ini..<o where b[i] & 0xC0 != 0x80 { col += 1 } }
        return ErroLeitura(mensagem: msg, linha: l + 1, coluna: col, deslocamento: o, formato: .yaml)
    }

    func fora(_ msg: String, em off: Int) -> ErroLeitura {
        var e = erro("\(msg) está fora do subconjunto que o Konfig edita pelo formulário; o arquivo abre só no modo Texto",
                     em: off)
        e.foraDoSubconjunto = true
        return e
    }

    func texto(_ r: Range<Int>) -> String { String(decoding: b[r], as: UTF8.self) }

    /// Texto de um comentário a partir do `#`, sem as marcas repetidas e sem espaços nas pontas.
    func comentario(_ r: Range<Int>) -> String {
        var i = r.lowerBound
        while i < r.upperBound, b[i] == CERQUILHA { i += 1 }
        return texto(i..<r.upperBound).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Caracteres

    /// UTF-8 válido e só caracteres que o YAML aceita (sem controles além de tabulação e quebras).
    func valida() throws(ErroLeitura) {
        var i = 0
        let n = b.count
        while i < n {
            let x = b[i]
            if x < 0x80 {
                if (x < 0x20 && x != TAB && x != LF && x != CR) || x == 0x7F {
                    throw erro("caractere de controle (0x\(String(format: "%02X", x))) não é aceito em YAML", em: i)
                }
                if x == CR && c(i + 1) != LF {
                    throw erro("CR sozinho (sem LF) não é quebra de linha aceita", em: i)
                }
                i += 1
                continue
            }
            var tam = 0, minimo: UInt32 = 0, v: UInt32 = 0
            if x & 0xE0 == 0xC0 { tam = 2; minimo = 0x80; v = UInt32(x & 0x1F) }
            else if x & 0xF0 == 0xE0 { tam = 3; minimo = 0x800; v = UInt32(x & 0x0F) }
            else if x & 0xF8 == 0xF0 { tam = 4; minimo = 0x10000; v = UInt32(x & 0x07) }
            else { throw erro("UTF-8 inválido (o arquivo precisa estar em UTF-8)", em: i) }
            guard i + tam <= n else { throw erro("UTF-8 inválido (sequência incompleta)", em: i) }
            for k in 1..<tam {
                let d = b[i + k]
                guard d & 0xC0 == 0x80 else { throw erro("UTF-8 inválido (o arquivo precisa estar em UTF-8)", em: i) }
                v = (v << 6) | UInt32(d & 0x3F)
            }
            if v < minimo || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) { throw erro("UTF-8 inválido", em: i) }
            if (v >= 0x80 && v <= 0x9F && v != 0x85) || v == 0xFFFE || v == 0xFFFF {
                throw erro("caractere de controle (U+\(String(format: "%04X", v))) não é aceito em YAML", em: i)
            }
            i += tam
        }
    }

    // MARK: Espaços e comentários

    /// Pula espaços e um comentário até o fim da linha e, depois, linhas em branco e de
    /// comentário (guardados em `pendentes`). Para no primeiro caractere de conteúdo da
    /// próxima linha (ou no fim do arquivo) — ou, se houver mais texto na mesma linha, nele.
    /// Devolve o comentário que estava no fim da linha.
    @discardableResult
    func lacuna(noInicioDaLinha: Bool = false) throws(ErroLeitura) -> String? {
        var fim: String? = nil
        var i = p
        cruzouLinha = false
        tabNoRecuo = false
        if !noInicioDaLinha {
            while i < b.count, ehBranco(b[i]) { i += 1 }
            if i < b.count, b[i] == CERQUILHA {
                guard i == inicioDaLinha(i) || ehBranco(b[i - 1]) else {
                    throw erro("'#' colado no valor: um comentário precisa de espaço antes", em: i)
                }
                let f = fimDaLinha(i)
                fim = comentario(i..<f)
                i = f
            }
            if i < b.count, !ehQuebra(b[i]) { p = i; return fim }
            // quebra de linha
            if i < b.count { i += b[i] == CR ? 2 : 1 }
        }
        while i < b.count {
            while i < b.count, b[i] == ESP { i += 1 }
            var j = i
            while j < b.count, ehBranco(b[j]) { j += 1 }
            if j >= b.count { i = j; break }
            if ehQuebra(b[j]) {
                pendentes = []          // linha em branco separa o comentário do que vem depois
                i = j + (b[j] == CR ? 2 : 1)
                continue
            }
            if b[j] == CERQUILHA {
                let f = fimDaLinha(j)
                pendentes.append(comentario(j..<f))
                i = f < b.count ? f + (b[f] == CR ? 2 : 1) : f
                continue
            }
            p = j
            cruzouLinha = true
            tabNoRecuo = j > i
            return fim
        }
        p = b.count
        cruzouLinha = true
        return fim
    }

    // MARK: Documento

    var entradas: [Entrada] = []
    var cabecalhos: [Cabecalho] = []

    func documento() throws(ErroLeitura) -> DocumentoConf {
        try valida()
        p = inicio
        try lacuna(noInicioDaLinha: true)
        if p < b.count, b[p] == 0x25, coluna(p) == 0 {                        // %
            throw fora("diretiva (\(texto(p..<min(fimDaLinha(p), p + 20))))", em: p)
        }
        var raiz: NoYAML? = nil
        var acimaDaRaiz: [String] = []
        if marcador(p) == HIFEN {
            let depois = p + 3
            p = depois
            var i = p
            while i < b.count, ehBranco(b[i]) { i += 1 }
            if i < b.count, !ehQuebra(b[i]), b[i] != CERQUILHA {
                p = i
                acimaDaRaiz = pendentes
                raiz = try noComLacuna(pai: -1, linhaNova: false).no
            } else {
                try lacuna()
                if p < b.count, marcador(p) == nil {
                    acimaDaRaiz = pendentes
                    raiz = try noComLacuna(pai: -1, linhaNova: true).no
                } else {
                    raiz = NoYAML(.vazio, .nulo, depois..<depois)
                }
            }
        } else if p < b.count, marcador(p) == nil {
            acimaDaRaiz = pendentes
            raiz = try noComLacuna(pai: -1, linhaNova: true).no
        }
        if p < b.count {
            if marcador(p) == PONTO {
                p += 3
                try lacuna()
                if p < b.count { throw fora("mais de um documento no arquivo", em: p) }
            } else if marcador(p) == HIFEN {
                throw fora("mais de um documento no arquivo (segundo '---')", em: p)
            } else {
                throw erro("texto inesperado (recuo menor que o do começo do documento?)", em: p)
            }
        }

        var valorRaiz: Valor = .tabela(Tabela())
        if let r = raiz {
            valorRaiz = r.valor
            if r.ehMapa {
                percorrer(r, caminho: [], nomes: [], secao: nil)
            } else if r.ehListaDeMapas {
                itensDeLista(r, caminho: [], nomes: [], acimaDaLista: [], fimDaLista: nil)
            } else {
                let iv = r.intervalo
                entradas.append(Entrada(caminho: [], chaveEscrita: "(raiz)", valor: r.valor, posicao: r.posicao,
                                        intervaloChave: iv.lowerBound..<iv.lowerBound, linha: linha(iv.lowerBound),
                                        linhaFinal: linha(max(iv.lowerBound, iv.upperBound - 1)),
                                        comentarioAcima: acimaDaRaiz, comentarioFim: r.comentarioCabecalho, secao: nil))
            }
        }
        var quebra = "\n"
        if let i = b.firstIndex(of: LF), i > 0, b[i - 1] == CR { quebra = "\r\n" }
        return DocumentoConf(formato: .yaml, bytes: b, raiz: valorRaiz, entradas: entradas, cabecalhos: cabecalhos,
                             quebraDeLinha: quebra, temBOM: inicio == 3)
    }

    /// Membros de um mapa: mapas em bloco viram seções; listas só de mapas, grupos; o resto, campos.
    func percorrer(_ mapa: NoYAML, caminho: Caminho, nomes: [String], secao: Int?) {
        for m in mapa.membros {
            let cam = caminho + [.chave(m.chave)]
            if m.no.ehMapaBloco {
                let idx = cabecalhos.count
                cabecalhos.append(Cabecalho(caminho: cam, nomes: nomes + [m.chave], ehListaDeTabelas: false,
                                            intervalo: m.no.intervalo, linha: linha(m.intervaloChave.lowerBound),
                                            comentarioAcima: m.acima, comentarioFim: m.fim))
                percorrer(m.no, caminho: cam, nomes: nomes + [m.chave], secao: idx)
            } else if m.no.ehListaDeMapas {
                itensDeLista(m.no, caminho: cam, nomes: nomes + [m.chave], acimaDaLista: m.acima, fimDaLista: m.fim)
            } else {
                let iv = m.no.intervalo
                entradas.append(Entrada(caminho: cam, chaveEscrita: m.chave, valor: m.no.valor, posicao: m.no.posicao,
                                        intervaloChave: m.intervaloChave, linha: linha(m.intervaloChave.lowerBound),
                                        linhaFinal: linha(max(iv.lowerBound, iv.upperBound - 1)),
                                        comentarioAcima: m.acima, comentarioFim: m.fim, secao: secao))
            }
        }
    }

    /// Cada mapa de uma lista de mapas vira uma seção, como um item de `[[lista]]` do TOML.
    func itensDeLista(_ l: NoYAML, caminho: Caminho, nomes: [String], acimaDaLista: [String], fimDaLista: String?) {
        let daLista = acimaDaLista + [fimDaLista].compactMap { $0 }
        for (j, item) in l.itens.enumerated() {
            let cam = caminho + [.indice(j)]
            let idx = cabecalhos.count
            cabecalhos.append(Cabecalho(caminho: cam, nomes: nomes, ehListaDeTabelas: true, intervalo: item.no.intervalo,
                                        linha: linha(item.no.intervalo.lowerBound),
                                        comentarioAcima: daLista + item.acima, comentarioFim: item.fim))
            percorrer(item.no, caminho: cam, nomes: nomes, secao: idx)
        }
    }

    // MARK: Nós em bloco

    /// Lê o nó que começa em `p` e o que sobra da linha (e as linhas em branco e de
    /// comentário seguintes). `pai` é o recuo do mapa ou da lista que contém o nó (−1 na
    /// raiz); `linhaNova`, se o nó começa no início de uma linha (só então pode ser um
    /// mapa ou uma lista em bloco). Coleções em bloco já terminam depois da lacuna.
    func noComLacuna(pai n: Int, linhaNova: Bool) throws(ErroLeitura) -> (no: NoYAML, fim: String?) {
        let x = b[p]
        switch x {
        case 0x26: throw fora("âncora (&)", em: p)
        case 0x2A: throw fora("alias (*)", em: p)
        case 0x21: throw fora("etiqueta de tipo (!)", em: p)
        case 0x3F where vazioEm(p + 1): throw fora("chave complexa ('? ')", em: p)
        case HIFEN where vazioEm(p + 1):
            guard linhaNova else { throw erro("uma lista em bloco ('- ') não pode começar nesta linha", em: p) }
            if tabNoRecuo { throw erro("tabulação no recuo (o recuo em YAML é só com espaços)", em: p) }
            return (try listaBloco(coluna: coluna(p)), nil)
        case 0x7C, 0x3E:                                                     // | >
            let no = try escalarBloco(pai: n)
            try lacuna()
            return (no, no.comentarioCabecalho)
        default: break
        }
        if try ehChaveImplicita() {
            guard linhaNova else {
                throw erro("um mapa ('chave: valor') não pode começar nesta linha; ponha o valor entre aspas ou numa linha própria", em: p)
            }
            if tabNoRecuo { throw erro("tabulação no recuo (o recuo em YAML é só com espaços)", em: p) }
            return (try mapaBloco(coluna: coluna(p)), nil)
        }
        let no: NoYAML
        switch x {
        case ABRE_COL, ABRE_CHAVE: no = try fluxo(pai: n)
        case ASPA, APOS: no = try escalarAspas(pai: n, fluxo: false)
        default: no = try escalarPlano(pai: n, fluxo: false)
        }
        let fim = try lacuna()
        if !cruzouLinha {
            if b[p] == DOIS_PONTOS {
                throw erro("':' inesperado: um mapa não pode começar aqui (chave em várias linhas, ou valor com ': ' que precisa de aspas)", em: p)
            }
            throw erro("texto inesperado depois do valor", em: p)
        }
        return (no, fim)
    }

    /// Há uma chave (`chave:` seguida de espaço ou fim de linha) começando em `p`, nesta linha?
    func ehChaveImplicita() throws(ErroLeitura) -> Bool {
        let x = b[p]
        var j = p
        let fimLinha = fimDaLinha(p)
        switch x {
        case ASPA, APOS:
            j += 1
            while j < fimLinha {
                if x == ASPA && b[j] == BARRA_INV { j += 2; continue }
                if b[j] == x {
                    if x == APOS && c(j + 1) == APOS { j += 2; continue }
                    break
                }
                j += 1
            }
            guard j < fimLinha else { return false }
            j += 1
            while j < fimLinha, ehBranco(b[j]) { j += 1 }
            return j < fimLinha && b[j] == DOIS_PONTOS && vazioEm(j + 1)
        case ABRE_COL, ABRE_CHAVE:
            // coleção em linha usada como chave: `[a, b]: c`
            var nivel = 0
            var aspa: UInt8 = 0
            while j < fimLinha {
                let y = b[j]
                if aspa != 0 {
                    if aspa == ASPA && y == BARRA_INV { j += 2; continue }
                    if y == aspa { aspa = 0 }
                } else if y == ASPA || y == APOS {
                    aspa = y
                } else if y == ABRE_COL || y == ABRE_CHAVE {
                    nivel += 1
                } else if y == FECHA_COL || y == FECHA_CHAVE {
                    nivel -= 1
                    if nivel == 0 { break }
                } else if y == CERQUILHA, ehBranco(b[j - 1]) {
                    return false
                }
                j += 1
            }
            guard j < fimLinha else { return false }
            j += 1
            while j < fimLinha, ehBranco(b[j]) { j += 1 }
            if j < fimLinha, b[j] == DOIS_PONTOS, vazioEm(j + 1) {
                throw fora("chave complexa (coleção como chave)", em: p)
            }
            return false
        case DOIS_PONTOS where vazioEm(p + 1):
            throw fora("chave vazia (': valor')", em: p)
        default:
            if !podeComecarPlano(p, fluxo: false) { return false }
            while j < fimLinha {
                if b[j] == DOIS_PONTOS && vazioEm(j + 1) { return true }
                if b[j] == CERQUILHA && j > p && ehBranco(b[j - 1]) { return false }
                j += 1
            }
            return false
        }
    }

    /// Lê a chave em `p` (numa linha só) e devolve o texto e o intervalo; `p` fica logo depois dela.
    func chave(fluxo: Bool) throws(ErroLeitura) -> (String, Range<Int>, NoYAML) {
        let ini = p
        let x = b[p]
        switch x {
        case 0x26: throw fora("âncora (&)", em: p)
        case 0x2A: throw fora("alias (*)", em: p)
        case 0x21: throw fora("etiqueta de tipo (!)", em: p)
        case 0x3F where vazioEm(p + 1) || (fluxo && ehIndicadorFluxo(c(p + 1))): throw fora("chave complexa ('? ')", em: p)
        case ABRE_COL, ABRE_CHAVE: throw fora("chave complexa (coleção como chave)", em: p)
        case DOIS_PONTOS where vazioEm(p + 1) || (fluxo && ehIndicadorFluxo(c(p + 1))): throw fora("chave vazia (': valor')", em: p)
        default: break
        }
        let no: NoYAML
        if x == ASPA || x == APOS {
            no = try escalarAspas(pai: -1, fluxo: fluxo)
        } else {
            guard podeComecarPlano(p, fluxo: fluxo) else {
                throw erro("caractere '\(String(UnicodeScalar(x)))' não pode começar uma chave sem aspas", em: p)
            }
            // dentro de `{ }` a chave pode ocupar várias linhas; num mapa em bloco, não
            no = try escalarPlano(pai: -1, fluxo: fluxo, umaLinha: !fluxo)
        }
        if !fluxo, linha(no.intervalo.lowerBound) != linha(max(no.intervalo.lowerBound, no.intervalo.upperBound - 1)) {
            throw erro("chave em várias linhas não é aceita", em: ini)
        }
        guard case .texto(let k) = no.forma == .plano ? .texto(no.texto) : no.valor else {
            throw erro("chave inválida", em: ini)
        }
        if no.forma == .plano {
            if k == "<<" { throw fora("mesclagem ('<<:')", em: ini) }
            if case .nulo = no.valor { throw fora("chave nula ('\(k)')", em: ini) }
        }
        return (k, no.intervalo, no)
    }

    /// Mapa em bloco cujas chaves estão na coluna `m`; `p` está na primeira chave.
    func mapaBloco(coluna m: Int) throws(ErroLeitura) -> NoYAML {
        let ini = p
        var membros: [NoYAML.Membro] = []
        var linhaDaChave: [String: Int] = [:]
        var tabela = Tabela()
        var fimValor = p
        while true {
            let acima = pendentes
            pendentes = []
            if b[p] == HIFEN && vazioEm(p + 1) {
                throw erro("item de lista ('- ') onde se esperava uma chave do mapa (confira o recuo)", em: p)
            }
            let (k, rChave, _) = try chave(fluxo: false)
            while p < b.count, ehBranco(b[p]) { p += 1 }
            guard p < b.count, b[p] == DOIS_PONTOS else { throw erro("esperava ':' depois da chave '\(k)'", em: p) }
            guard vazioEm(p + 1) else { throw erro("depois de ':' precisa vir espaço ou fim de linha", em: p + 1) }
            if let l = linhaDaChave[k] {
                throw erro("a chave '\(k)' já apareceu na linha \(l) neste mapa; chave repetida não é aceita", em: rChave.lowerBound)
            }
            linhaDaChave[k] = linha(rChave.lowerBound)
            p += 1
            let (no, fim) = try valorDeChave(recuo: m)
            membros.append(NoYAML.Membro(chave: k, intervaloChave: rChave, no: no, acima: acima, fim: fim))
            tabela.pares.append(Tabela.Par(chave: k, valor: no.valor))
            fimValor = max(no.intervalo.upperBound, rChave.upperBound + 1)
            // p está no próximo conteúdo
            if p >= b.count || marcador(p) != nil { break }
            let col = coluna(p)
            if col < m { break }
            if col > m { throw erro("recuo inesperado (esperava uma chave na coluna \(m + 1))", em: p) }
            if tabNoRecuo { throw erro("tabulação no recuo (o recuo em YAML é só com espaços)", em: p) }
        }
        let no = NoYAML(.mapaBloco, .tabela(tabela), ini..<fimValor)
        no.membros = membros
        return no
    }

    /// Valor depois de `chave:` num mapa em bloco de recuo `m`; `p` está logo depois do `:`.
    func valorDeChave(recuo m: Int) throws(ErroLeitura) -> (NoYAML, String?) {
        let depois = p
        while p < b.count, ehBranco(b[p]) { p += 1 }
        if p >= b.count || ehQuebra(b[p]) || b[p] == CERQUILHA {
            p = depois
            let fim = try lacuna()
            if p < b.count, marcador(p) == nil {
                let col = coluna(p)
                if col > m {
                    return (try noComLacuna(pai: m, linhaNova: true).no, fim)
                }
                if col == m, b[p] == HIFEN, vazioEm(p + 1) {
                    // lista no mesmo recuo da chave (`chave:\n- a`)
                    if tabNoRecuo { throw erro("tabulação no recuo (o recuo em YAML é só com espaços)", em: p) }
                    return (try listaBloco(coluna: m), fim)
                }
            }
            return (NoYAML(.vazio, .nulo, depois..<depois), fim)
        }
        let r = try noComLacuna(pai: m, linhaNova: false)
        return (r.no, r.fim)
    }

    /// Lista em bloco com os `-` na coluna `col`; `p` está no primeiro `-`.
    func listaBloco(coluna col: Int) throws(ErroLeitura) -> NoYAML {
        let traco0 = p
        var itens: [NoYAML.Item] = []
        var valores: [Valor] = []
        var fimItem = p + 1
        while true {
            let acima = pendentes
            pendentes = []
            let traco = p
            p += 1
            while p < b.count, ehBranco(b[p]) { p += 1 }
            let no: NoYAML
            var fim: String? = nil
            if p >= b.count || ehQuebra(b[p]) || b[p] == CERQUILHA {
                p = traco + 1
                fim = try lacuna()
                if p < b.count, marcador(p) == nil, coluna(p) > col {
                    no = try noComLacuna(pai: col, linhaNova: true).no
                } else {
                    no = NoYAML(.vazio, .nulo, (traco + 1)..<(traco + 1))
                }
            } else {
                let tab = b[(traco + 1)..<p].contains(TAB)
                // lista ou mapa compactos (`- - a`, `- chave: valor`)
                var compacto = b[p] == HIFEN && vazioEm(p + 1)
                if !compacto { compacto = try ehChaveImplicita() }
                if compacto && tab { throw erro("tabulação no recuo (o recuo em YAML é só com espaços)", em: p) }
                tabNoRecuo = false
                let r = try noComLacuna(pai: col, linhaNova: true)
                no = r.no
                fim = r.fim
            }
            itens.append(NoYAML.Item(no: no, acima: acima, fim: fim))
            valores.append(no.valor)
            fimItem = fimDaLinha(max(no.intervalo.upperBound, traco + 1))
            if p >= b.count || marcador(p) != nil { break }
            let c2 = coluna(p)
            if c2 < col { break }
            if c2 > col { throw erro("recuo inesperado (esperava '- ' na coluna \(col + 1))", em: p) }
            guard b[p] == HIFEN, vazioEm(p + 1) else { break }
            if tabNoRecuo { throw erro("tabulação no recuo (o recuo em YAML é só com espaços)", em: p) }
        }
        // a lista ocupa as linhas inteiras dos itens (do começo da linha do primeiro `-` ao fim
        // da linha do último item): assim dá para acrescentar e tirar linhas
        let iniLinha = inicioDaLinha(traco0)
        let ini = b[iniLinha..<traco0].allSatisfy { $0 == ESP } ? iniLinha : traco0
        let no = NoYAML(.listaBloco, .lista(valores), ini..<fimItem)
        no.itens = itens
        return no
    }

    // MARK: Escalares

    /// O caractere em `i` pode começar um valor sem aspas?
    func podeComecarPlano(_ i: Int, fluxo: Bool) -> Bool {
        let x = c(i)
        switch x {
        case 0, ESP, TAB, LF, CR: return false
        case VIRGULA, ABRE_COL, FECHA_COL, ABRE_CHAVE, FECHA_CHAVE, CERQUILHA, 0x26, 0x2A, 0x21, 0x7C, 0x3E,
             APOS, ASPA, 0x25, 0x40, 0x60:                                   // , [ ] { } # & * ! | > ' " % @ `
            return false
        case HIFEN, 0x3F, DOIS_PONTOS:                                        // - ? :
            let y = c(i + 1)
            return !vazioEm(i + 1) && !(fluxo && ehIndicadorFluxo(y))
        default:
            return true
        }
    }

    /// Valor sem aspas, de uma ou várias linhas (as quebras viram espaço; linhas em branco, `\n`).
    func escalarPlano(pai n: Int, fluxo: Bool, umaLinha: Bool = false) throws(ErroLeitura) -> NoYAML {
        let ini = p
        guard podeComecarPlano(p, fluxo: fluxo) else {
            let x = b[p]
            if x == 0x40 || x == 0x60 { throw erro("'\(String(UnicodeScalar(x)))' é reservado e não pode começar um valor sem aspas", em: p) }
            throw erro("caractere '\(String(UnicodeScalar(x)))' inesperado", em: p)
        }
        var saida: [UInt8] = []
        var fim = p
        /// Lê o texto de uma linha a partir de `i`; devolve onde parou e o fim do texto (sem brancos).
        func trecho(_ i0: Int) -> (parou: Int, fimTexto: Int) {
            var i = i0
            var ft = i0
            while i < b.count, !ehQuebra(b[i]) {
                let x = b[i]
                if x == DOIS_PONTOS && (vazioEm(i + 1) || (fluxo && ehIndicadorFluxo(c(i + 1)))) { break }
                if x == CERQUILHA && i > i0 && ehBranco(b[i - 1]) { break }
                if fluxo && ehIndicadorFluxo(x) { break }
                i += 1
                if !ehBranco(x) { ft = i }
            }
            return (i, ft)
        }
        let (parou, ft) = trecho(p)
        saida += b[p..<ft]
        fim = ft
        p = ft
        var i = parou
        while !umaLinha, i >= b.count || ehQuebra(b[i]) {
            // linhas seguintes: continuação se tiverem recuo maior que o do pai
            var k = i
            var vazias = 0
            var proxima: Int? = nil
            while k < b.count {
                k += b[k] == CR ? 2 : 1                                       // a quebra
                let ls = k
                while k < b.count, b[k] == ESP { k += 1 }
                let espacos = k - ls
                while k < b.count, ehBranco(b[k]) { k += 1 }
                if k >= b.count { break }
                if ehQuebra(b[k]) { vazias += 1; continue }
                if b[k] == CERQUILHA { break }                               // comentário termina o valor
                if espacos == 0, marcador(ls) != nil { break }
                if !fluxo, espacos <= n { break }
                if fluxo, n >= 0, espacos <= n { break }
                proxima = k
                break
            }
            guard let cs = proxima else { break }
            let (parou2, ft2) = trecho(cs)
            if ft2 == cs { break }                                            // a linha começa com um indicador
            if vazias == 0 { saida.append(ESP) } else { saida += [UInt8](repeating: LF, count: vazias) }
            saida += b[cs..<ft2]
            fim = ft2
            p = ft2
            i = parou2
        }
        let s = String(decoding: saida, as: UTF8.self)
        let no = NoYAML(.plano, LeitorYAML.resolver(s), ini..<fim)
        no.texto = s
        return no
    }

    /// Valor entre aspas simples (`''` é uma aspa) ou duplas (com escapes). Pode ocupar
    /// várias linhas: cada quebra vira espaço; linhas em branco, `\n`.
    func escalarAspas(pai n: Int, fluxo: Bool) throws(ErroLeitura) -> NoYAML {
        let ini = p
        let q = b[p]
        p += 1
        var s: [UInt8] = []
        /// Brancos literais no fim de `s` (somem antes de uma quebra; os de escapes ficam).
        var brancosFinais = 0
        func poe(_ v: UInt32) {
            s += Array(String(Character(Unicode.Scalar(v)!)).utf8)
            brancosFinais = 0
        }
        /// Depois de uma quebra (já consumida): linhas em branco e o recuo da linha seguinte.
        func continuacao(dobrar: Bool) throws(ErroLeitura) {
            var vazias = 0
            while true {
                let ls = p
                while p < b.count, b[p] == ESP { p += 1 }
                let espacos = p - ls
                while p < b.count, ehBranco(b[p]) { p += 1 }
                guard p < b.count else { throw erro("aspas abertas e não fechadas", em: ini) }
                if ehQuebra(b[p]) {
                    vazias += 1
                    p += b[p] == CR ? 2 : 1
                    continue
                }
                if espacos == 0, marcador(ls) != nil {
                    throw erro("marcador de documento dentro de um texto entre aspas", em: ls)
                }
                if n >= 0, espacos <= n {
                    throw erro("linha de continuação do texto entre aspas com recuo insuficiente", em: p)
                }
                break
            }
            if vazias > 0 { s += [UInt8](repeating: LF, count: vazias) } else if dobrar { s.append(ESP) }
            brancosFinais = 0
        }
        while true {
            guard p < b.count else { throw erro(q == ASPA ? "aspas duplas abertas e não fechadas" : "aspas simples abertas e não fechadas", em: ini) }
            let x = b[p]
            if x == q {
                if q == APOS && c(p + 1) == APOS { s.append(APOS); brancosFinais = 0; p += 2; continue }
                p += 1
                break
            }
            if ehQuebra(x) {
                s.removeLast(brancosFinais)
                brancosFinais = 0
                p += x == CR ? 2 : 1
                try continuacao(dobrar: true)
                continue
            }
            if q == ASPA && x == BARRA_INV {
                let e = c(p + 1)
                var v: UInt32
                var tam = 2
                switch e {
                case LF, CR:
                    // quebra escapada: junta as linhas sem espaço
                    p += e == CR ? 3 : 2
                    brancosFinais = 0
                    try continuacao(dobrar: false)
                    continue
                case 0x30: v = 0
                case 0x61: v = 7
                case 0x62: v = 8
                case 0x74, TAB: v = 9
                case 0x6E: v = 0x0A
                case 0x76: v = 0x0B
                case 0x66: v = 0x0C
                case 0x72: v = 0x0D
                case 0x65: v = 0x1B
                case ESP: v = 0x20
                case ASPA: v = 0x22
                case 0x2F: v = 0x2F
                case BARRA_INV: v = 0x5C
                case 0x4E: v = 0x85
                case 0x5F: v = 0xA0
                case 0x4C: v = 0x2028
                case 0x50: v = 0x2029
                case 0x78, 0x75, 0x55:                                        // x u U
                    let dig = e == 0x78 ? 2 : e == 0x75 ? 4 : 8
                    guard p + 2 + dig <= b.count,
                          let h = UInt32(String(decoding: b[(p + 2)..<(p + 2 + dig)], as: UTF8.self), radix: 16),
                          b[(p + 2)..<(p + 2 + dig)].allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) })
                    else { throw erro("escape '\\\(String(UnicodeScalar(e)))' precisa de \(dig) dígitos hexadecimais", em: p) }
                    v = h
                    tam = 2 + dig
                    if v >= 0xD800 && v <= 0xDBFF, e == 0x75, c(p + 6) == BARRA_INV, c(p + 7) == 0x75, p + 12 <= b.count,
                       let lo = UInt32(String(decoding: b[(p + 8)..<(p + 12)], as: UTF8.self), radix: 16),
                       lo >= 0xDC00 && lo <= 0xDFFF {
                        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                        tam = 12
                    }
                    guard Unicode.Scalar(v) != nil else { throw erro("escape de caractere inválido (U+\(String(v, radix: 16, uppercase: true)))", em: p) }
                default:
                    throw erro("escape '\\\(e < 0x80 ? String(UnicodeScalar(e)) : "…")' não existe em YAML", em: p)
                }
                poe(v)
                p += tam
                continue
            }
            s.append(x)
            if ehBranco(x) { brancosFinais += 1 } else { brancosFinais = 0 }
            p += 1
        }
        return NoYAML(q == ASPA ? .duplas : .simples, .texto(String(decoding: s, as: UTF8.self)), ini..<p)
    }

    /// Texto em bloco `|` (literal) ou `>` (dobrado), com os indicadores de corte (`-`, `+`) e de recuo.
    /// `p` fica no fim da última linha do valor.
    func escalarBloco(pai n: Int) throws(ErroLeitura) -> NoYAML {
        let ini = p
        let literal = b[p] == 0x7C
        p += 1
        var indicador: Int? = nil
        var corte = 0                                                       // -1 strip, 0 clip, +1 keep
        var viuCorte = false
        for _ in 0..<2 {
            let x = c(p)
            if x >= 0x31 && x <= 0x39 && indicador == nil { indicador = Int(x - 0x30); p += 1 }
            else if (x == 0x2B || x == HIFEN) && !viuCorte { corte = x == 0x2B ? 1 : -1; viuCorte = true; p += 1 }
            else if x == 0x30 { throw erro("o indicador de recuo vai de 1 a 9", em: p) }
            else { break }
        }
        guard vazioEm(p) else { throw erro("depois de '\(literal ? "|" : ">")' só podem vir os indicadores, espaço e comentário", em: p) }
        while p < b.count, ehBranco(b[p]) { p += 1 }
        var comentarioCab: String? = nil
        if p < b.count, b[p] == CERQUILHA {
            let f = fimDaLinha(p)
            comentarioCab = comentario(p..<f)
            p = f
        }
        guard p >= b.count || ehQuebra(b[p]) else { throw erro("texto inesperado depois do indicador de bloco", em: p) }
        let fimCabecalho = p
        let minimo = n + 1

        // linhas: (início, fim, espaços no começo)
        var linhas: [(ini: Int, fim: Int, espacos: Int)] = []
        var i = p
        while i < b.count {
            i += b[i] == CR ? 2 : 1
            if i >= b.count { break }
            let f = fimDaLinha(i)
            var e = 0
            while i + e < f, b[i + e] == ESP { e += 1 }
            linhas.append((i, f, e))
            i = f
        }
        func vazia(_ l: (ini: Int, fim: Int, espacos: Int)) -> Bool { l.ini + l.espacos == l.fim }

        var recuo: Int
        if let d = indicador {
            recuo = max(n, 0) + d
        } else {
            var maxVazio = 0
            recuo = minimo
            for l in linhas {
                if vazia(l) { maxVazio = max(maxVazio, l.espacos); continue }
                if l.espacos >= minimo, !(l.espacos == 0 && marcador(l.ini) != nil) {
                    if maxVazio > l.espacos {
                        throw erro("linha em branco com mais espaços que a primeira linha do texto em bloco", em: l.ini)
                    }
                    recuo = l.espacos
                } else {
                    recuo = max(minimo, maxVazio)
                }
                break
            }
            if linhas.allSatisfy(vazia) { recuo = max(minimo, linhas.map(\.espacos).max() ?? 0) }
        }
        recuo = max(recuo, 0)

        // separa as linhas do bloco: vazias e de conteúdo, até a primeira com recuo menor
        var conteudo: [(texto: Range<Int>, vaziasAntes: Int)] = []
        var vazias = 0
        var fimConteudo = fimCabecalho
        var fimTotal = fimCabecalho
        for l in linhas {
            if vazia(l) && l.espacos <= recuo {
                // só espaços (até o recuo): linha vazia; com mais espaços, os de sobra são conteúdo
                vazias += 1
                fimTotal = l.fim
                continue
            }
            if l.espacos < recuo {
                // linha só com brancos e tabulação antes do recuo: tabulação no recuo
                if b[(l.ini + l.espacos)..<l.fim].allSatisfy({ ehBranco($0) || $0 == CR }) {
                    throw erro("tabulação no recuo do texto em bloco (o recuo em YAML é só com espaços)", em: l.ini + l.espacos)
                }
                break
            }
            if recuo == 0, marcador(l.ini) != nil { break }
            conteudo.append(((l.ini + recuo)..<l.fim, vazias))
            vazias = 0
            fimConteudo = l.fim
            fimTotal = l.fim
        }
        var r: [UInt8] = []
        var anteriorNormal = false
        for (k, linhaC) in conteudo.enumerated() {
            let t = b[linhaC.texto]
            let normal = !(t.first.map(ehBranco) ?? false)
            if k == 0 {
                r += [UInt8](repeating: LF, count: linhaC.vaziasAntes)
            } else if !literal && anteriorNormal && normal {
                if linhaC.vaziasAntes == 0 { r.append(ESP) } else { r += [UInt8](repeating: LF, count: linhaC.vaziasAntes) }
            } else {
                r += [UInt8](repeating: LF, count: linhaC.vaziasAntes + 1)
            }
            r += t
            anteriorNormal = normal
        }
        // a última linha vale como terminada por quebra mesmo no fim do arquivo (como na yaml-test-suite)
        if conteudo.isEmpty {
            if corte == 1 { r += [UInt8](repeating: LF, count: vazias) }
        } else {
            if corte >= 0 { r.append(LF) }
            if corte == 1 { r += [UInt8](repeating: LF, count: vazias) }
        }
        // o valor vai do indicador ao fim da última linha que é dele (com `+`, as vazias do fim)
        let fim = corte == 1 ? fimTotal : (conteudo.isEmpty ? fimCabecalho : fimConteudo)
        p = fim
        let no = NoYAML(literal ? .literal : .dobrado, .texto(String(decoding: r, as: UTF8.self)), ini..<fim)
        no.comentarioCabecalho = comentarioCab
        return no
    }

    // MARK: Coleções em linha

    /// Espaços, quebras e comentários dentro de uma coleção em linha. As linhas seguintes
    /// precisam de recuo maior que `n` (o recuo do bloco que contém a coleção).
    func espacoFluxo(pai n: Int) throws(ErroLeitura) {
        while p < b.count {
            let x = b[p]
            if ehBranco(x) { p += 1; continue }
            if x == CERQUILHA {
                guard ehBranco(c(p - 1)) || ehQuebra(c(p - 1)) else {
                    throw erro("'#' colado: um comentário precisa de espaço antes", em: p)
                }
                p = fimDaLinha(p)
                continue
            }
            if ehQuebra(x) {
                p += x == CR ? 2 : 1
                let ls = p
                while p < b.count, b[p] == ESP { p += 1 }
                let espacos = p - ls
                if espacos == 0, marcador(ls) != nil {
                    throw erro("marcador de documento dentro de uma coleção em linha", em: ls)
                }
                var k = p
                while k < b.count, ehBranco(b[k]) { k += 1 }
                if k < b.count, !ehQuebra(b[k]), b[k] != CERQUILHA, n >= 0, espacos <= n {
                    throw erro("recuo insuficiente dentro da coleção em linha", em: k)
                }
                continue
            }
            break
        }
    }

    func noFluxo(pai n: Int) throws(ErroLeitura) -> NoYAML {
        guard p < b.count else { throw erro("coleção em linha não fechada", em: p) }
        let x = b[p]
        switch x {
        case 0x26: throw fora("âncora (&)", em: p)
        case 0x2A: throw fora("alias (*)", em: p)
        case 0x21: throw fora("etiqueta de tipo (!)", em: p)
        case ABRE_COL, ABRE_CHAVE: return try fluxo(pai: n)
        case ASPA, APOS: return try escalarAspas(pai: n, fluxo: true)
        case 0x3F where vazioEm(p + 1) || ehIndicadorFluxo(c(p + 1)): throw fora("chave complexa ('? ')", em: p)
        case HIFEN where vazioEm(p + 1): throw erro("lista em bloco ('- ') dentro de uma coleção em linha", em: p)
        case DOIS_PONTOS where vazioEm(p + 1) || ehIndicadorFluxo(c(p + 1)): throw fora("chave vazia (': valor')", em: p)
        default:
            guard podeComecarPlano(p, fluxo: true) else {
                throw erro("caractere '\(String(UnicodeScalar(x)))' inesperado na coleção em linha", em: p)
            }
            return try escalarPlano(pai: n, fluxo: true)
        }
    }

    /// Coleção em linha `[…]` ou `{…}`, também em várias linhas.
    func fluxo(pai n: Int) throws(ErroLeitura) -> NoYAML {
        let ini = p
        let ehLista = b[p] == ABRE_COL
        let fecha = ehLista ? FECHA_COL : FECHA_CHAVE
        p += 1
        var itens: [NoYAML.Item] = []
        var membros: [NoYAML.Membro] = []
        var tabela = Tabela()
        var valores: [Valor] = []
        var linhaDaChave: [String: Int] = [:]
        while true {
            try espacoFluxo(pai: n)
            guard p < b.count else { throw erro(ehLista ? "falta o ']' que fecha a lista" : "falta o '}' que fecha o mapa", em: ini) }
            if b[p] == fecha { p += 1; break }
            if b[p] == VIRGULA { throw erro("',' sem valor antes", em: p) }
            if ehLista {
                var no = try noFluxo(pai: n)
                try espacoFluxo(pai: n)
                if p < b.count, b[p] == DOIS_PONTOS,
                   vazioEm(p + 1) || ehIndicadorFluxo(c(p + 1)) || no.forma != .plano {
                    // par sozinho dentro da lista: `[a: 1]` é `[{a: 1}]`
                    guard no.forma == .plano || no.forma == .simples || no.forma == .duplas else {
                        throw fora("chave complexa (coleção como chave)", em: no.intervalo.lowerBound)
                    }
                    if linha(no.intervalo.lowerBound) != linha(p) { throw erro("chave em várias linhas não é aceita", em: no.intervalo.lowerBound) }
                    let k: String
                    if no.forma == .plano {
                        k = no.texto
                        if k == "<<" { throw fora("mesclagem ('<<:')", em: no.intervalo.lowerBound) }
                        if case .nulo = no.valor { throw fora("chave nula ('\(k)')", em: no.intervalo.lowerBound) }
                    } else if case .texto(let t) = no.valor { k = t } else { k = "" }
                    p += 1
                    try espacoFluxo(pai: n)
                    let valor: NoYAML
                    if p < b.count, b[p] == VIRGULA || b[p] == FECHA_COL {
                        valor = NoYAML(.vazio, .nulo, p..<p)
                    } else {
                        valor = try noFluxo(pai: n)
                    }
                    let par = NoYAML(.mapaFluxo, .tabela(Tabela(pares: [Tabela.Par(chave: k, valor: valor.valor)])),
                                     no.intervalo.lowerBound..<valor.intervalo.upperBound)
                    par.membros = [NoYAML.Membro(chave: k, intervaloChave: no.intervalo, no: valor, acima: [], fim: nil)]
                    no = par
                    try espacoFluxo(pai: n)
                }
                itens.append(NoYAML.Item(no: no, acima: [], fim: nil))
                valores.append(no.valor)
            } else {
                if b[p] == DOIS_PONTOS, vazioEm(p + 1) || ehIndicadorFluxo(c(p + 1)) {
                    throw fora("chave vazia (': valor')", em: p)
                }
                let (k, rChave, kNo) = try chave(fluxo: true)
                try espacoFluxo(pai: n)
                let valor: NoYAML
                if p < b.count, b[p] == DOIS_PONTOS,
                   vazioEm(p + 1) || ehIndicadorFluxo(c(p + 1)) || kNo.forma != .plano {
                    p += 1
                    try espacoFluxo(pai: n)
                    if p < b.count, b[p] == VIRGULA || b[p] == FECHA_CHAVE {
                        valor = NoYAML(.vazio, .nulo, p..<p)
                    } else {
                        valor = try noFluxo(pai: n)
                    }
                } else {
                    // chave sem valor: `{a, b: 1}` tem a: null
                    valor = NoYAML(.vazio, .nulo, rChave.upperBound..<rChave.upperBound)
                }
                if let l = linhaDaChave[k] {
                    throw erro("a chave '\(k)' já apareceu na linha \(l) neste mapa; chave repetida não é aceita", em: rChave.lowerBound)
                }
                linhaDaChave[k] = linha(rChave.lowerBound)
                membros.append(NoYAML.Membro(chave: k, intervaloChave: rChave, no: valor, acima: [], fim: nil))
                tabela.pares.append(Tabela.Par(chave: k, valor: valor.valor))
            }
            try espacoFluxo(pai: n)
            guard p < b.count else { throw erro(ehLista ? "falta o ']' que fecha a lista" : "falta o '}' que fecha o mapa", em: ini) }
            if b[p] == VIRGULA { p += 1; continue }
            if b[p] == fecha { continue }
            throw erro("esperava ',' ou '\(ehLista ? "]" : "}")'", em: p)
        }
        let no = NoYAML(ehLista ? .listaFluxo : .mapaFluxo, ehLista ? .lista(valores) : .tabela(tabela), ini..<p)
        no.itens = itens
        no.membros = membros
        return no
    }
}
