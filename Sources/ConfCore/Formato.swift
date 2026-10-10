import Foundation

/// Formatos de arquivo que o núcleo sabe ler e gravar.
///
/// Cada formato tem o seu leitor (que guarda o intervalo de bytes de cada valor)
/// e o seu jeito de escrever um valor novo imitando o estilo do antigo; o resto
/// (edição, gravação só dos trechos alterados, campos da tela) é comum.
public enum Formato: String, Sendable, Hashable, CaseIterable {
    case toml
    /// JSON (RFC 8259) e JSONC (JSON com comentários `//` e `/* */` e vírgula final).
    case json
    /// Variáveis de ambiente `CHAVE=valor` (`.env`, `.env.local`, `producao.env`).
    case env

    /// Formato pela extensão do arquivo (sem o ponto, qualquer caixa).
    public init?(extensao: String) {
        switch extensao.lowercased() {
        case "toml": self = .toml
        case "json", "jsonc": self = .json
        case "env": self = .env
        default: return nil
        }
    }

    /// Formato pelo nome do arquivo. Primeiro a extensão; depois os nomes de `.env`,
    /// que muitas vezes não têm extensão que o sistema reconheça: o macOS dá
    /// `pathExtension` vazio para `.env` e `local` para `.env.local`.
    public init?(nomeArquivo: String) {
        let n = nomeArquivo.lowercased()
        let ext = (n as NSString).pathExtension
        if n.hasPrefix(".") && !n.dropFirst().contains(".") {
            // `.env`, `.toml`: o nome inteiro é a "extensão" (`pathExtension` é vazio)
            if let f = Formato(extensao: String(n.dropFirst())) { self = f; return }
        }
        if let f = Formato(extensao: ext), !(n.hasPrefix(".env.") && f != .env) {
            self = f
            return
        }
        if n == ".env" || n.hasPrefix(".env.") || n.hasSuffix(".env") {
            self = .env
            return
        }
        return nil
    }

    public var nome: String {
        switch self {
        case .toml: return "TOML"
        case .json: return "JSON"
        case .env: return ".env"
        }
    }

    /// Lê um arquivo inteiro. JSON aceita também comentários e vírgula final (JSONC).
    public func ler(_ bytes: [UInt8]) throws(ErroLeitura) -> DocumentoConf {
        switch self {
        case .toml: return try Leitor.ler(bytes)
        case .json: return try LeitorJSON.ler(bytes)
        case .env: return try LeitorEnv.ler(bytes)
        }
    }

    /// Lê um valor isolado, como `[1, 2]` ou `"abc"`.
    public func lerValor(_ texto: String) throws(ErroLeitura) -> Valor {
        switch self {
        case .toml: return try Leitor.lerValor(texto)
        case .json: return try LeitorJSON.lerValor(texto)
        case .env: return try LeitorEnv.lerValor(texto)
        }
    }

    /// Escreve um valor imitando o estilo do valor antigo (aspas, escapes, base, forma do número…).
    public func escrever(_ v: Valor, antigo: Valor? = nil, posicao: Posicao? = nil, fonte: [UInt8] = [],
                         quebra: String = "\n") -> String {
        switch self {
        case .toml: return Formatar.valor(v, antigo: antigo, posicao: posicao, fonte: fonte, quebra: quebra)
        case .json: return FormatarJSON.valor(v, antigo: antigo, posicao: posicao, fonte: fonte, quebra: quebra)
        case .env: return FormatarEnv.valor(v, posicao: posicao, fonte: fonte, quebra: quebra)
        }
    }

    /// Motivo pelo qual o valor não pode ser escrito neste formato, ou `nil` se pode.
    public func problema(_ v: Valor) -> String? {
        switch self {
        case .toml:
            if case .nulo = v { return "TOML não tem valor nulo" }
        case .json:
            switch v {
            case .decimal(let d) where !d.isFinite: return "JSON não aceita \(Formatar.decimal(d))"
            case .dataHora: return "JSON não tem tipo de data"
            default: break
            }
        case .env:
            if case .texto = v { return nil }
            return "em .env todo valor é texto"
        }
        switch v {
        case .lista(let l): return l.lazy.compactMap { problema($0) }.first
        case .tabela(let t): return t.pares.lazy.compactMap { problema($0.valor) }.first
        default: return nil
        }
    }
}
