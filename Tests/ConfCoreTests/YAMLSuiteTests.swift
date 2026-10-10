import Foundation
import Testing
@testable import ConfCore

/// Casos da suíte oficial yaml-test-suite (release data-2022-01-17), em `Fixtures/yaml/`.
///
/// Cada caso é classificado pelos eventos do parser de referência (`test.event`) e pelo texto:
/// - **erro**: a suíte diz que o YAML é inválido (arquivo `error`) — precisa ser recusado;
/// - **fora** do subconjunto: âncora, alias, etiqueta, vários documentos, diretiva, chave
///   complexa (`? ` ou coleção como chave), chave vazia ou nula, mesclagem `<<` — precisa ser
///   recusado (de preferência com `foraDoSubconjunto`) ou lido igual ao `in.json`;
/// - **dentro**: o resto — precisa ser lido igual ao `in.json`.
enum SuiteYAML {
    static let pasta = Suite.pasta.appendingPathComponent("yaml")

    static let casos: [String] = {
        let e = FileManager.default.enumerator(at: pasta, includingPropertiesForKeys: nil)!
        var r: [String] = []
        for case let u as URL in e where u.lastPathComponent == "in.yaml" {
            r.append(String(u.deletingLastPathComponent().path.dropFirst(pasta.path.count + 1)))
        }
        return r.sorted()
    }()

    static func arquivo(_ caso: String, _ nome: String) -> Data? {
        try? Data(contentsOf: pasta.appendingPathComponent(caso).appendingPathComponent(nome))
    }

    static func bytes(_ caso: String) -> [UInt8] { [UInt8](arquivo(caso, "in.yaml")!) }

    enum Classe: String { case erro, fora, dentro }

    /// Por que o caso está fora do subconjunto (`nil` se está dentro).
    static func motivoFora(_ caso: String) -> String? {
        let eventos = String(decoding: arquivo(caso, "test.event") ?? Data(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        let yaml = String(decoding: bytes(caso), as: UTF8.self)
        if eventos.filter({ $0.hasPrefix("+DOC") }).count > 1 { return "vários documentos" }
        if eventos.contains(where: { $0.hasPrefix("=ALI") }) { return "alias" }
        // pilha: em cada mapa, os filhos alternam chave e valor
        var pilha: [(mapa: Bool, n: Int)] = []
        for ev in eventos {
            let partes = ev.split(separator: " ", maxSplits: 1).map(String.init)
            let tipo = partes[0]
            let resto = partes.count > 1 ? partes[1] : ""
            if ["+MAP", "+SEQ", "=VAL"].contains(tipo) {
                var props = resto
                if tipo == "+MAP" || tipo == "+SEQ" { props = props.replacingOccurrences(of: "{}", with: "").replacingOccurrences(of: "[]", with: "") }
                // propriedades vêm antes do valor: `&ancora`, `<etiqueta>`
                var r = Substring(props)
                while r.hasPrefix(" ") { r = r.dropFirst() }
                while r.hasPrefix("&") || r.hasPrefix("<") {
                    if r.hasPrefix("&") { return "âncora" }
                    return "etiqueta"
                }
                let ehChave = pilha.last.map { $0.mapa && $0.n % 2 == 0 } ?? false
                if ehChave {
                    if tipo != "=VAL" { return "chave complexa" }
                    if r.hasPrefix(":") {
                        let k = String(r.dropFirst())
                        if k == "<<" { return "mesclagem" }
                        if case .nulo = LeitorYAML.resolver(k) { return "chave vazia ou nula" }
                    }
                }
                if !pilha.isEmpty { pilha[pilha.count - 1].n += 1 }
                if tipo != "=VAL" { pilha.append((tipo == "+MAP", 0)) }
            } else if tipo == "-MAP" || tipo == "-SEQ" {
                pilha.removeLast()
            }
        }
        for l in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            if l.hasPrefix("%") { return "diretiva" }
            let t = l.drop { $0 == " " || $0 == "-" || $0 == "\t" }
            if t == "?" || t.hasPrefix("? ") || t.hasPrefix("?\t") { return "chave complexa" }
            if l.contains("[? ") || l.contains("{? ") || l.contains(", ? ") { return "chave complexa" }
        }
        return nil
    }

    static func classe(_ caso: String) -> Classe {
        if arquivo(caso, "error") != nil { return .erro }
        return motivoFora(caso) == nil ? .dentro : .fora
    }

    static let dentro = casos.filter { classe($0) == .dentro }
    static let fora = casos.filter { classe($0) == .fora }
    static let erros = casos.filter { classe($0) == .erro }

    /// Casos dentro do subconjunto que o km-conf recusa, cada um com o motivo. Precisa
    /// continuar vazio ou com motivo documentado (o teste confere os dois sentidos).
    static let recusadosDentro: [String: String] = [:]

    /// Valor esperado do `in.json`. `nil` se o caso não tem (a suíte não dá JSON para ele).
    static func esperado(_ caso: String) -> Any?? {
        guard let d = arquivo(caso, "in.json") else { return .none }
        if d.allSatisfy({ $0 == 0x20 || $0 == 0x0A }) { return .some(nil) }        // nenhum documento
        return .some(try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]))
    }
}

