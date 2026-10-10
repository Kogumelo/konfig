import Foundation

/// Escreve valores JSON imitando o estilo de um valor antigo.
///
/// - Texto: os trechos iguais no começo e no fim são copiados byte a byte do
///   original (escapes inclusive); só o miolo novo é escrito, com o mesmo hábito
///   de escapes do original (`\/`, `é` para não-ASCII, caixa do hexadecimal).
/// - Número: decimal continua decimal, com expoente se havia (`1.5e3`, mesma
///   letra `e`/`E` e o `+`), e pelo menos as mesmas casas depois do ponto.
/// - JSON5 (`json5: true`): aspas simples continuam simples; inteiro hexadecimal
///   continua hexadecimal (mesma caixa e largura); `+`, `.5` e `5.` se mantêm;
///   infinito e NaN viram `Infinity` e `NaN`.
public enum FormatarJSON {
    public static func valor(_ v: Valor, antigo: Valor? = nil, posicao: Posicao? = nil, fonte: [UInt8] = [],
                             quebra: String = "\n", json5: Bool = false) -> String {
        let original: ArraySlice<UInt8>? = posicao.map { fonte[$0.intervalo] }
        let estilo = original.map { String(decoding: $0, as: UTF8.self) }
        switch v {
        case .texto(let s):
            if case .texto? = antigo { return texto(s, original: original, fonte: fonte, json5: json5) }
            return texto(s, original: nil, fonte: fonte, json5: json5)
        case .inteiro(let n):
            if json5, case .inteiro? = antigo { return inteiroJSON5(n, estilo: estilo) }
            return String(n)
        case .decimal(let d):
            let e: String?
            switch antigo { case .decimal?, .inteiro?: e = estilo; default: e = nil }
            return json5 ? decimalJSON5(d, estilo: e) : decimal(d, estilo: e)
        case .booleano(let b): return b ? "true" : "false"
        case .nulo: return "null"
        case .dataHora(let dh): return texto(dh.iso, original: nil, fonte: [])
        case .lista(let itens):
            return Formatar.lista(itens, antigo: antigo, posicao: posicao, fonte: fonte, quebra: quebra,
                                  escrever: { v, a, p in valor(v, antigo: a, posicao: p, fonte: fonte, quebra: quebra, json5: json5) },
                                  temComentario: { $0.contains("//") || $0.contains("/*") },
                                  semComentarios: semComentarios)
        case .tabela(let t):
            if t.pares.isEmpty { return "{}" }
            return "{" + t.pares.map { texto($0.chave, original: nil, fonte: []) + ": " + valor($0.valor, json5: json5) }
                .joined(separator: ", ") + "}"
        }
    }

    /// O texto sem os comentários `//` e `/* */` (usado só nos espaços entre itens).
    static func semComentarios(_ s: String) -> String {
        let u = Array(s.utf8)
        var r: [UInt8] = []
        var i = 0
        while i < u.count {
            if u[i] == 0x2F, i + 1 < u.count, u[i + 1] == 0x2F {
                while i < u.count, u[i] != 0x0A { i += 1 }
            } else if u[i] == 0x2F, i + 1 < u.count, u[i + 1] == 0x2A {
                i += 2
                while i + 1 < u.count, !(u[i] == 0x2A && u[i + 1] == 0x2F) { i += 1 }
                i += 2
            } else {
                r.append(u[i]); i += 1
            }
        }
        return String(decoding: r, as: UTF8.self)
    }

    // MARK: Textos

    struct Estilo {
        var escapaBarra = false
        var escapaNaoASCII = false
        var hexMaiusculo = true
        /// Aspas do texto: `"` ou, em JSON5, `'`.
        var aspa = "\""
    }

    /// Um caractere do texto original: o escalar e os bytes exatos que o escreviam.
    struct Unidade {
        var escalar: Unicode.Scalar
        var bytes: ArraySlice<UInt8>
    }

