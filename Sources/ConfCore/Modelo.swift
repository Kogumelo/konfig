import Foundation

// MARK: - Caminhos

/// Um passo no caminho até um valor: nome de chave ou posição numa `[[lista de tabelas]]`.
public enum Segmento: Hashable, Sendable, CustomStringConvertible {
    case chave(String)
    case indice(Int)

    public var description: String {
        switch self {
        case .chave(let k): return Segmento.chaveFormatada(k)
        case .indice(let i): return "[\(i)]"
        }
    }

    /// Nome da chave como se escreve em TOML: sem aspas quando é chave simples.
    public static func chaveFormatada(_ k: String) -> String {
        if !k.isEmpty, k.utf8.allSatisfy(ehCaractereChaveSimples) { return k }
        return Formatar.textoBasico(k)
    }
}

/// Caminho completo de um valor, por exemplo `tarefas[0].nome`.
public typealias Caminho = [Segmento]

extension Array where Element == Segmento {
    /// Forma legível: `servidor.portas`, `tarefas[1].cron`.
    public var texto: String {
        var s = ""
        for seg in self {
            switch seg {
            case .chave:
                if !s.isEmpty { s += "." }
                s += seg.description
            case .indice:
                s += seg.description
            }
        }
        return s
    }
}

@inline(__always)
func ehCaractereChaveSimples(_ c: UInt8) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D
}

// MARK: - Datas

/// Os quatro tipos de data/hora do TOML numa estrutura só.
public struct DataHora: Hashable, Sendable {
    public enum Tipo: String, Hashable, Sendable {
        /// `1979-05-27T07:32:00Z` ou com `-03:00`
        case comFuso
        /// `1979-05-27T07:32:00`
        case local
        /// `1979-05-27`
        case data
        /// `07:32:00`
        case hora
    }

    public var tipo: Tipo
    public var ano = 0, mes = 1, dia = 1
    public var hora = 0, minuto = 0, segundo = 0
    /// Fração de segundo em nanossegundos.
    public var nanos = 0
    /// Quantos dígitos de fração o texto tinha (0 = nenhum). Usado só para escrever.
    public var casasFracao = 0
    /// Deslocamento em minutos para `comFuso`; 0 com `Z`.
    public var fusoMinutos = 0
    /// `true` quando o fuso foi escrito como `Z` (e não `+00:00`).
    public var fusoZ = true

    public init(tipo: Tipo) { self.tipo = tipo }

    public var temData: Bool { tipo != .hora }
    public var temHora: Bool { tipo != .data }

    /// Texto em RFC 3339 (o mesmo formato que o TOML escreve), com `T` entre data e hora.
    public var iso: String { texto(separador: "T", zMinusculo: false) }

    public func texto(separador: Character, zMinusculo: Bool) -> String {
        var s = ""
        if temData {
            s += pad(ano, 4) + "-" + pad(mes, 2) + "-" + pad(dia, 2)
        }
        if temHora {
            if temData { s.append(separador) }
            s += pad(hora, 2) + ":" + pad(minuto, 2) + ":" + pad(segundo, 2)
            // Mantém as casas do original, mas nunca menos que o necessário para o valor.
            var necessarias = 0
            if nanos > 0 {
                var t = pad(nanos, 9)
                while t.hasSuffix("0") { t.removeLast() }
                necessarias = t.count
            }
            let casas = min(9, max(casasFracao, necessarias))
            if casas > 0 { s += "." + pad(nanos, 9).prefix(casas) }
        }
        if tipo == .comFuso {
            if fusoZ && fusoMinutos == 0 {
                s += zMinusculo ? "z" : "Z"
            } else {
                let m = abs(fusoMinutos)
                s += (fusoMinutos < 0 ? "-" : "+") + pad(m / 60, 2) + ":" + pad(m % 60, 2)
            }
        }
        return s
    }

    private func pad(_ n: Int, _ w: Int) -> String {
        let s = String(n)
        return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
    }
}

// MARK: - Valores

public enum TipoValor: String, Sendable {
    case texto, inteiro, decimal, booleano, dataHora, dataHoraLocal, data, hora, lista, tabela, nulo

