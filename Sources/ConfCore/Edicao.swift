import Foundation

/// Estado de um arquivo aberto: bytes do disco, texto-base e alterações pendentes.
///
/// O texto-base começa igual ao disco e só muda quando o modo Texto aplica um
/// texto novo. As alterações do formulário ficam em `alteracoes` e só viram
/// bytes em `resultado()`, que troca apenas os trechos dos valores alterados.
public struct EdicaoTOML: Sendable {
    public private(set) var disco: [UInt8]
    public private(set) var base: [UInt8]
    public private(set) var alteracoes: [Caminho: NovoValor] = [:]
    /// Leitura do texto-base (`nil` se ele não for TOML válido).
    public private(set) var documento: DocumentoTOML?
    public private(set) var erro: ErroTOML?

    public init(_ bytes: [UInt8]) {
        disco = bytes
        base = bytes
        relerBase()
    }

    private mutating func relerBase() {
        do { documento = try Leitor.ler(base); erro = nil } catch { documento = nil; erro = error }
    }

    /// Instantâneo para desfazer operações grandes (aplicar o modo Texto).
    public struct Instantaneo: Sendable {
        var base: [UInt8]
        var alteracoes: [Caminho: NovoValor]
    }

    public var instantaneo: Instantaneo { Instantaneo(base: base, alteracoes: alteracoes) }

    public mutating func restaurar(_ i: Instantaneo) {
        let mudouBase = i.base != base
        base = i.base
        alteracoes = i.alteracoes
        if mudouBase { relerBase() }
    }

    /// Valor efetivo (alterado ou original) de uma entrada.
    public func valor(_ c: Caminho) -> Valor? {
        switch alteracoes[c] {
        case .valor(let v)?: return v
        case .cru(let s)?: return try? Leitor.lerValor(s)
        case nil: return documento?.entrada(c)?.valor
        }
    }

    /// Valor efetivo na forma de `NovoValor`, para guardar no desfazer.
    public func efetivo(_ c: Caminho) -> NovoValor? {
        if let a = alteracoes[c] { return a }
        return documento?.entrada(c).map { .valor($0.valor) }
    }

    public func alterado(_ c: Caminho) -> Bool { alteracoes[c] != nil }

    /// Define o valor de uma entrada. Igual ao do texto-base, a alteração some.
    public mutating func definir(_ c: Caminho, _ novo: NovoValor) throws {
        guard let doc = documento, let e = doc.entrada(c) else {
            throw ErroGravar("a chave '\(c.texto)' não existe no arquivo")
        }
        switch novo {
        case .valor(let v):
            if v == e.valor { alteracoes[c] = nil } else { alteracoes[c] = novo }
        case .cru(let s):
            do { _ = try Leitor.lerValor(s) } catch {
                throw ErroGravar("valor inválido: \(error)")
            }
            if Array(s.utf8) == Array(doc.bytes[e.intervalo]) { alteracoes[c] = nil } else { alteracoes[c] = novo }
        }
    }

    /// Bytes a gravar. Sem alterações, é exatamente o texto-base.
    public func resultado() throws -> [UInt8] {
        guard !alteracoes.isEmpty else { return base }
        guard let doc = documento else { throw ErroGravar("o arquivo não é TOML válido") }
        return try Gravar.aplicar(doc, alteracoes: alteracoes)
    }

    /// Há algo diferente do disco?
    public var temAlteracoes: Bool {
        guard let r = try? resultado() else { return true }
        return r != disco
    }

    /// Troca o texto inteiro (modo Texto). Só aceita TOML válido.
    public mutating func trocarTexto(_ novo: [UInt8]) throws(ErroTOML) {
        _ = try Leitor.ler(novo)
        base = novo
        alteracoes = [:]
        relerBase()
    }

    /// Depois de gravar: o disco passa a ser o que foi gravado. Se algo mudou durante
    /// a gravação (salvamento automático em segundo plano), essas alterações continuam pendentes.
    public mutating func gravado(_ bytes: [UInt8]) {
        disco = bytes
        guard (try? resultado()) == bytes else { return }
        if bytes != base {
            base = bytes
            relerBase()
        }
        alteracoes = [:]
    }
}

// MARK: - Diferença por linhas

/// Um trecho alterado entre dois textos.
public struct Trecho: Sendable, Identifiable, Hashable {
    public var id: Int { linhaDepois * 100_000 + linhaAntes }
    /// Primeira linha (começando em 1) do trecho no texto antigo e no novo.
    public var linhaAntes: Int
    public var linhaDepois: Int
    public var removidas: [String]
    public var adicionadas: [String]
}

public enum Diferenca {
    static func separa(_ b: [UInt8]) -> [String] {
        if b.isEmpty { return [] }
        var linhas = b.split(separator: 0x0A, omittingEmptySubsequences: false).map { l -> String in
            var l = l
            if l.last == 0x0D { l = l.dropLast() }
            return String(decoding: l, as: UTF8.self)
        }
        if b.last == 0x0A { linhas.removeLast() }
        return linhas
    }

    /// Trechos diferentes entre `antes` e `depois`, linha a linha.
    public static func linhas(_ antes: [UInt8], _ depois: [UInt8]) -> [Trecho] {
        if antes == depois { return [] }
        let a = separa(antes), d = separa(depois)
        var ini = 0
        while ini < a.count, ini < d.count, a[ini] == d[ini] { ini += 1 }
        var fa = a.count, fd = d.count
        while fa > ini, fd > ini, a[fa - 1] == d[fd - 1] { fa -= 1; fd -= 1 }
        let ma = Array(a[ini..<fa]), md = Array(d[ini..<fd])
        if ma.isEmpty && md.isEmpty {
            // só a quebra de linha mudou (CRLF × LF, BOM): mostra a primeira linha
            return [Trecho(linhaAntes: 1, linhaDepois: 1, removidas: Array(a.prefix(1)), adicionadas: Array(d.prefix(1)))]
        }
        guard ma.count * md.count <= 4_000_000 else {
            return [Trecho(linhaAntes: ini + 1, linhaDepois: ini + 1, removidas: ma, adicionadas: md)]
        }
        // maior subsequência comum
        let n = ma.count, m = md.count
        var t = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i][j] = ma[i] == md[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var r: [Trecho] = []
        var i = 0, j = 0
        var atual: Trecho? = nil
        func fecha() { if let x = atual { r.append(x); atual = nil } }
        while i < n || j < m {
            if i < n, j < m, ma[i] == md[j] {
                fecha(); i += 1; j += 1
            } else if j < m, i == n || t[i][j + 1] >= t[i + 1][j] {
                if atual == nil { atual = Trecho(linhaAntes: ini + i + 1, linhaDepois: ini + j + 1, removidas: [], adicionadas: []) }
                atual!.adicionadas.append(md[j]); j += 1
            } else {
                if atual == nil { atual = Trecho(linhaAntes: ini + i + 1, linhaDepois: ini + j + 1, removidas: [], adicionadas: []) }
                atual!.removidas.append(ma[i]); i += 1
            }
        }
        fecha()
        return r
    }
}