/// Compara o valor lido com o JSON da suíte (números por valor).
enum CompararYAML {
    static func valor(_ v: Valor, _ j: Any, _ onde: String) -> [String] {
        if let x = CompararJSON.booleano(j) {
            if case .booleano(let b) = v, b == x { return [] }
            return ["\(onde): esperado \(x), veio \(v)"]
        }
        switch j {
        case is NSNull:
            if case .nulo = v { return [] }
            return ["\(onde): esperado null, veio \(v)"]
        case let n as NSNumber:
            switch v {
            case .inteiro(let x): return Double(x) == n.doubleValue ? [] : ["\(onde): \(x) ≠ \(n)"]
            case .decimal(let x): return x == n.doubleValue ? [] : ["\(onde): \(x) ≠ \(n)"]
            default: return ["\(onde): esperado número \(n), veio \(v)"]
            }
        case let s as String:
            if case .texto(let t) = v, (t as NSString).isEqual(to: s) { return [] }
            return ["\(onde): esperado \(s.debugDescription), veio \(v)"]
        case let a as [Any]:
            guard case .lista(let l) = v else { return ["\(onde): esperado lista, veio \(v)"] }
            guard l.count == a.count else { return ["\(onde): \(l.count) itens, esperado \(a.count)"] }
            return zip(l, a).enumerated().flatMap { i, p in valor(p.0, p.1, "\(onde)[\(i)]") }
        case let d as NSDictionary:
            guard case .tabela(let t) = v else { return ["\(onde): esperado mapa, veio \(v)"] }
            var r: [String] = []
            if d.count != t.pares.count { r.append("\(onde): \(t.pares.count) chaves, esperado \(d.count)") }
            for case let (k as NSString, x) in d {
                guard let par = t.pares.first(where: { ($0.chave as NSString).isEqual(to: k as String) }) else {
                    r.append("\(onde): falta a chave \(k)")
                    continue
                }
                r += valor(par.valor, x, onde + "." + (k as String))
            }
            return r
        default:
            return ["\(onde): JSON inesperado"]
        }
    }
}

