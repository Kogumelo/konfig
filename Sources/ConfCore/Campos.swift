import Foundation

/// Que controle a tela usa para um valor.
public enum TipoCampo: Hashable, Sendable {
    case texto
    case inteiro
    case decimal
    case booleano
    /// Texto com opções vindas de um comentário `a | b | c`.
    case escolha([String])
    case data(DataHora.Tipo)
    /// Lista de valores simples, todos do mesmo tipo (etiquetas).
    case lista(TipoValor)
    /// Texto cru do valor, no formato do arquivo (listas mistas, tabelas embutidas, `null`…).
    case cru

    public var nome: String {
        switch self {
        case .texto: return "texto"
        case .inteiro: return "inteiro"
        case .decimal: return "decimal"
        case .booleano: return "sim/não"
        case .escolha: return "escolha"
        case .data(let t):
            switch t {
            case .comFuso: return "data-hora com fuso"
            case .local: return "data-hora local"
            case .data: return "data"
            case .hora: return "hora"
            }
        case .lista(let t): return "lista de \(TipoCampo.plural(t))"
        case .cru: return "texto cru"
        }
    }

    /// Nome para a tela; o texto cru leva o nome do formato ("TOML", "JSON").
    public func nome(em formato: Formato) -> String {
        if case .cru = self { return formato.nome }
        return nome
    }

    static func plural(_ t: TipoValor) -> String {
        switch t {
        case .texto: return "textos"
        case .inteiro: return "inteiros"
        case .decimal: return "decimais"
        case .booleano: return "sim/não"
        case .dataHora, .dataHoraLocal: return "datas-horas"
        case .data: return "datas"
        case .hora: return "horas"
        case .lista: return "listas"
        case .tabela: return "tabelas"
        case .nulo: return "nulos"
        }
    }
}

/// Um campo da tela, ligado a uma linha `chave = valor`.
public struct Campo: Identifiable, Sendable {
    public var id: String { caminho.texto }
    public var caminho: Caminho
    /// A chave como está escrita na linha.
    public var rotulo: String
    public var tipo: TipoCampo
    public var valor: Valor
    /// Texto do valor como está no arquivo.
    public var textoOriginal: String
    /// Comentários acima e no fim da linha, para ajuda.
    public var ajuda: String?
    public var linha: Int
}

/// Uma seção da tela: a raiz, uma `[tabela]` ou um item de `[[lista]]`
/// (em JSON: um objeto aninhado ou um objeto dentro de uma lista; em .env, só a raiz;
/// em INI, a seção "Geral" e cada `[seção]`).
public struct Secao: Identifiable, Sendable {
    /// Estável enquanto a estrutura do arquivo não muda: "raiz" ou o caminho do cabeçalho.
    public var id: String
    public var titulo: String
    /// Como aparece no arquivo: `[servidor]`, `[[tarefas]]` ou "chaves fora de qualquer tabela".
    public var subtitulo: String
    /// Para itens de `[[lista]]`: nome da lista (agrupa na barra lateral).
    public var grupo: String?
    /// Posição (começando em 0) e total de itens na `[[lista]]`.
    public var indiceItem: Int?
    public var totalItens: Int?
    public var caminho: Caminho
    public var campos: [Campo]
    public var ajuda: String?
}