    /// Decompõe um texto JSON (ou JSON5) válido, com as aspas, em unidades. Em JSON5,
    /// a continuação de linha (`\` + quebra) não é caractere: fica grudada na unidade seguinte
    /// (ou na anterior, no fim do texto), para ser copiada junto quando ela não muda.
    static func unidades(_ o: ArraySlice<UInt8>) -> [Unidade]? {
        guard o.count >= 2, o.first == 0x22 || o.first == 0x27, o.last == o.first else { return nil }
        var r: [Unidade] = []
        var i = o.startIndex + 1
        let fim = o.endIndex - 1
        /// Início de uma continuação de linha ainda sem unidade.
        var continuacao: Int? = nil
        func poe(_ u: Unicode.Scalar, _ tam: Int) {
            r.append(Unidade(escalar: u, bytes: o[(continuacao ?? i)..<(i + tam)]))
            continuacao = nil
        }
        func hex(_ k: Int) -> UInt32? {
            guard k + 4 <= fim else { return nil }
            return UInt32(String(decoding: o[k..<(k + 4)], as: UTF8.self), radix: 16)
        }
        while i < fim {
            let c = o[i]
            if c == 0x5C {
                guard i + 1 < fim else { return nil }
                let e = o[i + 1]
                var v: UInt32
                var tam = 2
                // continuação de linha (JSON5): `\` + LF, CR, CRLF, U+2028 ou U+2029
                var cont = 0
                if e == 0x0A { cont = 2 } else if e == 0x0D { cont = i + 2 < fim && o[i + 2] == 0x0A ? 3 : 2 }
                else if e == 0xE2, i + 3 < fim, o[i + 2] == 0x80, o[i + 3] == 0xA8 || o[i + 3] == 0xA9 { cont = 4 }
                if cont > 0 {
                    if continuacao == nil { continuacao = i }
                    i += cont
                    continue
                }
                switch e {
                case 0x22: v = 0x22
                case 0x27: v = 0x27
                case 0x76: v = 0x0B
                case 0x30: v = 0
                case 0x78:
                    guard i + 4 <= fim, let x = UInt32(String(decoding: o[(i + 2)..<(i + 4)], as: UTF8.self), radix: 16)
                    else { return nil }
                    v = x; tam = 4
                case 0x5C: v = 0x5C
                case 0x2F: v = 0x2F
                case 0x62: v = 0x08
                case 0x66: v = 0x0C
                case 0x6E: v = 0x0A
                case 0x72: v = 0x0D
                case 0x74: v = 0x09
                case 0x75:
                    guard let a = hex(i + 2) else { return nil }
                    v = a; tam = 6
                    if a >= 0xD800 && a <= 0xDBFF {
                        guard i + 12 <= fim, o[i + 6] == 0x5C, o[i + 7] == 0x75, let bx = hex(i + 8) else { return nil }
                        v = 0x10000 + ((a - 0xD800) << 10) + (bx - 0xDC00); tam = 12
                    }
                default:
                    // JSON5: qualquer outro caractere escapado vale ele mesmo (`\a` é `a`)
                    let t = e < 0x80 ? 1 : e < 0xE0 ? 2 : e < 0xF0 ? 3 : 4
                    guard i + 1 + t <= fim, let s = String(bytes: o[(i + 1)..<(i + 1 + t)], encoding: .utf8)?
                        .unicodeScalars.first else { return nil }
                    v = s.value; tam = 1 + t
                }
                guard let u = Unicode.Scalar(v) else { return nil }
                poe(u, tam)
                i += tam
            } else {
                let tam = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4
                guard i + tam <= fim, let s = String(bytes: o[i..<(i + tam)], encoding: .utf8)?.unicodeScalars.first
                else { return nil }
                poe(s, tam)
                i += tam
            }
        }
        if continuacao != nil, let u = r.last {
            // continuação logo antes da aspa de fechamento: fica com a última unidade
            r[r.count - 1].bytes = o[u.bytes.startIndex..<fim]
        }
        return r
    }

    static func estilo(_ us: [Unidade], fonte: [UInt8]) -> Estilo {
        var e = Estilo()
        var viuNaoASCII = false, viuMaiusculo = false, viuMinusculo = false
        for u in us {
            if u.bytes.first == 0x5C {
                if u.bytes.count == 2, u.bytes.last == 0x2F { e.escapaBarra = true }
                if u.bytes.count >= 6, u.bytes[u.bytes.startIndex + 1] == 0x75 {
                    for h in u.bytes where (0x41...0x46).contains(h) { viuMaiusculo = true }
                    for h in u.bytes where (0x61...0x66).contains(h) { viuMinusculo = true }
                    if u.escalar.value >= 0x80 { e.escapaNaoASCII = true }
                }
            } else if u.escalar.value >= 0x80 {
                viuNaoASCII = true
            }
        }
        if viuNaoASCII { e.escapaNaoASCII = false }
        if viuMinusculo && !viuMaiusculo { e.hexMaiusculo = false }
        if !viuNaoASCII && !e.escapaNaoASCII {
            // o texto não diz nada: vale o hábito do arquivo (só ASCII e com \u de não-ASCII)
            let corpo = fonte.starts(with: [0xEF, 0xBB, 0xBF]) ? fonte.dropFirst(3) : fonte[...]
            if !corpo.contains(where: { $0 >= 0x80 }), usaEscapeNaoASCII(corpo) { e.escapaNaoASCII = true }
        }
        return e
    }

