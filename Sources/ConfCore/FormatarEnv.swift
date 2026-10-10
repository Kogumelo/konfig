import Foundation

/// Escreve valores de `.env` imitando o estilo do valor antigo.
///
/// - Sem aspas continua sem aspas, se couber: vazio ou sem espaço, tabulação, `#`,
///   aspas (`"`, `'`, `` ` ``) e caracteres de controle. Se não couber, aspas duplas.
/// - Aspas simples continuam simples se o texto não tiver `'` nem CR, e quebra de
///   linha só se o original já ocupava várias linhas (escrita com a quebra do arquivo);
///   senão, aspas duplas.
/// - Aspas duplas continuam duplas. O começo e o fim iguais ao original são
///   copiados byte a byte (escapes inclusive); o miolo novo escapa só `\`, `"`,
///   quebra de linha (`\n`) e CR (`\r`).
public enum FormatarEnv {
    public static func valor(_ v: Valor, posicao: Posicao? = nil, fonte: [UInt8] = [], quebra: String = "\n") -> String {
        let s: String
        switch v {
        case .texto(let t): s = t
        case .inteiro(let n): s = String(n)
        case .decimal(let d): s = Formatar.decimal(d)
        case .booleano(let b): s = b ? "true" : "false"
        case .dataHora(let dh): s = dh.iso
        case .lista, .tabela, .nulo: s = ""   // recusados antes por `Formato.problema`
        }
        return texto(s, original: posicao.map { fonte[$0.intervalo] }, quebra: quebra)
    }

    /// Cabe sem aspas (e é relido igual)?
    public static func cabeSemAspas(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            u.value >= 0x20 && u.value != 0x7F && u != " " && u != "#" && u != "\"" && u != "'" && u != "`"
        }
    }

    public static func texto(_ s: String, original: ArraySlice<UInt8>?, quebra: String = "\n") -> String {
        switch original?.first {
        case 0x27?:   // '
            let variasLinhas = original?.contains(0x0A) ?? false
            if !s.contains("'") && !s.unicodeScalars.contains("\r")
                && (variasLinhas || !s.unicodeScalars.contains("\n")) {
                return "'" + s.replacingOccurrences(of: "\n", with: quebra) + "'"
            }
            return duplas(s, original: nil)
        case 0x22?:   // "
            return duplas(s, original: original)
        default:
            return cabeSemAspas(s) ? s : duplas(s, original: nil)
        }
    }

    /// Um caractere do texto original entre aspas duplas: o escalar e os bytes que o escreviam.
    struct Unidade {
        var escalar: Unicode.Scalar
        var bytes: ArraySlice<UInt8>
    }

    /// Decompõe um valor entre aspas duplas em unidades. `nil` se houver barra que não
    /// é escape (`\x`): copiar o começo até ela poderia formar um escape novo com o miolo.
    static func unidades(_ o: ArraySlice<UInt8>) -> [Unidade]? {
        guard o.count >= 2, o.first == 0x22, o.last == 0x22 else { return nil }
        var r: [Unidade] = []
        var i = o.startIndex + 1
        let fim = o.endIndex - 1
        while i < fim {
            let c = o[i]
            if c == 0x5C {
                guard i + 1 < fim else { return nil }
                let v: Unicode.Scalar
                switch o[i + 1] {
                case 0x6E: v = "\n"
                case 0x72: v = "\r"
                case 0x22: v = "\""
                case 0x5C: v = "\\"
                default: return nil
                }
                r.append(Unidade(escalar: v, bytes: o[i..<(i + 2)]))
                i += 2
            } else if c == 0x0D, i + 1 < fim, o[i + 1] == 0x0A {
                r.append(Unidade(escalar: "\n", bytes: o[i..<(i + 2)]))
                i += 2
            } else {
                let tam = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4
                guard i + tam <= fim, let u = String(bytes: o[i..<(i + tam)], encoding: .utf8)?.unicodeScalars.first
                else { return nil }
                r.append(Unidade(escalar: u, bytes: o[i..<(i + tam)]))
                i += tam
            }
        }
        return r
    }

    static func duplas(_ s: String, original: ArraySlice<UInt8>?) -> String {
        let novos = Array(s.unicodeScalars)
        guard let o = original, let us = unidades(o) else { return "\"" + escapa(novos[...]) + "\"" }
        var ini = 0
        while ini < us.count, ini < novos.count, us[ini].escalar == novos[ini] { ini += 1 }
        var fa = us.count, fn = novos.count
        while fa > ini, fn > ini, us[fa - 1].escalar == novos[fn - 1] { fa -= 1; fn -= 1 }
        var r = [UInt8(0x22)]
        for u in us[..<ini] { r += u.bytes }
        r += Array(escapa(novos[ini..<fn]).utf8)
        for u in us[fa...] { r += u.bytes }
        r.append(0x22)
        return String(decoding: r, as: UTF8.self)
    }

    static func escapa(_ us: ArraySlice<Unicode.Scalar>) -> String {
        var r = ""
        for u in us {
            switch u {
            case "\\": r += "\\\\"
            case "\"": r += "\\\""
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            default: r.unicodeScalars.append(u)
            }
        }
        return r
    }
}