    /// Nome curto em português para a interface.
    public var nome: String {
        switch self {
        case .texto: return "texto"
        case .inteiro: return "inteiro"
        case .decimal: return "decimal"
        case .booleano: return "sim/não"
        case .dataHora: return "data-hora com fuso"
        case .dataHoraLocal: return "data-hora local"
        case .data: return "data"
        case .hora: return "hora"
        case .lista: return "lista"
        case .tabela: return "tabela"
        case .nulo: return "nulo"
        }
    }
}

/// Um valor já interpretado (TOML ou JSON). `nulo` só existe em JSON.
public indirect enum Valor: Sendable, Hashable {
    case texto(String)
    case inteiro(Int64)
    case decimal(Double)
    case booleano(Bool)
    case dataHora(DataHora)
    case lista([Valor])
    case tabela(Tabela)
    /// `null` do JSON.
    case nulo

    public var tipo: TipoValor {
        switch self {
        case .texto: return .texto
        case .inteiro: return .inteiro
        case .decimal: return .decimal
        case .booleano: return .booleano
        case .dataHora(let d):
            switch d.tipo {
            case .comFuso: return .dataHora
            case .local: return .dataHoraLocal
            case .data: return .data
            case .hora: return .hora
            }
        case .lista: return .lista
        case .tabela: return .tabela
        case .nulo: return .nulo
        }
    }

    // Igualdade estrita: textos comparados escalar a escalar (o TOML não
    // normaliza Unicode) e `nan` igual a `nan`.
    public static func == (a: Valor, b: Valor) -> Bool {
        switch (a, b) {
        case (.texto(let x), .texto(let y)): return x.unicodeScalars.elementsEqual(y.unicodeScalars)
        case (.inteiro(let x), .inteiro(let y)): return x == y
        case (.decimal(let x), .decimal(let y)): return (x.isNaN && y.isNaN) || (x == y && x.sign == y.sign)
        case (.booleano(let x), .booleano(let y)): return x == y
        case (.dataHora(let x), .dataHora(let y)): return x.equivalente(y)
        case (.lista(let x), .lista(let y)): return x == y
        case (.tabela(let x), .tabela(let y)): return x == y
        case (.nulo, .nulo): return true
        default: return false
        }
    }

    public func hash(into h: inout Hasher) {
        switch self {
        case .texto(let s): h.combine(0); for u in s.unicodeScalars { h.combine(u.value) }
        case .inteiro(let n): h.combine(1); h.combine(n)
        case .decimal(let d): h.combine(2); if d.isNaN { h.combine(-1) } else { h.combine(d.bitPattern) }
        case .booleano(let b): h.combine(3); h.combine(b)
        case .dataHora(let d): h.combine(4); h.combine(d.iso)
        case .lista(let l): h.combine(5); h.combine(l)
        case .tabela(let t): h.combine(6); h.combine(t)
        case .nulo: h.combine(7)
        }
    }
}

extension DataHora {
    /// Mesmo instante/valor, ignorando só detalhes de escrita (casas de fração, `Z` × `+00:00`).
    public func equivalente(_ o: DataHora) -> Bool {
        tipo == o.tipo && ano == o.ano && mes == o.mes && dia == o.dia && hora == o.hora
            && minuto == o.minuto && segundo == o.segundo && nanos == o.nanos && fusoMinutos == o.fusoMinutos
    }
}

/// Tabela com a ordem das chaves preservada.
public struct Tabela: Sendable, Hashable {
    public struct Par: Sendable, Hashable {
        public var chave: String
        public var valor: Valor
        public init(chave: String, valor: Valor) { self.chave = chave; self.valor = valor }
        public static func == (a: Par, b: Par) -> Bool {
            a.chave.unicodeScalars.elementsEqual(b.chave.unicodeScalars) && a.valor == b.valor
        }
        public func hash(into h: inout Hasher) {
            for u in chave.unicodeScalars { h.combine(u.value) }
            h.combine(valor)
        }
    }

    public var pares: [Par]

    public init(pares: [Par] = []) { self.pares = pares }

    public subscript(chave: String) -> Valor? {
        get { pares.first { $0.chave.unicodeScalars.elementsEqual(chave.unicodeScalars) }?.valor }
        set {
            if let i = pares.firstIndex(where: { $0.chave.unicodeScalars.elementsEqual(chave.unicodeScalars) }) {
                if let v = newValue { pares[i].valor = v } else { pares.remove(at: i) }
            } else if let v = newValue {
                pares.append(Par(chave: chave, valor: v))
            }
        }
    }

