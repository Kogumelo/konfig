import AppKit
import SwiftUI
import ConfCore

/// Text mode: the whole file, editable. Only applied to the document if it is valid in the format.
struct TextModeView: View {
    @Bindable var model: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Text", comment: "Text mode title")).font(.title2.bold())
                    Text(NSLocalizedString("The whole file. Takes effect when going back to the Form, clicking Apply or saving.", comment: "Text mode subtitle"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(NSLocalizedString("Discard", comment: "Text mode button")) { model.enterTextMode() }
                    .disabled(!model.draftDiffers)
                    .help(NSLocalizedString("Reverts to the document's text", comment: "Tooltip on the Discard button in Text mode"))
                Button(NSLocalizedString("Apply", comment: "Text mode button")) { model.applyDraft() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.draftDiffers || model.draftError != nil)
                    .help(NSLocalizedString("Applies the text to the document (⌘↩)", comment: "Tooltip on the Apply button in Text mode"))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            CodeEditor(text: $model.draft, errorLine: model.draftError?.line, format: model.format)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
                .padding(.horizontal, 12)

            HStack(spacing: 6) {
                if let e = model.draftError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(String(format: NSLocalizedString("Line %ld, column %ld: %@", comment: "Text mode parse error; line, column, message"), e.line, e.column, e.message))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if let e = model.draftWarning {
                    // YAML with anchors, tags, multiple documents…: valid, but only as text
                    Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                    Text(String(format: NSLocalizedString("Line %ld: %@. When saving, the text is written as is, without the form's checks.", comment: "Text mode warning for text outside the form subset; line, message"), e.line, e.message))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if model.draftDiffers {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text(String(format: NSLocalizedString("Valid %@ — not applied yet", comment: "Text mode status; %@ = format name"), model.draftFormat))
                    if model.draftFormat == "JSONC" && model.session.document?.formatName == "JSON" {
                        Text(NSLocalizedString("· the file was plain JSON; not every program accepts comments or trailing commas", comment: "Text mode note when a JSON file gains JSONC extensions"))
                            .foregroundStyle(.orange)
                    }
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text(String(format: NSLocalizedString("Valid %@", comment: "Text mode status; %@ = format name"), model.draftFormat)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

/// `NSTextView` with a monospaced font, no automatic substitutions and its own undo
/// (keystrokes don't go into the document's undo; "Apply" does).
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var errorLine: Int?
    var format: Format = .toml

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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
        tv.font = Coordinator.source
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = text
        context.coordinator.colorize(tv)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            context.coordinator.undo.removeAllActions()
        }
        if context.coordinator.errorLine != errorLine {
            context.coordinator.errorLine = errorLine
            context.coordinator.colorize(tv)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var errorLine: Int?
        let undo = UndoManager()
        static let source = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

        init(_ p: CodeEditor) { parent = p; errorLine = p.errorLine }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            colorize(tv)
        }

        /// Simple per-line colors: comments, headers, keys, strings and the line with the error.
        func colorize(_ tv: NSTextView) {
            guard let ts = tv.textStorage else { return }
            let s = ts.string as NSString
            ts.beginEditing()
            let everything = NSRange(location: 0, length: s.length)
            ts.setAttributes([.font: Coordinator.source, .foregroundColor: NSColor.textColor], range: everything)
            if parent.format.isJSON { colorizeJSON(s, ts, json5: parent.format == .json5) }
            var number = 0
            var yamlBlock: Int? = nil
            s.enumerateSubstrings(in: everything, options: [.byLines, .substringNotRequired]) { _, r, _, _ in
                number += 1
                // .env uses the same per-line colors: `#` comment, key before the `=`, quoted strings
                if self.parent.format == .ini { self.colorizeINILine(s, r, ts) }
                else if self.parent.format == .yaml { self.colorizeYAMLLine(s, r, ts, &yamlBlock) }
                else if !self.parent.format.isJSON { self.colorizeLine(s, r, ts) }
                if number == self.errorLine {
                    ts.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.15), range: r)
                }
            }
            ts.endEditing()
        }

        /// JSON/JSONC/JSON5: keys in blue, strings in red, `//` and `/* */` comments in gray.
        /// In JSON5, also single-quoted strings and unquoted keys.
        private func colorizeJSON(_ s: NSString, _ ts: NSTextStorage, json5: Bool) {
            let u = Array((s as String).utf16)
            func paint(_ a: Int, _ b: Int, _ c: NSColor) {
                guard b > a else { return }
                ts.addAttribute(.foregroundColor, value: c, range: NSRange(location: a, length: b - a))
            }
            /// Letter, digit, `$`, `_` or non-ASCII: part of an unquoted JSON5 key.
            func ident(_ c: UInt16) -> Bool {
                (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 36 || c == 95 || c > 127
            }
            var i = 0
            while i < u.count {
                let c = u[i]
                if c == 34 || (json5 && c == 39) {                                  // " or '
                    var end = i + 1
                    while end < u.count, u[end] != c, u[end] != 10 {
                        end += u[end] == 92 ? 2 : 1                                 // \ escape (and line continuation)
                    }
                    end = min(end + 1, u.count)
                    // a key if the next character (skipping spaces) is ':'
                    var k = end
                    while k < u.count, u[k] == 32 || u[k] == 9 { k += 1 }
                    paint(i, end, k < u.count && u[k] == 58 ? .systemBlue : .systemRed)
                    i = end
                } else if c == 47, i + 1 < u.count, u[i + 1] == 47 {                // //
                    var end = i
                    while end < u.count, u[end] != 10 { end += 1 }
                    paint(i, end, .secondaryLabelColor)
                    i = end
                } else if c == 47, i + 1 < u.count, u[i + 1] == 42 {                // /*
                    var end = i + 2
                    while end + 1 < u.count, !(u[end] == 42 && u[end + 1] == 47) { end += 1 }
                    end = min(end + 2, u.count)
                    paint(i, end, .secondaryLabelColor)
                    i = end
                } else if json5, ident(c), i == 0 || !ident(u[i - 1]) {             // unquoted key
                    var end = i
                    while end < u.count, ident(u[end]) { end += 1 }
                    var k = end
                    while k < u.count, u[k] == 32 || u[k] == 9 { k += 1 }
                    if k < u.count && u[k] == 58 { paint(i, end, .systemBlue) }
                    i = end
                } else {
                    i += 1
                }
            }
        }

        /// INI, with the rules of `INIReader`: `;` or `#` comment at the start of the line or after
        /// a space (outside quotes), `[section]`, key before the first `=` or `:`, quoted value.
        private func colorizeINILine(_ s: NSString, _ r: NSRange, _ ts: NSTextStorage) {
            let u = Array((s.substring(with: r)).utf16)
            func paint(_ a: Int, _ b: Int, _ c: NSColor, bold: Bool = false) {
                guard b > a else { return }
                let span = NSRange(location: r.location + a, length: b - a)
                ts.addAttribute(.foregroundColor, value: c, range: span)
                if bold {
                    ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold), range: span)
                }
            }
            func space(_ c: UInt16) -> Bool { c == 32 || c == 9 }
            func comment(_ c: UInt16) -> Bool { c == 59 || c == 35 }                // ; #
            var i = 0
            while i < u.count, space(u[i]) { i += 1 }
            guard i < u.count else { return }
            if comment(u[i]) { paint(i, u.count, .secondaryLabelColor); return }
            if u[i] == 91 {                                                         // [section] ; comment
                var k = i + 1
                while k < u.count {
                    if u[k] == 93 {
                        var j = k + 1
                        while j < u.count, space(u[j]) { j += 1 }
                        if j == u.count || comment(u[j]) {
                            paint(i, k + 1, .systemOrange, bold: true)
                            paint(j, u.count, .secondaryLabelColor)
                            return
                        }
                    }
                    k += 1
                }
                return
            }
            guard let sep = u[i...].firstIndex(where: { $0 == 61 || $0 == 58 }) else { return }   // = :
            paint(i, sep, .systemBlue)
            var v = sep + 1
            while v < u.count, space(u[v]) { v += 1 }
            guard v < u.count else { return }
            if u[v] == 34 || u[v] == 39 {                                           // "…" '…'
                var f = v + 1
                while f < u.count, u[f] != u[v] { f += 1 }
                paint(v, min(f + 1, u.count), .systemRed)
                var j = f + 1
                while j < u.count, space(u[j]) { j += 1 }
                if j < u.count, comment(u[j]) { paint(j, u.count, .secondaryLabelColor) }
                return
            }
            if u[v] == 59 { paint(v, u.count, .secondaryLabelColor); return }
            var j = v + 1
            while j < u.count {
                if comment(u[j]), space(u[j - 1]) { paint(j, u.count, .secondaryLabelColor); return }
                j += 1
            }
        }

        /// YAML: `#` comment (at the start or after a space, outside quotes) in gray, key before
        /// `: ` in blue, quoted strings and the content of `|`/`>` blocks in red, `---` and
        /// `...` in orange. `block` holds the indentation of the line that opened a `|`/`>` block: the
        /// following lines with greater indentation are text, not keys or comments.
        private func colorizeYAMLLine(_ s: NSString, _ r: NSRange, _ ts: NSTextStorage, _ block: inout Int?) {
            let u = Array((s.substring(with: r)).utf16)
            func paint(_ a: Int, _ b: Int, _ c: NSColor, bold: Bool = false) {
                guard b > a else { return }
                let span = NSRange(location: r.location + a, length: b - a)
                ts.addAttribute(.foregroundColor, value: c, range: span)
                if bold {
                    ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold), range: span)
                }
            }
            func space(_ c: UInt16) -> Bool { c == 32 || c == 9 }
            var i = 0
            while i < u.count, u[i] == 32 { i += 1 }
            let indent = i
            while i < u.count, space(u[i]) { i += 1 }
            if let b = block {
                if i == u.count { return }                                      // blank line inside the block
                if indent > b { paint(i, u.count, .systemRed); return }
                block = nil
            }
            guard i < u.count else { return }
            if u[i] == 35 { paint(i, u.count, .secondaryLabelColor); return }   // #
            if indent == 0, u.count >= 3, (u[0] == 45 && u[1] == 45 && u[2] == 45) || (u[0] == 46 && u[1] == 46 && u[2] == 46),
               u.count == 3 || space(u[3]) {
                paint(0, 3, .systemOrange, bold: true)
                i = 3
            }
            // `- ` of sequences
            while i + 1 < u.count, u[i] == 45, space(u[i + 1]) {
                i += 2
                while i < u.count, space(u[i]) { i += 1 }
            }
            var k = i
            var quote: UInt16 = 0
            var keyDone = false
            var valueStart = i
            while k < u.count {
                let c = u[k]
                if quote != 0 {
                    if quote == 34 && c == 92 { k += 2; continue }                // \ escape
                    if c == quote {
                        if quote == 39 && k + 1 < u.count && u[k + 1] == 39 { k += 2; continue }
                        quote = 0
                    }
                    k += 1
                    continue
                }
                if (c == 34 || c == 39) && (k == valueStart || space(u[k - 1]) || u[k - 1] == 91 || u[k - 1] == 123 || u[k - 1] == 44) {
                    var f = k + 1
                    while f < u.count {
                        if c == 34 && u[f] == 92 { f += 2; continue }
                        if u[f] == c {
                            if c == 39 && f + 1 < u.count && u[f + 1] == 39 { f += 2; continue }
                            break
                        }
                        f += 1
                    }
                    f = min(f + 1, u.count)
                    var j = f
                    while j < u.count, space(u[j]) { j += 1 }
                    let isKey = !keyDone && j < u.count && u[j] == 58
                    paint(k, f, isKey ? .systemBlue : .systemRed)
                    if f >= u.count, !isKey, c != 0 { quote = 0 }
                    k = f
                    continue
                }
                if c == 35, k > 0, space(u[k - 1]) { paint(k, u.count, .secondaryLabelColor); break }   // # comment
                if c == 58, !keyDone, k + 1 >= u.count || space(u[k + 1]) {                      // key:
                    paint(i, k, .systemBlue)
                    keyDone = true
                    valueStart = k + 1
                    while valueStart < u.count, space(u[valueStart]) { valueStart += 1 }
                }
                if (c == 124 || c == 62) && k == valueStart {                                      // | >
                    var j = k + 1
                    while j < u.count, u[j] == 43 || u[j] == 45 || (u[j] >= 49 && u[j] <= 57) { j += 1 }
                    while j < u.count, space(u[j]) { j += 1 }
                    if j == u.count || u[j] == 35 { block = indent }
                }
                k += 1
            }
        }