public enum Campos {
    /// Monta as seções na ordem do arquivo.
    public static func secoes(_ doc: DocumentoConf) -> [Secao] {
        // YAML se organiza como JSON: mapas viram seções e listas de mapas, grupos
        let json = doc.formato.ehJSON || doc.formato == .yaml
        var porSecao: [Int: [Campo]] = [:]
        var raiz: [Campo] = []
        for e in doc.entradas {
            let c = campo(e, doc: doc)
            if let s = e.secao { porSecao[s, default: []].append(c) } else { raiz.append(c) }
        }
        var r: [Secao] = []
        if !raiz.isEmpty || doc.cabecalhos.isEmpty {
            var sub = "chaves fora de qualquer tabela"
            if json { if case .tabela = doc.valorRaiz { sub = "chaves do objeto principal" } else { sub = "valor principal do arquivo" } }
            var titulo = "Raiz"
            if doc.formato == .env { titulo = "Variáveis"; sub = "CHAVE=valor (todos os valores são texto)" }
            if doc.formato == .ini { titulo = "Geral"; sub = "chaves antes da primeira seção" }
            if doc.formato == .yaml {
                if case .tabela = doc.valorRaiz { sub = "chaves do mapa principal" } else { sub = "valor principal do arquivo" }
            }
            r.append(Secao(id: "raiz", titulo: titulo, subtitulo: sub, caminho: [], campos: raiz))
        }
        // total de itens por lista de tabelas (mesmo caminho sem o índice final)
        var totais: [Caminho: Int] = [:]
        for c in doc.cabecalhos where c.ehListaDeTabelas { totais[Array(c.caminho.dropLast()), default: 0] += 1 }

        for (i, c) in doc.cabecalhos.enumerated() {
            var nome = c.nomes.map(Segmento.chaveFormatada).joined(separator: ".")
            var subtitulo = c.ehListaDeTabelas ? "[[\(nome)]]" : "[\(nome)]"
            if json {
                // em JSON o caminho tem os índices das listas: `tarefas[0].ambiente`
                let lista = c.ehListaDeTabelas ? Array(c.caminho.dropLast()) : c.caminho
                nome = lista.isEmpty ? "(raiz)" : lista.texto
                let chave: String
                switch lista.last { case .chave(let k)?: chave = Formatar.textoBasico(k) + ": "; default: chave = "" }
                subtitulo = c.ehListaDeTabelas ? chave + "[ { … } ]" : chave + "{ … }"
                if doc.formato == .yaml {
                    let k: String
                    switch lista.last { case .chave(let x)?: k = x + ":"; default: k = "" }
                    subtitulo = c.ehListaDeTabelas ? (k.isEmpty ? "- …" : k + " - …") : k + " …"
                }
            }
            if doc.formato == .ini {
                // o nome como está entre os colchetes (pontos e espaços são literais)
                nome = c.nomes.first ?? ""
                subtitulo = "[\(nome)]"
            }
            let campos = porSecao[i] ?? []
            var s = Secao(id: c.caminho.texto, titulo: nome, subtitulo: subtitulo, caminho: c.caminho, campos: campos)
            let ajuda = (c.comentarioAcima + [c.comentarioFim].compactMap { $0 }).filter { !$0.isEmpty }
            s.ajuda = ajuda.isEmpty ? nil : ajuda.joined(separator: "\n")
            if c.ehListaDeTabelas, case .indice(let k)? = c.caminho.last {
                s.grupo = nome
                s.indiceItem = k
                s.totalItens = totais[Array(c.caminho.dropLast())]
                s.titulo = nomeDoItem(campos) ?? "item \(k + 1)"
            }
            r.append(s)
        }
        return r
    }

