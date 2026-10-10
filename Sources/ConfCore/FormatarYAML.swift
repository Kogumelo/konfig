import Foundation

/// Escreve valores YAML imitando o estilo do valor antigo.
///
/// - Texto: sem aspas continua sem aspas quando cabe (`cabeSemAspas`); aspas simples
///   continuam simples (sem quebra de linha nem controles); aspas duplas continuam duplas;
///   bloco `|`/`>` continua bloco, com o mesmo recuo e o indicador de corte (`-`, `+`)
///   que o texto novo pede. Quando o estilo não serve, aspas duplas.
/// - **Aspas de proteção**: um texto que um leitor YAML 1.1 (PyYAML, o `yaml` do Go v2,
///   Ruby…) entenderia como sim/não, número, data ou nulo (`no`, `on`, `1e3`, `010`,
///   `2024-01-01`, `null`…) vai entre aspas, mesmo que no YAML 1.2 já seja texto.
/// - Número: inteiro na mesma base (`0x`, `0o`) e com o `+`; decimal com expoente e casas
///   como o original; `.inf`/`.nan` na mesma caixa. Sim/não e nulo também na mesma caixa.
/// - Lista em bloco: itens alterados são trocados no lugar; item a mais é uma linha nova
///   (`- valor`) depois do último, com o recuo dele; item a menos é a linha dele que sai.
/// - Lista em linha (`[a, b]`): como em TOML e JSON (`Formatar.lista`).
public enum FormatarYAML {
    public static func valor(_ v: Valor, antigo: Valor? = nil, posicao: Posicao? = nil, fonte: [UInt8] = [],
                             quebra: String = "\n") -> String {
        let r = escrever(v, antigo: antigo, posicao: posicao, fonte: fonte, quebra: quebra, fluxo: false)
        if let pos = posicao, pos.intervalo.isEmpty, !r.isEmpty { return prefixoVazio(pos.intervalo.lowerBound, fonte) + r }
        return r
    }

    /// Texto cru de um campo, ajustado ao lugar: espaço depois de `chave:` vazio e, numa
    /// lista em bloco (que começa no começo da linha), o recuo da primeira linha.
    public static func cru(_ s: String, posicao: Posicao, fonte: [UInt8]) -> String {
        let iv = posicao.intervalo
        if iv.isEmpty {
            if !s.isEmpty, !s.hasPrefix(" ") { return prefixoVazio(iv.lowerBound, fonte) + s }
            return s
        }
        if iv.lowerBound == 0 || fonte[iv.lowerBound - 1] == 0x0A, fonte[iv.lowerBound] == 0x20, !s.hasPrefix(" ") {
            let recuo = fonte[iv].prefix { $0 == 0x20 }.count
            return String(repeating: " ", count: recuo) + s
        }
        return s
    }

    /// O que vai antes de um valor escrito no lugar vazio de um valor nulo: espaço depois de
    /// `chave:`, `-` e `---`; `: ` depois de uma chave sem valor dentro de `{ }` (`{a, b}`).
    static func prefixoVazio(_ off: Int, _ fonte: [UInt8]) -> String {
        guard off > 0, off <= fonte.count else { return "" }
        switch fonte[off - 1] {
        case 0x3A, 0x2D, 0x3F: return " "
        case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5B, 0x7B: return ""
        default: return ": "
        }
    }

    /// Recuo do mapa ou da lista que contém o valor que começa em `off` (a coluna da chave
    /// em `chave: |`, a do `-` em `- |`; −1 na raiz). Usado com o indicador de recuo (`|2`).
    static func recuoDoPai(_ off: Int, _ fonte: [UInt8]) -> Int {
        var ls = off
        while ls > 0, fonte[ls - 1] != 0x0A { ls -= 1 }
        var i = ls
        if fonte[i...].starts(with: [0xEF, 0xBB, 0xBF]) { i += 3 }
        let base = i
        while i < off, fonte[i] == 0x20 { i += 1 }
        if fonte[i..<off].starts(with: Array("---".utf8)) { return -1 }
        var traco = -1
        while i < off, fonte[i] == 0x2D, i + 1 < fonte.count, fonte[i + 1] == 0x20 || fonte[i + 1] == 0x09 {
            traco = i - base
            i += 1
            while i < off, fonte[i] == 0x20 || fonte[i] == 0x09 { i += 1 }
        }
        return i == off ? traco : i - base
    }