    // Igualdade sem depender da ordem (a ordem é detalhe de escrita).
    public static func == (a: Tabela, b: Tabela) -> Bool {
        guard a.pares.count == b.pares.count else { return false }
        for p in a.pares {
            guard let v = b[p.chave], v == p.valor else { return false }
        }
        return true
    }

    public func hash(into h: inout Hasher) { h.combine(pares.count) }

    /// Valor no caminho indicado (chaves e índices de `[[lista]]`).
    public func valor(em caminho: Caminho) -> Valor? { Valor.tabela(self).valor(em: caminho) }

    /// Cópia com o valor do caminho trocado. Devolve `nil` se o caminho não existir.
    public func substituindo(_ caminho: Caminho, por novo: Valor) -> Tabela? {
        guard case .tabela(let t)? = Valor.tabela(self).substituindo(caminho, por: novo) else { return nil }
        return t
    }
}

extension Valor {
    /// Valor no caminho indicado; caminho vazio é o próprio valor.
    public func valor(em caminho: Caminho) -> Valor? {
        var atual = self
        for seg in caminho {
            switch (seg, atual) {
            case (.chave(let k), .tabela(let t)):
                guard let v = t[k] else { return nil }
                atual = v
            case (.indice(let i), .lista(let l)):
                guard l.indices.contains(i) else { return nil }
                atual = l[i]
            default:
                return nil
            }
        }
        return atual
    }

    /// Cópia com o valor do caminho trocado (caminho vazio troca o valor inteiro).
    /// Devolve `nil` se o caminho não existir.
    public func substituindo(_ caminho: Caminho, por novo: Valor) -> Valor? {
        Valor.troca(self, caminho[...], novo)
    }

    private static func troca(_ atual: Valor, _ resto: ArraySlice<Segmento>, _ novo: Valor) -> Valor? {
        guard let seg = resto.first else { return novo }
        switch (seg, atual) {
        case (.chave(let k), .tabela(var t)):
            guard let v = t[k], let n = troca(v, resto.dropFirst(), novo) else { return nil }
            t[k] = n
            return .tabela(t)
        case (.indice(let i), .lista(var l)):
            guard l.indices.contains(i), let n = troca(l[i], resto.dropFirst(), novo) else { return nil }
            l[i] = n
            return .lista(l)
        default:
            return nil
        }
    }
}

// MARK: - Posições no texto

/// Onde um valor está no texto original. Para listas, guarda também a posição de cada item.
public struct Posicao: Sendable, Hashable {
    /// Intervalo de bytes UTF-8 do valor, contado desde o início do arquivo (BOM incluído).
    public var intervalo: Range<Int>
    /// Itens de uma lista, na ordem (vazio para os outros tipos).
    public var itens: [Posicao]

    public init(intervalo: Range<Int>, itens: [Posicao] = []) {
        self.intervalo = intervalo
        self.itens = itens
    }
}

/// Uma linha `chave = valor` do arquivo.
public struct Entrada: Sendable {
    /// Caminho completo, com índices para itens de `[[lista]]`.
    public var caminho: Caminho
    /// A chave como aparece na linha (pode ter pontos: `apple.color`).
    public var chaveEscrita: String
    public var valor: Valor
    public var tipo: TipoValor { valor.tipo }
    /// Posição do valor (e dos itens, se for lista).
    public var posicao: Posicao
    /// Intervalo de bytes UTF-8 do valor no texto original.
    public var intervalo: Range<Int> { posicao.intervalo }
    /// Intervalo de bytes da chave.
    public var intervaloChave: Range<Int>
    /// Linha (começando em 1) onde a chave está.
    public var linha: Int
    /// Linha onde o valor termina (listas e textos de várias linhas ocupam mais de uma).
    public var linhaFinal: Int
    /// Linhas de comentário logo acima, sem o `#` e sem espaços nas pontas.
    public var comentarioAcima: [String]
    /// Comentário no fim da linha, se houver.
    public var comentarioFim: String?
    /// Índice em `DocumentoConf.cabecalhos` da seção onde a linha está (`nil` = raiz).
    public var secao: Int?
}

