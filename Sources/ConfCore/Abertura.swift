import Foundation

/// Comentário de abertura do arquivo: as linhas de comentário antes da primeira linha com
/// conteúdo que não ficaram presas a nenhum campo (um bloco colado à primeira chave ou
/// seção, sem linha em branco no meio, já é a ajuda dela; em JSON nada se prende ao `{`).
///
/// O texto tem uma linha para cada linha do arquivo, da primeira à última linha de
/// comentário: sem o marcador (`#`, `;`, `//`) e um espaço depois dele, com o recuo que
/// vem a seguir; linhas em branco e comentários vazios viram linhas vazias.
public struct Abertura: Sendable, Equatable {
    public var texto: String
    /// Linhas do arquivo (começando em 0, sem contar o BOM) ocupadas pelo comentário.
    public var linhas: Range<Int>

    static func marcadores(_ f: Formato) -> [String] {
        switch f {
        case .toml, .yaml, .env: return ["#"]
        case .ini: return [";", "#"]
        case .json, .json5: return ["//"]
        }
    }

    /// Linhas cruas (com o `\r` do CRLF, se houver) e o BOM separado.
    static func separa(_ bytes: [UInt8]) -> (bom: [UInt8], linhas: [[UInt8]]) {
        let bom: [UInt8] = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? [0xEF, 0xBB, 0xBF] : []
        let linhas = bytes.dropFirst(bom.count).split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
        return (bom, linhas)
    }

    static func aparada(_ l: [UInt8]) -> String {
        String(decoding: l, as: UTF8.self).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\r")))
    }

    /// Linha do arquivo como aparece no texto do comentário (`nil` se tem conteúdo).
    static func visivel(_ l: [UInt8], _ marcadores: [String]) -> String? {
        let t = aparada(l)
        if t.isEmpty { return "" }
        guard let m = marcadores.first(where: { t.hasPrefix($0) }) else { return nil }
        var resto = t.dropFirst(m.count)
        if resto.first == " " { resto = resto.dropFirst() }
        return String(resto)
    }

    public static func ler(_ bytes: [UInt8], formato: Formato) -> Abertura? {
        let marcadores = marcadores(formato)
        let linhas = separa(bytes).linhas
        var visiveis: [String] = []
        var ultimoBloco: Int? = nil   // onde começa o bloco de comentário atual
        var colado = false
        for l in linhas {
            guard let v = visivel(l, marcadores) else {
                colado = ultimoBloco != nil && !formato.ehJSON
                break
            }
            if aparada(l).isEmpty { ultimoBloco = nil } else if ultimoBloco == nil { ultimoBloco = visiveis.count }
            visiveis.append(v)
        }
        // o bloco colado à primeira chave ou seção é a ajuda dela
        if colado, let b = ultimoBloco { visiveis.removeSubrange(b...) }
        // da primeira à última linha de comentário (as em branco nas pontas ficam de fora)
        guard let fim = visiveis.indices.last(where: { !aparada(linhas[$0]).isEmpty }),
              let ini = visiveis.indices.first(where: { !aparada(linhas[$0]).isEmpty }) else { return nil }
        return Abertura(texto: visiveis[ini...fim].joined(separator: "\n"), linhas: ini..<(fim + 1))
    }

    /// Bytes do arquivo com o comentário de abertura trocado por `novo`. Só as linhas que
    /// mudaram são reescritas (as iguais ficam byte a byte como estavam), com o
    /// marcador da primeira linha do comentário e a quebra de linha do arquivo. Texto vazio
    /// apaga o comentário e as linhas em branco depois dele. `nil` se não há comentário.
    public static func trocar(_ bytes: [UInt8], formato: Formato, por novo: String) -> [UInt8]? {
        guard let a = ler(bytes, formato: formato) else { return nil }
        var (bom, linhas) = separa(bytes)
        var novas = novo.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
        while novas.last?.isEmpty == true { novas.removeLast() }
        while novas.first?.isEmpty == true { novas.removeFirst() }
        let antigas = a.texto.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if novas == antigas { return bytes }

        if novas.isEmpty {
            var fim = a.linhas.upperBound
            while fim < linhas.count - 1, aparada(linhas[fim]).isEmpty { fim += 1 }
            linhas.removeSubrange(a.linhas.lowerBound..<fim)
            return bom + Array(linhas.joined(separator: [0x0A]))
        }

        let primeira = aparada(linhas[a.linhas.lowerBound])
        let marcador = marcadores(formato).first { primeira.hasPrefix($0) } ?? "#"
        let cr: [UInt8] = linhas[a.linhas.lowerBound].last == 0x0D ? [0x0D] : []
        // maior subsequência comum: linha igual fica como estava no arquivo (marcador, espaços,
        // linha em branco entre blocos); linha nova ganha o marcador
        let originais = Array(linhas[a.linhas])
        let n = antigas.count, m = novas.count
        var t = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i][j] = antigas[i] == novas[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var meio: [[UInt8]] = []
        var i = 0, j = 0
        while j < m {
            if i < n, antigas[i] == novas[j] {
                meio.append(originais[i]); i += 1; j += 1
            } else if i < n, t[i + 1][j] >= t[i][j + 1] {
                i += 1
            } else {
                meio.append(Array((novas[j].isEmpty ? marcador : marcador + " " + novas[j]).utf8) + cr); j += 1
            }
        }
        linhas.replaceSubrange(a.linhas, with: meio)
        return bom + Array(linhas.joined(separator: [0x0A]))
    }
}
