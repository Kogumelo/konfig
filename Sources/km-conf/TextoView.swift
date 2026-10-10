import AppKit
import SwiftUI
import ConfCore

/// Modo Texto: o arquivo inteiro editável. Só é aplicado ao documento se for válido no formato.
struct TextoView: View {
    @Bindable var modelo: ModeloJanela

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Texto").font(.title2.bold())
                    Text("O arquivo inteiro. Vale ao voltar para o Formulário, ao clicar em Aplicar ou ao salvar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Descartar") { modelo.entrarModoTexto() }
                    .disabled(!modelo.rascunhoDifere)
                    .help("Volta ao texto do documento")
                Button("Aplicar") { modelo.aplicarRascunho() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!modelo.rascunhoDifere || modelo.erroRascunho != nil)
                    .help("Aplica o texto ao documento (⌘↩)")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            EditorTexto(texto: $modelo.rascunho, linhaErro: modelo.erroRascunho?.linha, formato: modelo.formato)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
                .padding(.horizontal, 12)

            HStack(spacing: 6) {
                if let e = modelo.erroRascunho {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Linha \(e.linha), coluna \(e.coluna): \(e.mensagem)")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if modelo.rascunhoDifere {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text("\(modelo.formatoRascunho) válido — ainda não aplicado")
                    if modelo.formatoRascunho == "JSONC" && modelo.edicao.documento?.nomeFormato == "JSON" {
                        Text("· o arquivo era JSON puro; nem todo programa aceita comentário ou vírgula final")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text("\(modelo.formatoRascunho) válido").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

/// `NSTextView` com fonte monoespaçada, sem substituições automáticas e com desfazer próprio
/// (as digitações não entram no desfazer do documento; o "Aplicar" entra).
struct EditorTexto: NSViewRepresentable {
    @Binding var texto: String
    var linhaErro: Int?
    var formato: Formato = .toml

    func makeCoordinator() -> Coordenador { Coordenador(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = Coordenador.fonte
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = texto
        context.coordinator.colorir(tv)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.pai = self
        guard let tv = sv.documentView as? NSTextView else { return }
        if tv.string != texto {
            tv.string = texto
            context.coordinator.desfazer.removeAllActions()
        }
        if context.coordinator.linhaErro != linhaErro {
            context.coordinator.linhaErro = linhaErro
            context.coordinator.colorir(tv)
        }
    }

    final class Coordenador: NSObject, NSTextViewDelegate {
        var pai: EditorTexto
        var linhaErro: Int?
        let desfazer = UndoManager()
        static let fonte = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

        init(_ p: EditorTexto) { pai = p; linhaErro = p.linhaErro }

        func undoManager(for view: NSTextView) -> UndoManager? { desfazer }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            pai.texto = tv.string
            colorir(tv)
        }

        /// Cores simples por linha: comentários, cabeçalhos, chaves, textos e a linha com erro.
        func colorir(_ tv: NSTextView) {
            guard let ts = tv.textStorage else { return }
            let s = ts.string as NSString
            ts.beginEditing()
            let tudo = NSRange(location: 0, length: s.length)
            ts.setAttributes([.font: Coordenador.fonte, .foregroundColor: NSColor.textColor], range: tudo)
            if pai.formato.ehJSON { colorirJSON(s, ts, json5: pai.formato == .json5) }
            var numero = 0
            s.enumerateSubstrings(in: tudo, options: [.byLines, .substringNotRequired]) { _, r, _, _ in
                numero += 1
                // .env usa as mesmas cores por linha: `#` comentário, chave antes do `=`, textos entre aspas
                if !self.pai.formato.ehJSON { self.colorirLinha(s, r, ts) }
                if numero == self.linhaErro {
                    ts.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.15), range: r)
                }
            }
            ts.endEditing()
        }

        /// JSON/JSONC/JSON5: chaves em azul, textos em vermelho, comentários `//` e `/* */` em cinza.
        /// Em JSON5, também textos com aspas simples e chaves sem aspas.
        private func colorirJSON(_ s: NSString, _ ts: NSTextStorage, json5: Bool) {
            let u = Array((s as String).utf16)
            func pinta(_ a: Int, _ b: Int, _ c: NSColor) {
                guard b > a else { return }
                ts.addAttribute(.foregroundColor, value: c, range: NSRange(location: a, length: b - a))
            }
            /// Letra, dígito, `$`, `_` ou não-ASCII: parte de uma chave JSON5 sem aspas.
            func ident(_ c: UInt16) -> Bool {
                (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 36 || c == 95 || c > 127
            }
            var i = 0
            while i < u.count {
                let c = u[i]
                if c == 34 || (json5 && c == 39) {                                  // " ou '
                    var fim = i + 1
                    while fim < u.count, u[fim] != c, u[fim] != 10 {
                        fim += u[fim] == 92 ? 2 : 1                                 // \ escape (e continuação de linha)
                    }
                    fim = min(fim + 1, u.count)
                    // chave se o próximo caractere (fora espaços) for ':'
                    var k = fim
                    while k < u.count, u[k] == 32 || u[k] == 9 { k += 1 }
                    pinta(i, fim, k < u.count && u[k] == 58 ? .systemBlue : .systemRed)
                    i = fim
                } else if c == 47, i + 1 < u.count, u[i + 1] == 47 {                // //
                    var fim = i
                    while fim < u.count, u[fim] != 10 { fim += 1 }
                    pinta(i, fim, .secondaryLabelColor)
                    i = fim
                } else if c == 47, i + 1 < u.count, u[i + 1] == 42 {                // /*
                    var fim = i + 2
                    while fim + 1 < u.count, !(u[fim] == 42 && u[fim + 1] == 47) { fim += 1 }
                    fim = min(fim + 2, u.count)
                    pinta(i, fim, .secondaryLabelColor)
                    i = fim
                } else if json5, ident(c), i == 0 || !ident(u[i - 1]) {             // chave sem aspas
                    var fim = i
                    while fim < u.count, ident(u[fim]) { fim += 1 }
                    var k = fim
                    while k < u.count, u[k] == 32 || u[k] == 9 { k += 1 }
                    if k < u.count && u[k] == 58 { pinta(i, fim, .systemBlue) }
                    i = fim
                } else {
                    i += 1
                }
            }
        }

        private func colorirLinha(_ s: NSString, _ r: NSRange, _ ts: NSTextStorage) {
            let u = Array((s.substring(with: r)).utf16)
            var i = 0
            while i < u.count, u[i] == 32 || u[i] == 9 { i += 1 }
            guard i < u.count else { return }
            func pinta(_ a: Int, _ b: Int, _ c: NSColor, negrito: Bool = false) {
                guard b > a else { return }
                ts.addAttribute(.foregroundColor, value: c, range: NSRange(location: r.location + a, length: b - a))
                if negrito {
                    ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold),
                                    range: NSRange(location: r.location + a, length: b - a))
                }
            }
            if u[i] == 35 { pinta(i, u.count, .secondaryLabelColor); return }        // #
            var dentro: UInt16? = nil
            var k = i
            var depoisDoIgual = u[i] == 91                                          // [
            let inicioChave = i
            while k < u.count {
                let c = u[k]
                if let q = dentro {
                    if c == 92 && q == 34 { k += 2; continue }                      // \ escape
                    if c == q {
                        dentro = nil
                    }
                    k += 1
                    continue
                }
                if c == 34 || c == 39 {
                    if depoisDoIgual {
                        var fim = k + 1
                        while fim < u.count {
                            if u[fim] == 92 && c == 34 { fim += 2; continue }
                            if u[fim] == c { fim += 1; break }
                            fim += 1
                        }
                        pinta(k, min(fim, u.count), .systemRed)
                        k = min(fim, u.count)
                        continue
                    }
                    dentro = c
                } else if c == 61 && !depoisDoIgual {                               // =
                    pinta(inicioChave, k, .systemBlue)
                    depoisDoIgual = true
                } else if c == 35 {                                                 // # no fim
                    pinta(k, u.count, .secondaryLabelColor)
                    break
                }
                k += 1
            }
            if u[i] == 91 {
                var fim = i
                while fim < u.count, u[fim] != 35 { fim += 1 }
                pinta(i, fim, .systemOrange, negrito: true)
            }
        }
    }
}