        private func colorizeLine(_ s: NSString, _ r: NSRange, _ ts: NSTextStorage) {
            let u = Array((s.substring(with: r)).utf16)
            var i = 0
            while i < u.count, u[i] == 32 || u[i] == 9 { i += 1 }
            guard i < u.count else { return }
            func paint(_ a: Int, _ b: Int, _ c: NSColor, bold: Bool = false) {
                guard b > a else { return }
                ts.addAttribute(.foregroundColor, value: c, range: NSRange(location: r.location + a, length: b - a))
                if bold {
                    ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold),
                                    range: NSRange(location: r.location + a, length: b - a))
                }
            }
            if u[i] == 35 { paint(i, u.count, .secondaryLabelColor); return }        // #
            var inside: UInt16? = nil
            var k = i
            var afterEquals = u[i] == 91                                          // [
            let keyStart = i
            while k < u.count {
                let c = u[k]
                if let q = inside {
                    if c == 92 && q == 34 { k += 2; continue }                      // \ escape
                    if c == q {
                        inside = nil
                    }
                    k += 1
                    continue
                }
                if c == 34 || c == 39 {
                    if afterEquals {
                        var end = k + 1
                        while end < u.count {
                            if u[end] == 92 && c == 34 { end += 2; continue }
                            if u[end] == c { end += 1; break }
                            end += 1
                        }
                        paint(k, min(end, u.count), .systemRed)
                        k = min(end, u.count)
                        continue
                    }
                    inside = c
                } else if c == 61 && !afterEquals {                               // =
                    paint(keyStart, k, .systemBlue)
                    afterEquals = true
                } else if c == 35 {                                                 // # at the end
                    paint(k, u.count, .secondaryLabelColor)
                    break
                }
                k += 1
            }
            if u[i] == 91 {
                var end = i
                while end < u.count, u[end] != 35 { end += 1 }
                paint(i, end, .systemOrange, bold: true)
            }
        }
    }
}
