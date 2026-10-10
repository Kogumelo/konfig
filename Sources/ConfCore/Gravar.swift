import Foundation

/// O que gravar no lugar de um valor.
public enum NovoValor: Hashable, Sendable {
    /// Valor novo, escrito no estilo do valor antigo.
    case valor(Valor)
    /// Texto TOML cru do valor (por exemplo `[1, "a"]`), gravado como está depois de validado.
    case cru(String)
}

public struct ErroGravar: Error, Sendable, LocalizedError, CustomStringConvertible {
    public var mensagem: String
    public init(_ m: String) { mensagem = m }
    public var description: String { mensagem }
    public var errorDescription: String? { mensagem }
}

/// Troca no texto original só os trechos dos valores alterados.
public enum Gravar {
    /// Devolve o texto novo. Sem alterações efetivas, devolve exatamente os mesmos bytes.
    ///
    /// Antes de devolver, relê o resultado com o `Leitor` e confere se os valores
    /// são os esperados; se não forem, lança erro e nada deve ser gravado.
    public static func aplicar(_ original: [UInt8], alteracoes: [Caminho: NovoValor]) throws -> [UInt8] {
        if alteracoes.isEmpty { return original }
        let doc: DocumentoTOML
        do { doc = try Leitor.ler(original) } catch {
            throw ErroGravar("o arquivo atual não é TOML válido (\(error)); edite pelo modo Texto")
        }
        return try aplicar(doc, alteracoes: alteracoes)
    }

    public static func aplicar(_ doc: DocumentoTOML, alteracoes: [Caminho: NovoValor]) throws -> [UInt8] {
        var trocas: [(Range<Int>, [UInt8])] = []
        var esperado = doc.raiz
        for (caminho, novo) in alteracoes {
            guard let e = doc.entrada(caminho) else {
                throw ErroGravar("a chave '\(caminho.texto)' não existe mais no arquivo")
            }
            let textoAntigo = Array(doc.bytes[e.intervalo])
            let valorNovo: Valor
            let textoNovo: [UInt8]
            switch novo {
            case .cru(let s):
                do { valorNovo = try Leitor.lerValor(s) } catch {
                    throw ErroGravar("valor de '\(caminho.texto)' não é TOML válido: \(error)")
                }
                textoNovo = Array(s.utf8)
                if textoNovo == textoAntigo { continue }
            case .valor(let v):
                if v == e.valor { continue }
                valorNovo = v
                textoNovo = Array(Formatar.valor(v, antigo: e.valor, posicao: e.posicao, fonte: doc.bytes,
                                                 quebra: doc.quebraDeLinha).utf8)
            }
            trocas.append((e.intervalo, textoNovo))
            guard let t = esperado.substituindo(caminho, por: valorNovo) else {
                throw ErroGravar("não foi possível localizar '\(caminho.texto)'")
            }
            esperado = t
        }
        if trocas.isEmpty { return doc.bytes }
        var r = doc.bytes
        for (intervalo, novo) in trocas.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            r.replaceSubrange(intervalo, with: novo)
        }
        let relido: DocumentoTOML
        do { relido = try Leitor.ler(r) } catch {
            throw ErroGravar("o resultado não seria TOML válido (\(error)); nada foi gravado")
        }
        guard relido.raiz == esperado else {
            throw ErroGravar("o resultado relido não confere com os valores pedidos; nada foi gravado")
        }
        return r
    }
}

/// Escreve valores TOML imitando o estilo de um valor antigo.
public enum Formatar {
    public static func valor(_ v: Valor, antigo: Valor? = nil, posicao: Posicao? = nil, fonte: [UInt8] = [],
                             quebra: String = "\n") -> String {
        let a: String? = posicao.map { String(decoding: fonte[$0.intervalo], as: UTF8.self) }
        switch v {
        case .texto(let s): return texto(s, estilo: a, quebra: quebra)
        case .inteiro(let n): return inteiro(n, estilo: a)
        case .decimal(let d): return decimal(d)
        case .booleano(let b): return b ? "true" : "false"
        case .dataHora(let dh): return dataHora(dh, estilo: a)
        case .lista(let itens): return lista(itens, antigo: antigo, posicao: posicao, fonte: fonte, quebra: quebra)
        case .tabela(let t): return tabelaEmbutida(t)
        }
    }

    // MARK: Textos