    static func escrever(_ v: Valor, antigo: Valor?, posicao: Posicao?, fonte: [UInt8], quebra: String,
                         fluxo: Bool) -> String {
        let o: ArraySlice<UInt8> = posicao.map { fonte[$0.intervalo] } ?? []
        let estilo = String(decoding: o, as: UTF8.self)
        switch v {
        case .texto(let s):
            return texto(s, original: o, posicao: posicao, fonte: fonte, quebra: quebra, fluxo: fluxo)
        case .inteiro(let n):
            if case .inteiro? = antigo, o.first.map({ $0 == 0x2B || ($0 >= 0x30 && $0 <= 0x39) }) == true {
                return Formatar.inteiro(n, estilo: estilo)
            }
            return String(n)
        case .decimal(let d):
            let e = antigo?.tipo == .decimal ? estilo : ""
            if d.isNaN { return caixa(".nan", como: e) }
            if d.isInfinite { return (d < 0 ? "-" : (e.hasPrefix("+") ? "+" : "")) + caixa(".inf", como: e) }
            switch antigo {
            case .decimal?, .inteiro?:
                if o.first.map({ $0 == 0x2B || $0 == 0x2D || $0 == 0x2E || ($0 >= 0x30 && $0 <= 0x39) }) == true,
                   !estilo.lowercased().contains("inf"), !estilo.lowercased().contains("nan") {
                    return FormatarJSON.decimalJSON5(d, estilo: estilo)
                }
            default: break
            }
            return FormatarJSON.decimal(d, estilo: nil)
        case .booleano(let b):
            if case .booleano? = antigo { return caixa(b ? "true" : "false", como: estilo) }
            return b ? "true" : "false"
        case .nulo:
            if case .nulo? = antigo, ["~", "null", "Null", "NULL"].contains(estilo) { return estilo }
            return "null"
        case .dataHora(let dh):
            return duplas(dh.iso)                                           // recusado antes por `Formato.problema`
        case .lista(let itens):
            if case .lista(let velhos)? = antigo, let pos = posicao, pos.itens.count == velhos.count {
                let primeiro = o.first { $0 != 0x20 && $0 != 0x09 }
                if primeiro == 0x5B {
                    return Formatar.lista(itens, antigo: antigo, posicao: posicao, fonte: fonte, quebra: quebra,
                                          escrever: { v, a, p in
                                              escrever(v, antigo: a, posicao: p, fonte: fonte, quebra: quebra, fluxo: true)
                                          },
                                          temComentario: { $0.contains("#") },
                                          semComentarios: { s in
                                              s.split(separator: "\n", omittingEmptySubsequences: false)
                                                  .map { l in l.firstIndex(of: "#").map { l[..<$0] } ?? l }
                                                  .joined(separator: "\n")
                                          })
                }
                if primeiro == 0x2D, !velhos.isEmpty {
                    return listaBloco(itens, velhos: velhos, pos: pos, fonte: fonte, quebra: quebra)
                }
            }
            return "[" + itens.map { escrever($0, antigo: nil, posicao: nil, fonte: [], quebra: quebra, fluxo: true) }
                .joined(separator: ", ") + "]"
        case .tabela(let t):
            if t.pares.isEmpty { return "{}" }
            return "{" + t.pares.map { p in
                (cabeSemAspas(p.chave, fluxo: true) ? p.chave : duplas(p.chave)) + ": "
                    + escrever(p.valor, antigo: nil, posicao: nil, fonte: [], quebra: quebra, fluxo: true)
            }.joined(separator: ", ") + "}"
        }
    }