/// Uma seção do arquivo: em TOML, um cabeçalho `[tabela]` ou `[[lista de tabelas]]`;
/// em JSON, um objeto `{…}` aninhado ou um objeto dentro de uma lista de objetos.
public struct Cabecalho: Sendable {
    /// Caminho concreto da tabela (com índice para itens de `[[lista]]`).
    public var caminho: Caminho
    /// Nomes do cabeçalho, sem índices.
    public var nomes: [String]
    public var ehListaDeTabelas: Bool
    /// Intervalo de bytes do cabeçalho inteiro, colchetes incluídos (em JSON, o objeto `{…}`).
    public var intervalo: Range<Int>
    public var linha: Int
    public var comentarioAcima: [String]
    public var comentarioFim: String?
}

/// Resultado da leitura de um arquivo (TOML ou JSON).
public struct DocumentoConf: Sendable {
    public var formato: Formato
    /// Bytes exatamente como foram lidos.
    public var bytes: [UInt8]
    /// O valor do arquivo inteiro: em TOML sempre uma tabela; em JSON, qualquer valor.
    public var valorRaiz: Valor
    /// Cada `chave = valor` (em JSON, cada membro de objeto que não é seção), na ordem do arquivo.
    public var entradas: [Entrada]
    /// Cada seção (cabeçalho TOML ou objeto JSON), na ordem do arquivo.
    public var cabecalhos: [Cabecalho]
    /// `"\r\n"` se a primeira quebra de linha do arquivo for CRLF; senão `"\n"`.
    public var quebraDeLinha: String
    public var temBOM: Bool
    /// JSON com comentários ou vírgula final (JSONC). Sempre `false` em TOML.
    public var usaExtensoesJSONC = false

    public init(formato: Formato = .toml, bytes: [UInt8], raiz: Valor, entradas: [Entrada], cabecalhos: [Cabecalho],
                quebraDeLinha: String, temBOM: Bool, usaExtensoesJSONC: Bool = false) {
        self.formato = formato
        self.bytes = bytes
        self.valorRaiz = raiz
        self.entradas = entradas
        self.cabecalhos = cabecalhos
        self.quebraDeLinha = quebraDeLinha
        self.temBOM = temBOM
        self.usaExtensoesJSONC = usaExtensoesJSONC
    }

    public init(bytes: [UInt8], raiz: Tabela, entradas: [Entrada], cabecalhos: [Cabecalho],
                quebraDeLinha: String, temBOM: Bool) {
        self.init(formato: .toml, bytes: bytes, raiz: .tabela(raiz), entradas: entradas, cabecalhos: cabecalhos,
                  quebraDeLinha: quebraDeLinha, temBOM: temBOM)
    }

    /// A raiz como tabela (vazia quando a raiz de um JSON não é objeto).
    public var raiz: Tabela {
        if case .tabela(let t) = valorRaiz { return t }
        return Tabela()
    }

    /// Nome do formato como aparece na tela: "TOML", "JSON" ou "JSONC".
    public var nomeFormato: String { usaExtensoesJSONC ? "JSONC" : formato.nome }

    /// Entrada pelo caminho exato.
    public func entrada(_ caminho: Caminho) -> Entrada? {
        entradas.first { $0.caminho == caminho }
    }

    /// Texto original de um intervalo.
    public func texto(_ r: Range<Int>) -> String {
        String(decoding: bytes[r], as: UTF8.self)
    }
}

/// Nome antigo, de quando só havia TOML.
public typealias DocumentoTOML = DocumentoConf

/// Erro de leitura com posição (linha e coluna começam em 1; coluna conta caracteres).
public struct ErroLeitura: Error, Sendable, CustomStringConvertible, LocalizedError {
    public var mensagem: String
    public var linha: Int
    public var coluna: Int
    /// Deslocamento em bytes no texto.
    public var deslocamento: Int
    public var formato: Formato = .toml

    public var description: String { "linha \(linha), coluna \(coluna): \(mensagem)" }
    public var errorDescription: String? { "\(formato.nome) inválido na \(description)" }
}

/// Nome antigo, de quando só havia TOML.
public typealias ErroTOML = ErroLeitura
