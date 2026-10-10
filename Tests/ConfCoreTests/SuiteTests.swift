import Foundation
import Testing
@testable import ConfCore

/// Casos da suíte oficial toml-test (TOML 1.0), copiados em `Fixtures/`.
enum Suite {
    static let pasta: URL = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    static func casos(_ sub: String) -> [String] {
        let raiz = pasta.appendingPathComponent(sub)
        let e = FileManager.default.enumerator(at: raiz, includingPropertiesForKeys: nil)!
        var r: [String] = []
        for case let u as URL in e where u.pathExtension == "toml" {
            r.append(String(u.path.dropFirst(pasta.path.count + 1)))
        }
        return r.sorted()
    }

    static let validos = casos("valid")
    static let invalidos = casos("invalid")

    static func bytes(_ caso: String) -> [UInt8] {
        Array(try! Data(contentsOf: pasta.appendingPathComponent(caso)))
    }
}

@Test func suiteTemOsCasos() {
    #expect(Suite.validos.count == 208)
    #expect(Suite.invalidos.count == 501)
}

@Test(arguments: Suite.validos)
func casoValido(_ caso: String) throws {
    let doc: DocumentoTOML
    do { doc = try Leitor.ler(Suite.bytes(caso)) } catch {
        Issue.record("recusou um caso válido: \(error)")
        return
    }
    let jsonURL = Suite.pasta.appendingPathComponent(String(caso.dropLast(5)) + ".json")
    let esperado = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL), options: [.fragmentsAllowed])
    let diferencas = Comparar.tabela(doc.raiz, esperado, "")
    #expect(diferencas.isEmpty, "\(diferencas.prefix(5).joined(separator: "\n"))")
}

@Test(arguments: Suite.invalidos)
func casoInvalido(_ caso: String) {
    do {
        let doc = try Leitor.ler(Suite.bytes(caso))
        Issue.record("aceitou um caso inválido: \(doc.raiz)")
    } catch {
        #expect(error.linha >= 1 && error.coluna >= 1)
    }
}

/// Compara a estrutura lida com o JSON da suíte (mesmas regras do toml-test:
/// decimais por valor, datas por instante).
enum Comparar {
    static func tabela(_ t: Tabela, _ j: Any, _ onde: String) -> [String] {
        guard let obj = j as? NSDictionary else { return ["\(onde): esperado objeto"] }
        var r: [String] = []
        if obj.count != t.pares.count {
            r.append("\(onde): \(t.pares.count) chaves, esperado \(obj.count)")
        }
        for case let (k as NSString, v) in obj {
            let ks = k as String
            guard let par = t.pares.first(where: { ($0.chave as NSString).isEqual(to: ks) }) else {
                r.append("\(onde): falta a chave \(ks)")
                continue
            }
            r += valor(par.valor, v, onde + "." + ks)
        }
        return r
    }

    static func valor(_ v: Valor, _ j: Any, _ onde: String) -> [String] {
        if let arr = j as? [Any] {
            guard case .lista(let l) = v else { return ["\(onde): esperado lista, veio \(v.tipo)"] }
            guard l.count == arr.count else { return ["\(onde): \(l.count) itens, esperado \(arr.count)"] }
            return zip(l, arr).enumerated().flatMap { i, p in valor(p.0, p.1, "\(onde)[\(i)]") }
        }
        guard let obj = j as? NSDictionary else { return ["\(onde): JSON inesperado"] }
        guard let tipo = obj["type"] as? String, let texto = obj["value"] as? String, obj.count == 2 else {
            if case .tabela(let t) = v { return tabela(t, obj, onde) }
            return ["\(onde): esperado tabela, veio \(v.tipo)"]
        }
        switch (tipo, v) {
        case ("string", .texto(let s)):
            return (s as NSString).isEqual(to: texto) ? [] : ["\(onde): texto \(s.debugDescription) ≠ \(texto.debugDescription)"]
        case ("integer", .inteiro(let n)):
            return String(n) == texto ? [] : ["\(onde): \(n) ≠ \(texto)"]
        case ("float", .decimal(let d)):
            if texto.lowercased().hasSuffix("nan") { return d.isNaN ? [] : ["\(onde): \(d) ≠ nan"] }
            let e: Double = texto == "inf" || texto == "+inf" ? .infinity : texto == "-inf" ? -.infinity : Double(texto)!
            return d == e ? [] : ["\(onde): \(d) ≠ \(texto)"]
        case ("bool", .booleano(let b)):
            return String(b) == texto ? [] : ["\(onde): \(b) ≠ \(texto)"]
        case ("datetime", .dataHora(let dh)) where dh.tipo == .comFuso,
             ("datetime-local", .dataHora(let dh)) where dh.tipo == .local,
             ("date-local", .dataHora(let dh)) where dh.tipo == .data,
             ("time-local", .dataHora(let dh)) where dh.tipo == .hora:
            guard let a = Instante(dh.iso, dh.tipo), let b = Instante(texto, dh.tipo) else {
                return ["\(onde): data ilegível \(dh.iso) / \(texto)"]
            }
            return a == b ? [] : ["\(onde): \(dh.iso) ≠ \(texto)"]
        default:
            return ["\(onde): tipo \(v.tipo) ≠ \(tipo)"]
        }
    }
}

/// Leitor independente de RFC 3339 para comparar datas (instante absoluto quando há fuso).
struct Instante: Equatable {
    var segundos: Int64
    var nanos: Int

    init?(_ s0: String, _ tipo: DataHora.Tipo) {
        let s = Array(s0.replacingOccurrences(of: " ", with: "T").replacingOccurrences(of: "t", with: "T")
            .replacingOccurrences(of: "z", with: "Z").utf8)
        func n(_ i: Int, _ k: Int) -> Int? {
            guard i + k <= s.count else { return nil }
            var v = 0
            for c in s[i..<(i + k)] { guard c >= 48 && c <= 57 else { return nil }; v = v * 10 + Int(c - 48) }
            return v
        }
        var i = 0
        var y = 1970, mo = 1, d = 1, h = 0, mi = 0, se = 0, ns = 0, off = 0
        if tipo != .hora {
            guard let a = n(0, 4), let b = n(5, 2), let c = n(8, 2) else { return nil }
            y = a; mo = b; d = c; i = 10
            if tipo != .data { i += 1 }
        }
        if tipo != .data {
            guard let a = n(i, 2), let b = n(i + 3, 2), let c = n(i + 6, 2) else { return nil }
            h = a; mi = b; se = c; i += 8
            if i < s.count, s[i] == 46 {
                i += 1
                var dig = ""
                while i < s.count, s[i] >= 48, s[i] <= 57 { dig.append(Character(UnicodeScalar(s[i]))); i += 1 }
                dig = String((dig + "000000000").prefix(9))
                ns = Int(dig)!
            }
            if tipo == .comFuso {
                guard i < s.count else { return nil }
                if s[i] == 90 { i += 1 } else {
                    guard let a = n(i + 1, 2), let b = n(i + 4, 2) else { return nil }
                    off = (a * 60 + b) * (s[i] == 45 ? -1 : 1)
                    i += 6
                }
            }
        }
        guard i == s.count else { return nil }
        // dias desde 1970-01-01 (algoritmo de Howard Hinnant)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let dias = era * 146097 + doe - 719468
        segundos = Int64(dias) * 86400 + Int64(h * 3600 + mi * 60 + se) - Int64(off * 60)
        nanos = ns
    }
}