    static func usaEscapeNaoASCII(_ f: ArraySlice<UInt8>) -> Bool {
        var i = f.startIndex
        while i + 5 < f.endIndex {
            if f[i] == 0x5C, f[i + 1] == 0x75 {
                let h = String(decoding: f[(i + 2)..<(i + 6)], as: UTF8.self)
                if let v = UInt32(h, radix: 16), v >= 0x80 { return true }
                i += 6
            } else if f[i] == 0x5C {
                i += 2
            } else {
                i += 1
            }
        }
        return false
    }

    /// Texto entre aspas. Com o original, copia dele o começo e o fim que não mudaram.
    /// Em JSON5, aspas simples continuam simples.
    public static func texto(_ s: String, original: ArraySlice<UInt8>?, fonte: [UInt8] = [],
                             json5: Bool = false) -> String {
        let novos = Array(s.unicodeScalars)
        guard let o = original, let us = unidades(o) else { return "\"" + escapa(novos[...], Estilo()) + "\"" }
        var e = estilo(us, fonte: fonte)
        let aspa = json5 && o.first == 0x27 ? "'" : "\""
        e.aspa = aspa
        var ini = 0
        while ini < us.count, ini < novos.count, us[ini].escalar == novos[ini] { ini += 1 }
        var fa = us.count, fn = novos.count
        while fa > ini, fn > ini, us[fa - 1].escalar == novos[fn - 1] { fa -= 1; fn -= 1 }
        var r = aspa
        for u in us[..<ini] { r += String(decoding: u.bytes, as: UTF8.self) }
        r += escapa(novos[ini..<fn], e)
        for u in us[fa...] { r += String(decoding: u.bytes, as: UTF8.self) }
        return r + aspa
    }

    static func escapa(_ us: ArraySlice<Unicode.Scalar>, _ e: Estilo) -> String {
        func u4(_ v: UInt32) -> String {
            let h = String(v, radix: 16, uppercase: e.hexMaiusculo)
            return "\\u" + String(repeating: "0", count: max(0, 4 - h.count)) + h
        }
        var r = ""
        for u in us {
            switch u {
            case "\"": r += e.aspa == "\"" ? "\\\"" : "\""
            case "'": r += e.aspa == "'" ? "\\'" : "'"
            case "\\": r += "\\\\"
            case "/": r += e.escapaBarra ? "\\/" : "/"
            case "\u{08}": r += "\\b"
            case "\u{0C}": r += "\\f"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default:
                if u.value < 0x20 {
                    r += u4(u.value)
                } else if u.value >= 0x80 && e.escapaNaoASCII {
                    if u.value > 0xFFFF {
                        let v = u.value - 0x10000
                        r += u4(0xD800 + (v >> 10)) + u4(0xDC00 + (v & 0x3FF))
                    } else {
                        r += u4(u.value)
                    }
                } else {
                    r.unicodeScalars.append(u)
                }
            }
        }
        return r
    }

    // MARK: Números

    /// Inteiro JSON5 na forma do original: hexadecimal (`0x`/`0X`, caixa dos dígitos e
    /// largura) ou decimal, com o `+` se havia.
    public static func inteiroJSON5(_ n: Int64, estilo a: String?) -> String {
        var a = Substring(a ?? "")
        let mais = a.hasPrefix("+")
        if a.hasPrefix("+") || a.hasPrefix("-") { a = a.dropFirst() }
        let sinal = n < 0 ? "-" : (mais ? "+" : "")
        guard a.hasPrefix("0x") || a.hasPrefix("0X") else { return sinal + String(n.magnitude) }
        let digitos = a.dropFirst(2)
        let maiusculo = digitos.contains { "ABCDEF".contains($0) } || !digitos.contains { "abcdef".contains($0) }
            && a.hasPrefix("0X")
        var h = String(n.magnitude, radix: 16, uppercase: maiusculo)
        if h.count < digitos.count { h = String(repeating: "0", count: digitos.count - h.count) + h }
        return sinal + a.prefix(2) + h
    }