    /// `true` → `True`/`TRUE` se o original estava assim (o mesmo para `.inf`, `.nan`).
    static func caixa(_ s: String, como estilo: String) -> String {
        let letras = estilo.filter(\.isLetter)
        guard let primeira = letras.first else { return s }
        if letras.count > 1, letras.allSatisfy(\.isUppercase) { return s.uppercased() }
        if primeira.isUppercase {
            guard let i = s.firstIndex(where: \.isLetter) else { return s }
            var r = s
            r.replaceSubrange(i...i, with: String(s[i]).uppercased())
            if s.hasSuffix("nan") { r = String(r.dropLast(1)) + "N" }      // .NaN
            return r
        }
        return s
    }

    // MARK: Textos

    static func texto(_ s: String, original o: ArraySlice<UInt8>, posicao: Posicao?, fonte: [UInt8], quebra: String,
                      fluxo: Bool) -> String {
        switch o.first {
        case 0x7C?, 0x3E?:                                                   // | >
            if let pos = posicao, let r = bloco(s, pos: pos, fonte: fonte, quebra: quebra) { return r }
            return duplas(s)
        case 0x27?:
            return cabeEmAspasSimples(s) ? simples(s) : duplas(s)
        case 0x22?:
            return duplas(s)
        default:
            return cabeSemAspas(s, fluxo: fluxo) ? s : duplas(s)
        }
    }

