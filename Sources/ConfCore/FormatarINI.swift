import Foundation

/// Escreve valores INI imitando o estilo do valor antigo.
///
/// - Sem aspas continua sem aspas se o texto couber (`cabeSemAspas`); se não, aspas
///   duplas (ou simples, se o texto tiver `"`).
/// - Aspas duplas continuam duplas e simples continuam simples, a menos que o texto
///   tenha essa aspa (não há escapes): então a outra, ou nenhuma se couber.
/// - Valor antigo vazio em `chave =` (espaço antes do `=`) ganha um espaço depois do `=`.
/// - Listas `chave[] = …`: itens alterados são trocados no lugar; item a mais é uma
///   linha nova logo depois da última da lista, copiando o começo dela (`chave[] = `);
///   item a menos é a linha dele que sai.
public enum FormatarINI {
    public static func valor(_ v: Valor, antigo: Valor? = nil, posicao: Posicao? = nil, fonte: [UInt8] = [],
                             quebra: String = "\n") -> String {
        switch v {
        case .lista(let itens):
            guard case .lista(let velhos)? = antigo, let pos = posicao, pos.itens.count == velhos.count,
                  !velhos.isEmpty else {
                return itens.map { valor($0) }.joined(separator: ", ")
            }
            return lista(itens, velhos: velhos, pos: pos, fonte: fonte, quebra: quebra)
        default:
            return texto(textoDe(v), fonte: fonte, intervalo: posicao?.intervalo)
        }
    }

    static func textoDe(_ v: Valor) -> String {
        switch v {
        case .texto(let t): return t
        case .inteiro(let n): return String(n)
        case .decimal(let d): return Formatar.decimal(d)
        case .booleano(let b): return b ? "true" : "false"
        case .dataHora(let dh): return dh.iso
        case .lista, .tabela, .nulo: return ""   // recusados antes por `Formato.problema`
        }
    }

    /// Cabe sem aspas (e é relido igual, inclusive pelo PHP, que corta no `;`)?
    public static func cabeSemAspas(_ s: String) -> Bool {
        let us = Array(s.unicodeScalars)
        guard let primeiro = us.first else { return true }
        if primeiro == " " || primeiro == "\t" || us.last == " " || us.last == "\t" { return false }
        if primeiro == "\"" || primeiro == "'" || primeiro == "#" { return false }
        for (i, u) in us.enumerated() {
            if u.value < 0x20 && u != "\t" || u.value == 0x7F { return false }
            if u == ";" { return false }
            if u == "#" && i > 0 && (us[i - 1] == " " || us[i - 1] == "\t") { return false }
        }
        return true
    }