    /// Comentário de abertura do arquivo: os blocos de comentário antes da primeira linha
    /// com conteúdo que não ficaram presos a nenhum campo (um bloco colado à primeira chave
    /// ou seção, sem linha em branco no meio, já é a ajuda dela). Sem o marcador (`#`, `;`,
    /// `//`) e um espaço depois dele, mas com o recuo que vem a seguir; linhas em branco
    /// entre blocos viram uma linha vazia. `nil` se não houver.
    public static func comentarioDeAbertura(_ doc: DocumentoConf) -> String? {
        let marcadores: [String]
        switch doc.formato {
        case .toml, .yaml, .env: marcadores = ["#"]
        case .ini: marcadores = [";", "#"]
        case .json, .json5: marcadores = ["//"]
        }
        var texto = String(decoding: doc.bytes, as: UTF8.self)
        if texto.hasPrefix("\u{FEFF}") { texto.removeFirst() }
        var blocos: [[String]] = []
        var atual: [String] = []
        var colado = false   // o último bloco termina logo acima da primeira linha com conteúdo
        // `\r\n` é um caractere só em Swift: `isNewline` pega `\n` e `\r\n`
        for linha in texto.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let l = linha.trimmingCharacters(in: .whitespaces)
            if l.isEmpty {
                if !atual.isEmpty { blocos.append(atual); atual = [] }
                continue
            }
            guard let m = marcadores.first(where: { l.hasPrefix($0) }) else {
                // nada se prende ao `{` inicial do JSON (em YAML, o bloco colado ao `---` já é
                // a ajuda da primeira chave)
                colado = !atual.isEmpty && !doc.formato.ehJSON
                break
            }
            var resto = l.dropFirst(m.count)
            if resto.first == " " { resto = resto.dropFirst() }
            atual.append(String(resto))
        }
        if !atual.isEmpty { blocos.append(atual) }
        if colado { blocos.removeLast() }
        var linhas = blocos.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while linhas.first?.isEmpty == true { linhas.removeFirst() }
        while linhas.last?.isEmpty == true { linhas.removeLast() }
        return linhas.isEmpty ? nil : linhas.joined(separator: "\n")
    }

    /// Nome amigável para um item de `[[lista]]`: valor de `nome`, `name`, `titulo`, `title` ou `id`.
    static func nomeDoItem(_ campos: [Campo]) -> String? {
        for k in ["nome", "name", "titulo", "title", "id", "rotulo", "label"] {
            if let c = campos.first(where: { $0.rotulo == k }) {
                switch c.valor {
                case .texto(let s) where !s.isEmpty: return s
                case .inteiro(let n): return "\(k) \(n)"
                default: break
                }
            }
        }
        return nil
    }

    public static func campo(_ e: Entrada, doc: DocumentoConf) -> Campo {
        let comentarios = (e.comentarioAcima + [e.comentarioFim].compactMap { $0 }).filter { !$0.isEmpty }
        return Campo(caminho: e.caminho, rotulo: e.chaveEscrita, tipo: tipo(e), valor: e.valor,
                     textoOriginal: doc.texto(e.intervalo),
                     ajuda: comentarios.isEmpty ? nil : comentarios.joined(separator: "\n"),
                     linha: e.linha)
    }

    public static func tipo(_ e: Entrada) -> TipoCampo {
        switch e.valor {
        case .texto(let s):
            for c in [e.comentarioFim].compactMap({ $0 }) + e.comentarioAcima.reversed() {
                if var ops = opcoes(c) {
                    if !ops.contains(s) { ops.insert(s, at: 0) }
                    return .escolha(ops)
                }
            }
            return .texto
        case .inteiro: return .inteiro
        case .decimal: return .decimal
        case .booleano: return .booleano
        case .dataHora(let d): return .data(d.tipo)
        case .lista(let itens):
            guard let t = itens.first?.tipo, t != .lista, t != .tabela,
                  itens.allSatisfy({ $0.tipo == t }) else { return .cru }
            // listas com textos de várias linhas ficam melhor como texto cru
            if itens.contains(where: { if case .texto(let s) = $0 { return s.contains("\n") }; return false }) {
                return .cru
            }
            return .lista(t)
        case .tabela, .nulo: return .cru
        }
    }

    /// Lê `a | b | c` (com ou sem aspas em cada opção). Precisa de pelo menos duas opções.
    public static func opcoes(_ comentario: String) -> [String]? {
        guard comentario.contains("|") else { return nil }
        let partes = comentario.split(separator: "|", omittingEmptySubsequences: false).map { p -> String in
            var s = p.trimmingCharacters(in: .whitespaces)
            if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
                s = String(s.dropFirst().dropLast())
            }
            return s
        }
        guard partes.count >= 2, partes.allSatisfy({ !$0.isEmpty && $0.count <= 40 }) else { return nil }
        return partes
    }
}