    /// Cabe sem aspas e é relido como o mesmo texto — também por um leitor YAML 1.1?
    public static func cabeSemAspas(_ s: String, fluxo: Bool = false) -> Bool {
        let us = Array(s.unicodeScalars)
        guard let primeiro = us.first, let ultimo = us.last else { return false }
        if s.hasPrefix("---") || s.hasPrefix("...") { return false }
        if primeiro == " " || primeiro == "\t" || ultimo == " " || ultimo == "\t" { return false }
        if "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(primeiro) {
            // `-x` pode; `- x`, `?`, `:` e os outros indicadores, não
            guard primeiro == "-", us.count > 1, us[1] != " ", us[1] != "\t", !(fluxo && ",[]{}".unicodeScalars.contains(us[1]))
            else { return false }
        }
        for (i, u) in us.enumerated() {
            if !imprimivel(u) || u == "\t" { return false }
            let proximo: Unicode.Scalar? = i + 1 < us.count ? us[i + 1] : nil
            if u == ":" && (proximo == nil || proximo == " " || (fluxo && proximo.map { ",[]{}".unicodeScalars.contains($0) } == true)) {
                return false
            }
            if u == "#" && i > 0 && (us[i - 1] == " " || us[i - 1] == "\t") { return false }
            if fluxo && ",[]{}".unicodeScalars.contains(u) { return false }
        }
        if case .texto = LeitorYAML.resolver(s) {} else { return false }
        return !ambiguoEmYAML11(s)
    }

    /// Um leitor YAML 1.1 leria este texto sem aspas como outro tipo (sim/não, número,
    /// data, nulo) ou como algo especial (`<<`, `=`)? Na dúvida, sim: aspas a mais não mudam nada.
    public static func ambiguoEmYAML11(_ s: String) -> Bool {
        let l = s.lowercased()
        if ["y", "yes", "n", "no", "true", "false", "on", "off", "~", "null", "", "<<", "="].contains(l) { return true }
        if [".inf", "+.inf", "-.inf", ".nan"].contains(l) { return true }
        // números de qualquer base, com `_`, sexagesimais (`1:30`), `1e3`, `010`, `.5`, `1.2.3`
        var t = Substring(l.replacingOccurrences(of: "_", with: ""))
        if t.hasPrefix("+") || t.hasPrefix("-") { t = t.dropFirst() }
        if let p = t.first, p.isASCII, p.isNumber || (p == "." && t.dropFirst().first.map { $0.isASCII && $0.isNumber } == true) {
            if t.allSatisfy({ "0123456789.:eE+-xXoObBabcdefABCDEF".contains($0) }) { return true }
        }
        // data (timestamp do YAML 1.1): 2024-01-31, 2024-1-5 10:00…
        let u = Array(l.utf8)
        if u.count >= 8, u[0...3].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), u[4] == 0x2D {
            return true
        }
        return false
    }

    static func imprimivel(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        if v == 0x09 { return true }
        if v < 0x20 || v == 0x7F { return false }
        if v >= 0x80 && v <= 0x9F { return false }
        if v == 0x2028 || v == 0x2029 || v == 0xFEFF || v == 0xFFFE || v == 0xFFFF { return false }
        return true
    }

    static func cabeEmAspasSimples(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { imprimivel($0) && $0 != "\t" }
    }

    static func simples(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public static func duplas(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x5C: r += "\\\\"
            case 0x22: r += "\\\""
            case 0x00: r += "\\0"
            case 0x07: r += "\\a"
            case 0x08: r += "\\b"
            case 0x09: r += "\\t"
            case 0x0A: r += "\\n"
            case 0x0B: r += "\\v"
            case 0x0C: r += "\\f"
            case 0x0D: r += "\\r"
            case 0x1B: r += "\\e"
            case 0x85: r += "\\N"
            case 0x2028: r += "\\L"
            case 0x2029: r += "\\P"
            default:
                if !imprimivel(u) {
                    r += u.value <= 0xFF ? String(format: "\\x%02X", u.value) : String(format: "\\u%04X", u.value)
                } else {
                    r.unicodeScalars.append(u)
                }
            }
        }
        return r + "\""
    }

    // MARK: Blocos `|` e `>`

    /// Texto em bloco no estilo do original (`|` ou `>`, recuo, indicador de recuo e o resto
    /// da linha do cabeçalho, comentário inclusive). `nil` se o texto não cabe em bloco.
    static func bloco(_ s: String, pos: Posicao, fonte: [UInt8], quebra: String) -> String? {
        let iv = pos.intervalo
        let o = Array(fonte[iv])
        // cabeçalho: indicador, dígito, corte e o resto da linha
        var literal = o[0] == 0x7C
        var k = 1
        var digito: UInt8? = nil
        for _ in 0..<2 where k < o.count {
            if o[k] >= 0x31 && o[k] <= 0x39 { digito = o[k]; k += 1 }
            else if o[k] == 0x2B || o[k] == 0x2D { k += 1 }
        }
        var fimCab = k
        while fimCab < o.count, o[fimCab] != 0x0A, o[fimCab] != 0x0D { fimCab += 1 }
        let restoCab = String(decoding: o[k..<fimCab], as: UTF8.self)
        // recuo do conteúdo: o da primeira linha com texto; sem nenhuma, o da linha do cabeçalho + 2
        var recuo: Int? = nil
        for l in o[fimCab...].split(separator: 0x0A) {
            let e = l.prefix { $0 == 0x20 }.count
            if l.dropFirst(e).contains(where: { $0 != 0x0D }) { recuo = e; break }
        }
        if let d = digito {
            recuo = max(recuoDoPai(iv.lowerBound, fonte), 0) + Int(d - 0x30)
        }
        if recuo == nil {
            var i = iv.lowerBound
            while i > 0, fonte[i - 1] != 0x0A { i -= 1 }
            recuo = fonte[i...].prefix { $0 == 0x20 }.count + 2
        }
        let ind = String(repeating: " ", count: recuo!)

        // o texto cabe em bloco?
        if s.unicodeScalars.contains(where: { !imprimivel($0) && $0 != "\n" }) { return nil }
        var corpo = Substring(s)
        var finais = 0
        while corpo.hasSuffix("\n") { corpo = corpo.dropLast(); finais += 1 }
        if corpo.isEmpty && finais > 0 { return nil }
        let linhas = corpo.isEmpty ? [] : corpo.split(separator: "\n", omittingEmptySubsequences: false)
        let primeiraComTexto = linhas.first { !$0.isEmpty }
        if let pl = primeiraComTexto, pl.first == " " || pl.first == "\t", digito == nil { return nil }
        if recuo == 0, linhas.contains(where: { $0.hasPrefix("---") || $0.hasPrefix("...") }) { return nil }
        // linhas com espaço no começo não são dobradas: num `>` só cabem em `|`
        if !literal, linhas.contains(where: { $0.first == " " || $0.first == "\t" }) { literal = true }
        let corte = finais == 0 ? "-" : finais == 1 ? "" : "+"
        // com `+`, linhas em branco logo depois do valor seriam lidas como parte dele
        if corte == "+" || corte == "" {
            var i = iv.upperBound
            if i < fonte.count {
                i += fonte[i] == 0x0D ? 2 : 1
                var j = i
                while j < fonte.count, fonte[j] == 0x20 || fonte[j] == 0x09 { j += 1 }
                if corte == "+", j < fonte.count, fonte[j] == 0x0A || fonte[j] == 0x0D { return nil }
                if corte == "+", j >= fonte.count, i < fonte.count { return nil }
            }
        }

        var r = (literal ? "|" : ">") + (digito.map { String(UnicodeScalar($0)) } ?? "") + corte + restoCab
        var anteriorComTexto = false
        for l in linhas {
            if !literal, !l.isEmpty, anteriorComTexto { r += quebra }      // `>`: uma quebra vira linha em branco
            r += quebra + (l.isEmpty ? "" : ind + l)
            if !l.isEmpty { anteriorComTexto = true }
        }
        if corte == "+" { r += String(repeating: quebra, count: finais - 1) }
        // no fim do arquivo sem quebra, a quebra final do valor precisa ser escrita
        if iv.upperBound >= fonte.count, finais > 0 { r += quebra }
        return r
    }

    // MARK: Listas em bloco

    static func listaBloco(_ novos: [Valor], velhos: [Valor], pos: Posicao, fonte: [UInt8], quebra: String) -> String {
        let itens = pos.itens.map(\.intervalo)
        func inicioDaLinha(_ off: Int) -> Int {
            var i = off
            while i > 0, fonte[i - 1] != 0x0A { i -= 1 }
            return i
        }
        func fimDaLinha(_ off: Int) -> Int {
            var i = off
            while i < fonte.count, fonte[i] != 0x0A, fonte[i] != 0x0D { i += 1 }
            return i
        }
        func proximaLinha(_ off: Int) -> Int {
            var i = off
            while i < fonte.count, fonte[i] != 0x0A { i += 1 }
            return min(i + 1, fonte.count)
        }
        /// Posição do `-` do item `k`.
        func traco(_ k: Int) -> Int {
            var i = itens[k].lowerBound
            while i > 0, fonte[i - 1] != 0x2D { i -= 1 }
            return i - 1
        }
        func fimItem(_ k: Int) -> Int { fimDaLinha(max(itens[k].upperBound, traco(k) + 1)) }
        func escreveItem(_ v: Valor, _ k: Int?) -> String {
            guard let k else { return escrever(v, antigo: nil, posicao: nil, fonte: [], quebra: quebra, fluxo: false) }
            return valor(v, antigo: velhos[k], posicao: pos.itens[k], fonte: fonte, quebra: quebra)
        }
        let ini = pos.intervalo.lowerBound
        // todos os itens precisam começar numa linha própria (só espaços antes do `-`)
        let linhasProprias = velhos.indices.allSatisfy { k in
            let t = traco(k)
            return inicioDaLinha(t) >= ini && fonte[inicioDaLinha(t)..<t].allSatisfy { $0 == 0x20 }
        }
        if novos.isEmpty || !linhasProprias {
            // lista vazia (ou itens compactos): em linha, no recuo do primeiro item
            let recuo = String(decoding: fonte[ini..<traco(0)], as: UTF8.self)
            return recuo + "[" + novos.map { escrever($0, antigo: nil, posicao: nil, fonte: [], quebra: quebra, fluxo: true) }
                .joined(separator: ", ") + "]"
        }
        var edicoes: [(Range<Int>, String)] = []
        func tirar(_ k: Int, ficaDepois: Bool) {
            let ls = inicioDaLinha(traco(k))
            if ficaDepois {
                edicoes.append((ls..<proximaLinha(fimItem(k)), ""))
            } else {
                var q = ls - 1
                if q > 0, fonte[q - 1] == 0x0D { q -= 1 }
                edicoes.append((q..<fimItem(k), ""))
            }
        }
        if novos.count < velhos.count, let fica = FormatarINI.subsequencia(novos, de: velhos) {
            for k in velhos.indices where !fica[k] {
                tirar(k, ficaDepois: fica[(k + 1)...].contains(true))
            }
        } else {
            let n = min(novos.count, velhos.count)
            for i in 0..<n where novos[i] != velhos[i] {
                let tipoIgual = novos[i].tipo == velhos[i].tipo || velhos[i].tipo == .nulo
                edicoes.append((itens[i], escreveItem(novos[i], tipoIgual ? i : nil)))
            }
            if novos.count > velhos.count {
                // linhas novas depois da última, com o recuo e o `- ` dela; o estilo (aspas) do
                // último item do mesmo tipo, sem o bloco `|` (que tem linhas e comentário próprios)
                let u = velhos.count - 1
                let t = traco(u)
                let col = t - inicioDaLinha(t)
                var sep = String(decoding: fonte[(t + 1)..<itens[u].lowerBound], as: UTF8.self)
                if sep.isEmpty || sep.contains("\n") || sep.contains("\r") { sep = " " }
                var r = ""
                for v in novos[velhos.count...] {
                    var modelo: Int? = velhos.lastIndex { $0.tipo == v.tipo }
                    if let m = modelo, [0x7C, 0x3E].contains(fonte[itens[m]].first) { modelo = nil }
                    r += quebra + String(repeating: " ", count: col) + "-" + sep + escreveItem(v, modelo)
                        .drop { $0 == " " && sep.hasSuffix(" ") }
                }
                let fim = fimItem(u)
                edicoes.append((fim..<fim, r))
            } else {
                for k in n..<velhos.count { tirar(k, ficaDepois: false) }
            }
        }
        // aplica do fim para o começo; remoções vizinhas se juntam. Um trecho fora da lista
        // (não deveria acontecer) faz a lista inteira ser escrita em linha.
        guard edicoes.allSatisfy({ $0.0.lowerBound >= ini && $0.0.upperBound <= pos.intervalo.upperBound }) else {
            let recuo = String(decoding: fonte[ini..<traco(0)].map { _ in 0x20 }, as: UTF8.self)
            return recuo + "[" + novos.map { escrever($0, antigo: nil, posicao: nil, fonte: [], quebra: quebra, fluxo: true) }
                .joined(separator: ", ") + "]"
        }
        var r = Array(fonte[pos.intervalo])
        var feitas: [Range<Int>] = []
        for (faixa, novo) in edicoes.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            var f = faixa
            if novo.isEmpty, let ult = feitas.last, ult.lowerBound < f.upperBound {
                f = f.lowerBound..<ult.lowerBound
            }
            r.replaceSubrange((f.lowerBound - ini)..<(f.upperBound - ini), with: Array(novo.utf8))
            feitas.append(f)
        }
        return String(decoding: r, as: UTF8.self)
    }
}