@Test func yamlSuiteTemOsCasos() {
    #expect(SuiteYAML.casos.count == 402)
    #expect(SuiteYAML.dentro.count + SuiteYAML.fora.count + SuiteYAML.erros.count == 402)
    // as contagens vão para o relatório da missão (swift test mostra o print)
    print("yaml-test-suite: \(SuiteYAML.casos.count) casos; dentro \(SuiteYAML.dentro.count), fora \(SuiteYAML.fora.count), erro \(SuiteYAML.erros.count)")
    var motivos: [String: Int] = [:]
    for c in SuiteYAML.fora { motivos[SuiteYAML.motivoFora(c)!, default: 0] += 1 }
    print("fora do subconjunto, por motivo: \(motivos.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
}

@Test(arguments: SuiteYAML.dentro)
func yamlDentro(_ caso: String) throws {
    let doc: DocumentoConf
    do { doc = try LeitorYAML.ler(SuiteYAML.bytes(caso)) } catch {
        if let motivo = SuiteYAML.recusadosDentro[caso] {
            print("dentro e recusado \(caso): \(motivo)")
            return
        }
        Issue.record("recusou um caso dentro do subconjunto: \(error)")
        return
    }
    #expect(SuiteYAML.recusadosDentro[caso] == nil, "aceito agora: tirar de recusadosDentro")
    switch SuiteYAML.esperado(caso) {
    case .none:
        break                                                               // a suíte não dá JSON
    case .some(nil):
        #expect(doc.vazio, "esperado arquivo sem documento")
    case .some(let j?):
        let d = CompararYAML.valor(doc.valorRaiz, j, "")
        #expect(d.isEmpty, "\(d.prefix(5).joined(separator: "\n"))")
    }
}

@Test(arguments: SuiteYAML.fora)
func yamlFora(_ caso: String) throws {
    let doc: DocumentoConf
    do { doc = try LeitorYAML.ler(SuiteYAML.bytes(caso)) } catch {
        return                                                              // recusado: o que se espera
    }
    // aceito: só vale se os valores forem os mesmos do in.json
    switch SuiteYAML.esperado(caso) {
    case .none:
        Issue.record("fora do subconjunto (\(SuiteYAML.motivoFora(caso)!)), aceito e sem JSON para conferir")
    case .some(nil):
        #expect(doc.vazio)
    case .some(let j?):
        let d = CompararYAML.valor(doc.valorRaiz, j, "")
        #expect(d.isEmpty, "fora do subconjunto (\(SuiteYAML.motivoFora(caso)!)), aceito com valores diferentes: \(d.prefix(5).joined(separator: "\n"))")
    }
}

@Test(arguments: SuiteYAML.erros)
func yamlErro(_ caso: String) {
    do {
        let doc = try LeitorYAML.ler(SuiteYAML.bytes(caso))
        Issue.record("aceitou um caso inválido: \(doc.valorRaiz)")
    } catch {
        #expect(error.linha >= 1 && error.coluna >= 1)
    }
}

/// Contagens para o relatório: quantos casos de cada classe foram aceitos ou recusados, e como.
@Test func yamlSuiteContagens() {
    var dentroAceitos = 0, dentroRecusados = 0
    for c in SuiteYAML.dentro { if (try? LeitorYAML.ler(SuiteYAML.bytes(c))) != nil { dentroAceitos += 1 } else { dentroRecusados += 1 } }
    var foraComoFora = 0, foraComoErro = 0, foraAceitos = 0
    for c in SuiteYAML.fora {
        do { _ = try LeitorYAML.ler(SuiteYAML.bytes(c)); foraAceitos += 1 } catch {
            if error.foraDoSubconjunto { foraComoFora += 1 } else { foraComoErro += 1 }
        }
    }
    var errosRecusados = 0, errosComoFora = 0
    for c in SuiteYAML.erros {
        do { _ = try LeitorYAML.ler(SuiteYAML.bytes(c)) } catch {
            errosRecusados += 1
            if error.foraDoSubconjunto { errosComoFora += 1 }
        }
    }
    print("""
        yaml-test-suite — dentro: \(SuiteYAML.dentro.count) (aceitos \(dentroAceitos), recusados \(dentroRecusados)); \
        fora: \(SuiteYAML.fora.count) (recusados como fora do subconjunto \(foraComoFora), recusados como erro \(foraComoErro), \
        aceitos com os valores do in.json \(foraAceitos)); erro: \(SuiteYAML.erros.count) (recusados \(errosRecusados), \
        dos quais \(errosComoFora) pelo aviso de fora do subconjunto)
        """)
    #expect(dentroRecusados == SuiteYAML.recusadosDentro.count)
    #expect(errosRecusados == SuiteYAML.erros.count)
}

/// Entrada quebrada não pode travar nem estourar índice: cada prefixo de cada caso, e cada
/// caso sem um byte, é lido (aceito ou recusado) sem erro de execução.
@Test func yamlLeitorRobusto() {
    var lidos = 0
    for c in SuiteYAML.casos {
        let bytes = SuiteYAML.bytes(c)
        for n in 0..<bytes.count {
            _ = try? LeitorYAML.ler(Array(bytes.prefix(n)))
            var sem = bytes
            sem.remove(at: n)
            _ = try? LeitorYAML.ler(sem)
            lidos += 2
        }
    }
    #expect(lidos > 10_000)
}