    /// Decimal JSON5 na forma do original: `Infinity`/`NaN`, `+` se havia, `.5` sem o zero
    /// e `5.` sem casas, quando o valor novo cabe nessa forma.
    public static func decimalJSON5(_ d: Double, estilo a: String?) -> String {
        var a = Substring(a ?? "")
        let mais = a.hasPrefix("+")
        if a.hasPrefix("+") || a.hasPrefix("-") { a = a.dropFirst() }
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : (mais ? "+Infinity" : "Infinity") }
        let ehNumero = a.first.map { $0.isNumber || $0 == "." } ?? false
        let posE = a.firstIndex { $0 == "e" || $0 == "E" }
        let mantissa = posE.map { a[..<$0] } ?? a
        let pontoNoInicio = ehNumero && mantissa.hasPrefix(".")
        let pontoNoFim = ehNumero && mantissa.hasSuffix(".")
        // estilo normalizado para o JSON: `.5` → `0.5`, `5.` → `5.0`, hexadecimal ignorado
        var normal: String? = nil
        if ehNumero && !a.hasPrefix("0x") && !a.hasPrefix("0X") {
            normal = (pontoNoInicio ? "0" : "") + mantissa + (pontoNoFim ? "0" : "") + (posE.map { String(a[$0...]) } ?? "")
        }
        var r = decimal(d, estilo: normal)
        let neg = r.hasPrefix("-")
        if neg { r.removeFirst() }
        let e = r.firstIndex { $0 == "e" || $0 == "E" }
        var m = String(e.map { r[..<$0] } ?? r[...])
        let resto = e.map { String(r[$0...]) } ?? ""
        if pontoNoInicio, m.hasPrefix("0.") { m.removeFirst() }
        if pontoNoFim, let p = m.firstIndex(of: "."), m[m.index(after: p)...].allSatisfy({ $0 == "0" }) {
            m = String(m[...p])
        }
        return (neg ? "-" : (mais ? "+" : "")) + m + resto
    }

    /// Decimal na forma do original: com ou sem expoente, mesmas casas depois do ponto (no mínimo).
    /// Sempre com ponto ou expoente, para continuar sendo lido como decimal.
    public static func decimal(_ d: Double, estilo a: String?) -> String {
        guard d.isFinite else { return Formatar.decimal(d) }
        let a = a ?? ""
        let posE = a.firstIndex { $0 == "e" || $0 == "E" }
        let letraE: String = posE.map { String(a[$0]) } ?? "e"
        let mantissa = posE.map { a[..<$0] } ?? a[...]
        let casas = mantissa.firstIndex(of: ".").map { mantissa.distance(from: $0, to: mantissa.endIndex) - 1 } ?? 0
        let maisNoExpoente = posE.map { a[a.index(after: $0)...].hasPrefix("+") } ?? false

        // dígitos significativos (D) e expoente (E): |d| = D × 10^E
        let (digitos, expoente) = decompor(d.magnitude)
        let sinal = d.sign == .minus ? "-" : ""
        let usarExpoente = posE != nil || expoente + digitos.count > 21 || expoente + digitos.count < -6

        if usarExpoente {
            let e10 = expoente + digitos.count - 1
            var frac = String(digitos.dropFirst())
            let minimo = posE != nil ? casas : 0
            if frac.count < minimo { frac += String(repeating: "0", count: minimo - frac.count) }
            let m = String(digitos.prefix(1)) + (frac.isEmpty ? "" : "." + frac)
            let se = e10 < 0 ? "-" : (maisNoExpoente ? "+" : "")
            return sinal + m + letraE + se + String(abs(e10))
        }
        var inteira: String, frac: String
        if expoente >= 0 {
            inteira = digitos + String(repeating: "0", count: expoente)
            frac = ""
        } else if digitos.count > -expoente {
            inteira = String(digitos.dropLast(-expoente))
            frac = String(digitos.suffix(-expoente))
        } else {
            inteira = "0"
            frac = String(repeating: "0", count: -expoente - digitos.count) + digitos
        }
        let minimo = max(1, casas)
        if frac.count < minimo { frac += String(repeating: "0", count: minimo - frac.count) }
        return sinal + inteira + "." + frac
    }

    /// Menor sequência de dígitos que representa `d` (≥ 0), com o expoente decimal.
    static func decompor(_ d: Double) -> (String, Int) {
        if d == 0 { return ("0", 0) }
        let s = "\(d)"   // forma mais curta que relê o mesmo Double: "1.5", "1e-05", "1.2345e+20"
        var mant = Substring(s), exp = 0
        if let i = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mant = s[..<i]
            exp = Int(s[s.index(after: i)...]) ?? 0
        }
        var dig = mant.replacingOccurrences(of: ".", with: "")
        if let ponto = mant.firstIndex(of: ".") {
            exp -= mant.distance(from: ponto, to: mant.endIndex) - 1
        }
        while dig.count > 1, dig.hasPrefix("0") { dig.removeFirst() }
        while dig.count > 1, dig.hasSuffix("0") { dig.removeLast(); exp += 1 }
        return (dig, exp)
    }
}