    public static func textoBasico(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": r += "\\\\"
            case "\"": r += "\\\""
            case "\u{08}": r += "\\b"
            case "\t": r += "\\t"
            case "\n": r += "\\n"
            case "\u{0C}": r += "\\f"
            case "\r": r += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F { r += String(format: "\\u%04X", u.value) }
                else { r.unicodeScalars.append(u) }
            }
        }
        return r + "\""
    }

    static func temControle(_ s: String, permitindoQuebra: Bool) -> Bool {
        s.unicodeScalars.contains { u in
            if u == "\t" { return false }
            if u == "\n" && permitindoQuebra { return false }
            return u.value < 0x20 || u.value == 0x7F
        }
    }

    /// Texto no mesmo tipo de aspas do original; se não couber, passa para aspas normais.
    public static func texto(_ s: String, estilo a: String?, quebra: String = "\n") -> String {
        let a = a ?? ""
        let quebraInicial = a.dropFirst(3).hasPrefix("\n") || a.dropFirst(3).hasPrefix("\r\n") || s.hasPrefix("\n")
        if a.hasPrefix("'''") {
            if !s.contains("'''") && !s.hasSuffix("'") && !temControle(s, permitindoQuebra: true) {
                return "'''" + (quebraInicial ? quebra : "") + s.replacingOccurrences(of: "\n", with: quebra) + "'''"
            }
            return textoMultiBasico(s, quebraInicial: quebraInicial, quebra: quebra)
        }
        if a.hasPrefix("\"\"\"") {
            return textoMultiBasico(s, quebraInicial: quebraInicial, quebra: quebra)
        }
        if a.hasPrefix("'") && !s.contains("'") && !temControle(s, permitindoQuebra: false) {
            return "'" + s + "'"
        }
        return textoBasico(s)
    }

    static func textoMultiBasico(_ s: String, quebraInicial: Bool, quebra: String) -> String {
        var r = "\"\"\"" + (quebraInicial ? quebra : "")
        let us = Array(s.unicodeScalars)
        for (i, u) in us.enumerated() {
            switch u {
            case "\\": r += "\\\\"
            case "\"":
                // nunca deixa duas aspas seguidas sem escape, nem aspas antes do fechamento
                let proxima = i + 1 < us.count ? us[i + 1] : nil
                r += (proxima == "\"" || proxima == nil) ? "\\\"" : "\""
            case "\n": r += quebra
            case "\t": r += "\t"
            case "\r": r += "\\r"
            case "\u{08}": r += "\\b"
            case "\u{0C}": r += "\\f"
            default:
                if u.value < 0x20 || u.value == 0x7F { r += String(format: "\\u%04X", u.value) }
                else { r.unicodeScalars.append(u) }
            }
        }
        return r + "\"\"\""
    }

    // MARK: Números

    /// Inteiro na mesma base, com o mesmo agrupamento por `_` e a mesma largura (hex/octal/binário).
    public static func inteiro(_ n: Int64, estilo a: String?) -> String {
        let a = a ?? ""
        var base = 10, prefixo = "", maiusculas = false
        if a.hasPrefix("0x") { base = 16; prefixo = "0x"; maiusculas = a.dropFirst(2).contains { "ABCDEF".contains($0) } }
        else if a.hasPrefix("0o") { base = 8; prefixo = "0o" }
        else if a.hasPrefix("0b") { base = 2; prefixo = "0b" }
        if n < 0 && base != 10 { base = 10; prefixo = "" }
        var dig = String(n.magnitude, radix: base, uppercase: maiusculas)
        if base != 10 {
            let largura = a.dropFirst(2).filter { $0 != "_" }.count
            if dig.count < largura { dig = String(repeating: "0", count: largura - dig.count) + dig }
        }
        if let ult = a.lastIndex(of: "_") {
            let grupo = a.distance(from: a.index(after: ult), to: a.endIndex)
            if grupo > 0 {
                var partes: [Substring] = []
                var fim = dig.endIndex
                while fim > dig.startIndex {
                    let ini = dig.index(fim, offsetBy: -grupo, limitedBy: dig.startIndex) ?? dig.startIndex
                    partes.insert(dig[ini..<fim], at: 0)
                    fim = ini
                }
                dig = partes.joined(separator: "_")
            }
        }
        let sinal = n < 0 ? "-" : (a.hasPrefix("+") && base == 10 ? "+" : "")
        return sinal + prefixo + dig
    }

    public static func decimal(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        var s = "\(d)"
        if !s.contains(".") && !s.contains("e") { s += ".0" }
        return s
    }

    public static func dataHora(_ dh: DataHora, estilo a: String?) -> String {
        var sep: Character = "T"
        if let a, a.count > 10 {
            let c = a[a.index(a.startIndex, offsetBy: 10)]
            if c == " " || c == "t" { sep = c }
        }
        return dh.texto(separador: sep, zMinusculo: a?.hasSuffix("z") ?? false)
    }

    // MARK: Listas e tabelas

    public static func tabelaEmbutida(_ t: Tabela) -> String {
        if t.pares.isEmpty { return "{}" }
        return "{ " + t.pares.map { Segmento.chaveFormatada($0.chave) + " = " + valor($0.valor) }.joined(separator: ", ") + " }"
    }

    static func lista(_ itens: [Valor], antigo: Valor?, posicao: Posicao?, fonte: [UInt8], quebra: String) -> String {
        guard case .lista(let velhos)? = antigo, let pos = posicao, pos.itens.count == velhos.count,
              pos.intervalo.count >= 2 else {
            return "[" + itens.map { valor($0) }.joined(separator: ", ") + "]"
        }
        func txt(_ r: Range<Int>) -> String { String(decoding: fonte[r], as: UTF8.self) }
        // "\r\n" é um caractere só em Swift: procurar a quebra pelos bytes
        func temQuebra(_ s: String) -> Bool { s.utf8.contains(0x0A) }

        // Mesmo número de itens: troca só os itens que mudaram, preservando todo o resto.
        if itens.count == velhos.count {
            var r = ""
            var cursor = pos.intervalo.lowerBound
            for i in itens.indices where itens[i] != velhos[i] {
                let ip = pos.itens[i]
                r += txt(cursor..<ip.intervalo.lowerBound)
                r += valor(itens[i], antigo: velhos[i], posicao: ip, fonte: fonte, quebra: quebra)
                cursor = ip.intervalo.upperBound
            }
            return r + txt(cursor..<pos.intervalo.upperBound)
        }

        // Cada item novo copia o estilo do item antigo na mesma posição, ou do primeiro do mesmo tipo.
        let escritos: [String] = itens.enumerated().map { i, v in
            if i < velhos.count, velhos[i].tipo == v.tipo {
                return valor(v, antigo: velhos[i], posicao: pos.itens[i], fonte: fonte, quebra: quebra)
            }
            if let j = velhos.firstIndex(where: { $0.tipo == v.tipo }), v.tipo != .lista {
                return valor(v, antigo: velhos[j], posicao: pos.itens[j], fonte: fonte, quebra: quebra)
            }
            return valor(v, quebra: quebra)
        }

        let ini = pos.intervalo.lowerBound, fim = pos.intervalo.upperBound
        guard let primeiro = pos.itens.first, let ultimo = pos.itens.last else {
            // lista antiga vazia: mantém o que havia entre os colchetes se for só espaço
            let dentro = txt((ini + 1)..<(fim - 1))
            if escritos.isEmpty { return txt(pos.intervalo) }
            let pad = dentro.allSatisfy { $0 == " " } && !dentro.isEmpty ? " " : ""
            return "[" + pad + escritos.joined(separator: ", ") + pad + "]"
        }
        if escritos.isEmpty { return "[]" }

        let antes = txt((ini + 1)..<primeiro.intervalo.lowerBound)
        let depois = txt(ultimo.intervalo.upperBound..<(fim - 1))
        let virgulaFinal = depois.contains(",")
        var entre: [String] = []
        for k in 1..<pos.itens.count {
            entre.append(txt(pos.itens[k - 1].intervalo.upperBound..<pos.itens[k].intervalo.lowerBound))
        }
        let variasLinhas = ([antes, depois] + entre).contains(where: temQuebra)

        if !variasLinhas {
            let abre = antes.allSatisfy { $0 == " " || $0 == "\t" } ? antes : ""
            var sep = ", "
            if let e = entre.first, !e.contains("#"), !temQuebra(e) { sep = e }
            var fecha = depois
            if let v = fecha.lastIndex(of: ",") { fecha = String(fecha[fecha.index(after: v)...]) }
            if !fecha.allSatisfy({ $0 == " " || $0 == "\t" }) { fecha = "" }
            return "[" + abre + escritos.joined(separator: sep) + (virgulaFinal ? "," : "") + fecha + "]"
        }

        // Várias linhas: recuo do primeiro item, vírgula final se havia, `]` onde estava.
        func recuoDaLinha(_ off: Int) -> String? {
            var i = off
            while i > 0, fonte[i - 1] == 0x20 || fonte[i - 1] == 0x09 { i -= 1 }
            guard i == 0 || fonte[i - 1] == 0x0A else { return nil }
            return txt(i..<off)
        }
        let primeiraNaLinhaDoColchete = !temQuebra(antes)
        var recuo = "    "
        if !primeiraNaLinhaDoColchete, let r = recuoDaLinha(primeiro.intervalo.lowerBound) {
            recuo = r
        } else if pos.itens.count > 1, let r = recuoDaLinha(pos.itens[1].intervalo.lowerBound) {
            recuo = r
        }
        var r = "["
        if primeiraNaLinhaDoColchete {
            r += antes.allSatisfy({ $0 == " " || $0 == "\t" }) ? antes : ""
        } else {
            r += quebra + recuo
        }
        r += escritos[0]
        for e in escritos.dropFirst() { r += "," + quebra + recuo + e }
        if virgulaFinal { r += "," }
        if temQuebra(depois) {
            let fechaRecuo = String(decoding: depois.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).last ?? [], as: UTF8.self)
            r += quebra + (fechaRecuo.allSatisfy { $0 == " " || $0 == "\t" } ? fechaRecuo : "")
        }
        return r + "]"
    }
}