    /// Motivo pelo qual o texto não pode ser escrito em INI (sem escapes, uma linha só).
    static func problema(_ s: String) -> String? {
        if s.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }) {
            return "INI não tem valor de várias linhas nem caracteres de controle"
        }
        if !cabeSemAspas(s) && s.contains("\"") && s.contains("'") {
            return "o valor precisa de aspas (tem ';', '#', espaço nas pontas ou começa com aspas) e tem aspas duplas e simples; INI não tem escapes"
        }
        return nil
    }

    /// Texto no estilo do original em `fonte[intervalo]`.
    static func texto(_ s: String, fonte: [UInt8], intervalo: Range<Int>?) -> String {
        let original = intervalo.map { fonte[$0] } ?? []
        let duplas = "\"" + s + "\"", simples = "'" + s + "'"
        var r: String
        switch original.first {
        case 0x22?: r = !s.contains("\"") ? duplas : !s.contains("'") ? simples : s
        case 0x27?: r = !s.contains("'") ? simples : !s.contains("\"") ? duplas : s
        default: r = cabeSemAspas(s) ? s : !s.contains("\"") ? duplas : simples
        }
        guard let iv = intervalo, !r.isEmpty else { return r }
        let lb = iv.lowerBound, ub = iv.upperBound
        // `chave =` vazio: `chave = novo`, não `chave =novo`
        if original.isEmpty, lb >= 2, lb <= fonte.count, fonte[lb - 1] == 0x3D || fonte[lb - 1] == 0x3A,
           fonte[lb - 2] == 0x20 || fonte[lb - 2] == 0x09 {
            r = " " + r
        }
        // sem aspas e colado num comentário (`chave =;c`): um espaço para o comentário continuar comentário
        if r.last != "\"" && r.last != "'", ub < fonte.count, fonte[ub] == 0x3B || fonte[ub] == 0x23 {
            r += " "
        }
        return r
    }

    // MARK: Listas

    static func lista(_ novos: [Valor], velhos: [Valor], pos: Posicao, fonte: [UInt8], quebra: String) -> String {
        let itens = pos.itens.map(\.intervalo)
        func inicioDaLinha(_ off: Int) -> Int {
            var i = off
            while i > 0, fonte[i - 1] != 0x0A { i -= 1 }
            return i
        }
        func fimDoConteudo(_ off: Int) -> Int {
            var i = off
            while i < fonte.count, fonte[i] != 0x0A { i += 1 }
            if i > off, i > 0, fonte[i - 1] == 0x0D { i -= 1 }
            return i
        }
        func proximaLinha(_ off: Int) -> Int {
            var i = off
            while i < fonte.count, fonte[i] != 0x0A { i += 1 }
            return min(i + 1, fonte.count)
        }
        var edicoes: [(Range<Int>, String)] = []

        /// Tira a linha do item `k`. Se nenhum item depois dele fica, leva a quebra de
        /// antes (a lista termina sem quebra própria); senão, a de depois.
        func tirar(_ k: Int, ficaDepois: Bool) {
            let ini = inicioDaLinha(itens[k].lowerBound)
            if ficaDepois {
                edicoes.append((ini..<proximaLinha(itens[k].lowerBound), ""))
            } else {
                var q = ini - 1
                if q > 0, fonte[q - 1] == 0x0D { q -= 1 }
                edicoes.append((q..<fimDoConteudo(itens[k].lowerBound), ""))
            }
        }

        if novos.count < velhos.count, let fica = subsequencia(novos, de: velhos) {
            // itens removidos (o caso do × da etiqueta): sai só a linha de cada um
            for k in velhos.indices where !fica[k] {
                tirar(k, ficaDepois: fica[(k + 1)...].contains(true))
            }
        } else {
            let n = min(novos.count, velhos.count)
            for i in 0..<n where novos[i] != velhos[i] {
                edicoes.append((itens[i], texto(textoDe(novos[i]), fonte: fonte, intervalo: itens[i])))
            }
            if novos.count > velhos.count {
                // linhas novas logo depois da última, com o começo dela (recuo, chave, separador)
                let ultimo = itens[itens.count - 1]
                let prefixo = String(decoding: fonte[inicioDaLinha(ultimo.lowerBound)..<ultimo.lowerBound], as: UTF8.self)
                var r = ""
                for v in novos[velhos.count...] {
                    var t = texto(textoDe(v), fonte: fonte, intervalo: ultimo)
                    // o espaço antes de um comentário colado não vale aqui: a linha nova não tem comentário
                    if t.hasSuffix(" "), ultimo.upperBound < fonte.count, fonte[ultimo.upperBound] == 0x3B || fonte[ultimo.upperBound] == 0x23 {
                        t.removeLast()
                    }
                    r += quebra + prefixo + t
                }
                edicoes.append((pos.intervalo.upperBound..<pos.intervalo.upperBound, r))
            } else {
                for k in n..<velhos.count { tirar(k, ficaDepois: false) }
            }
        }

        // aplica do fim para o começo; remoções vizinhas se juntam
        var r = Array(fonte[pos.intervalo])
        let base = pos.intervalo.lowerBound
        var feitas: [Range<Int>] = []
        for (faixa, novo) in edicoes.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            var f = faixa
            if novo.isEmpty, let ult = feitas.last, ult.lowerBound < f.upperBound {
                f = f.lowerBound..<ult.lowerBound   // já removido em parte
            }
            r.replaceSubrange((f.lowerBound - base)..<(f.upperBound - base), with: Array(novo.utf8))
            feitas.append(f)
        }
        return String(decoding: r, as: UTF8.self)
    }

    /// Para cada item de `velhos`, se ele fica em `novos` (que precisa ser `velhos` sem
    /// alguns itens, na mesma ordem). `nil` se não for.
    static func subsequencia(_ novos: [Valor], de velhos: [Valor]) -> [Bool]? {
        var fica = [Bool](repeating: false, count: velhos.count)
        var j = 0
        for (k, v) in velhos.enumerated() where j < novos.count && novos[j] == v {
            fica[k] = true
            j += 1
        }
        return j == novos.count ? fica : nil
    }
}
