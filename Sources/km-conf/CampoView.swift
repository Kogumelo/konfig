import AppKit
import SwiftUI
import ConfCore

/// Uma linha do formulário: rótulo, tipo, ajuda e o controle do tipo certo.
struct CampoView: View {
    let campo: Campo
    let modelo: ModeloJanela

    var alterado: Bool { modelo.alterados.contains(campo.id) }

    var body: some View {
        LabeledContent {
            controle
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(campo.rotulo)
                    Text(campo.tipo.nome)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if alterado {
                        Text("alterado")
                            .font(.caption2.bold())
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.tint, lineWidth: 1))
                    }
                }
                if let a = campo.ajuda {
                    Text(a).font(.caption).foregroundStyle(.secondary)
                }
            }
            .help("\(campo.caminho.texto) · linha \(campo.linha)")
        }
    }

    func definir(_ v: Valor) { modelo.definir(campo, .valor(v)) }

    @ViewBuilder var controle: some View {
        let v = modelo.valor(campo)
        switch (campo.tipo, v) {
        case (.texto, .texto(let s)):
            CaixaTexto(atual: s, varias: s.contains("\n"), validar: { _ in nil }) { definir(.texto($0)) }
        case (.escolha(let ops), .texto(let s)):
            Picker("", selection: Binding(get: { s }, set: { definir(.texto($0)) })) {
                ForEach(ops.contains(s) ? ops : [s] + ops, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
        case (.inteiro, .inteiro(let n)):
            CaixaTexto(atual: String(n), largura: 140, validar: { Conversao.inteiro($0).erro }) {
                if let n = Conversao.inteiro($0).valor { definir(.inteiro(n)) }
            }
        case (.decimal, .decimal(let d)):
            CaixaTexto(atual: Formatar.decimal(d), largura: 140, validar: { Conversao.decimal($0).erro }) {
                if let d = Conversao.decimal($0).valor { definir(.decimal(d)) }
            }
        case (.booleano, .booleano(let b)):
            Toggle("", isOn: Binding(get: { b }, set: { definir(.booleano($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
        case (.data, .dataHora(let dh)):
            CampoData(atual: dh) { definir(.dataHora($0)) }
        case (.lista(let t), .lista(let itens)):
            CampoLista(itens: itens, tipo: t) { definir(.lista($0)) }
        default:
            // .cru, ou valor de tipo diferente do original vindo de texto cru
            CaixaTexto(atual: modelo.textoCru(campo), varias: true, monoespacada: true, largura: 300,
                       validar: { s in
                           do { _ = try Leitor.lerValor(s); return nil } catch { return "\(error)" }
                       }) { modelo.definir(campo, .cru($0)) }
        }
    }
}

/// Converte o que se digita em valores, com mensagens em português.
enum Conversao {
    static func inteiro(_ s: String) -> (valor: Int64?, erro: String?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if case .inteiro(let n)? = try? Leitor.lerValor(t) { return (n, nil) }
        return (nil, "inteiro inválido")
    }

    static func decimal(_ s: String) -> (valor: Double?, erro: String?) {
        var t = s.trimmingCharacters(in: .whitespaces)
        if !t.contains("."), t.filter({ $0 == "," }).count == 1 { t = t.replacingOccurrences(of: ",", with: ".") }
        switch try? Leitor.lerValor(t) {
        case .decimal(let d)?: return (d, nil)
        case .inteiro(let n)?: return (Double(n), nil)
        default: return (nil, "decimal inválido")
        }
    }
}

/// Caixa de texto que só confirma ao apertar Return ou sair do campo.
struct CaixaTexto: View {
    let atual: String
    var varias = false
    var monoespacada = false
    var largura: CGFloat = 240
    let validar: (String) -> String?
    let confirmar: (String) -> Void

    @State private var rascunho = ""
    @State private var erro: String?
    @FocusState private var foco: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Group {
                if varias {
                    TextField("", text: $rascunho, axis: .vertical)
                        .lineLimit(1...10)
                } else {
                    TextField("", text: $rascunho)
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(monoespacada ? .body.monospaced() : .body)
            .frame(width: largura)
            .focused($foco)
            .onSubmit(confirma)
            .onExitCommand { rascunho = atual; erro = nil }
            if let erro {
                Text(erro)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: largura, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { rascunho = atual }
        .onChange(of: atual) { _, novo in rascunho = novo; erro = nil }
        .onChange(of: foco) { _, f in if !f { confirma() } }
        .onDisappear { if rascunho != atual && validar(rascunho) == nil { confirmar(rascunho) } }
    }

    func confirma() {
        guard rascunho != atual else { erro = nil; return }
        if let e = validar(rascunho) { erro = e; return }
        erro = nil
        confirmar(rascunho)
    }
}

/// Os quatro tipos de data/hora do TOML num `DatePicker`.
struct CampoData: View {
    let atual: DataHora
    let confirmar: (DataHora) -> Void

    var fuso: TimeZone {
        atual.tipo == .comFuso ? TimeZone(secondsFromGMT: atual.fusoMinutos * 60) ?? .gmt : .gmt
    }

    var calendario: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = fuso
        return c
    }

    var elementos: NSDatePicker.ElementFlags {
        switch atual.tipo {
        case .comFuso, .local: return [.yearMonthDay, .hourMinuteSecond]
        case .data: return .yearMonthDay
        case .hora: return .hourMinuteSecond
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            SeletorData(data: paraData(), elementos: elementos, fuso: fuso, calendario: calendario) {
                confirmar(deData($0))
            }
            .fixedSize()
            if atual.tipo == .comFuso {
                Text(atual.fusoZ && atual.fusoMinutos == 0 ? "UTC" : String(atual.iso.suffix(6)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help("Fuso do arquivo (mantido ao gravar)")
            }
        }
    }

    func paraData() -> Date {
        var c = DateComponents()
        c.year = atual.temData ? max(1, atual.ano) : 2000
        c.month = atual.temData ? atual.mes : 1
        c.day = atual.temData ? atual.dia : 1
        c.hour = atual.hora
        c.minute = atual.minuto
        c.second = min(atual.segundo, 59)
        return calendario.date(from: c) ?? Date()
    }

    func deData(_ d: Date) -> DataHora {
        let c = calendario.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        var n = atual
        if n.temData {
            n.ano = c.year ?? n.ano; n.mes = c.month ?? n.mes; n.dia = c.day ?? n.dia
        }
        if n.temHora {
            n.hora = c.hour ?? n.hora; n.minuto = c.minute ?? n.minuto
            let s = c.second ?? n.segundo
            if s != min(n.segundo, 59) { n.segundo = s }
        }
        return n
    }
}

/// `NSDatePicker` (o do SwiftUI no Mac não mostra segundos).
struct SeletorData: NSViewRepresentable {
    var data: Date
    var elementos: NSDatePicker.ElementFlags
    var fuso: TimeZone
    var calendario: Calendar
    var mudou: (Date) -> Void

    func makeCoordinator() -> Alvo { Alvo() }

    func makeNSView(context: Context) -> NSDatePicker {
        let p = NSDatePicker()
        p.datePickerStyle = .textFieldAndStepper
        p.isBezeled = true
        p.target = context.coordinator
        p.action = #selector(Alvo.mudou(_:))
        return p
    }

    func updateNSView(_ p: NSDatePicker, context: Context) {
        context.coordinator.mudou = mudou
        p.datePickerElements = elementos
        p.timeZone = fuso
        p.calendar = calendario
        p.locale = Locale(identifier: "pt_BR")
        if p.dateValue != data { p.dateValue = data }
    }

    final class Alvo: NSObject {
        var mudou: ((Date) -> Void)?
        @objc func mudou(_ p: NSDatePicker) { mudou?(p.dateValue) }
    }
}

/// Lista simples como etiquetas, com adicionar e remover.
struct CampoLista: View {
    let itens: [Valor]
    let tipo: TipoValor
    let confirmar: ([Valor]) -> Void

    @State private var novo = ""
    @State private var erro: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                if !itens.isEmpty {
                    Fluxo(espaco: 4) {
                        ForEach(Array(itens.enumerated()), id: \.offset) { i, v in
                            etiqueta(v) {
                                var l = itens
                                l.remove(at: i)
                                confirmar(l)
                            }
                        }
                    }
                }
                TextField("+ adicionar", text: $novo)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .onSubmit(adicionar)
            }
            .padding(5)
            .frame(width: 280, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
            if let erro {
                Text(erro).font(.caption).foregroundStyle(.red)
            }
        }
    }

    func etiqueta(_ v: Valor, remover: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Text(rotulo(v)).font(.callout.monospaced())
            Button(action: remover) {
                Image(systemName: "xmark").font(.caption2.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remover \(rotulo(v))")
        }
        .padding(.leading, 6).padding(.trailing, 4).padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }

    func rotulo(_ v: Valor) -> String {
        if case .texto(let s) = v { return s }
        return Formatar.valor(v)
    }

    func adicionar() {
        let t = novo.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var v: Valor?
        switch tipo {
        case .texto: v = .texto(novo)
        case .inteiro: v = Conversao.inteiro(t).valor.map(Valor.inteiro)
        case .decimal: v = Conversao.decimal(t).valor.map(Valor.decimal)
        default:
            if let x = try? Leitor.lerValor(t), x.tipo == tipo { v = x }
        }
        guard let v else { erro = "não é \(tipo.nome)"; return }
        erro = nil
        novo = ""
        confirmar(itens + [v])
    }
}

/// Distribui as etiquetas em linhas, quebrando quando não cabe.
struct Fluxo: Layout {
    var espaco: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let largura = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, alturaLinha: CGFloat = 0, maior: CGFloat = 0
        for s in subviews {
            let t = s.sizeThatFits(.unspecified)
            if x > 0 && x + t.width > largura { x = 0; y += alturaLinha + espaco; alturaLinha = 0 }
            x += t.width + espaco
            maior = max(maior, x - espaco)
            alturaLinha = max(alturaLinha, t.height)
        }
        return CGSize(width: min(largura, maior), height: y + alturaLinha)
    }

    func placeSubviews(in r: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = r.minX, y = r.minY, alturaLinha: CGFloat = 0
        for s in subviews {
            let t = s.sizeThatFits(.unspecified)
            if x > r.minX && x + t.width > r.maxX { x = r.minX; y += alturaLinha + espaco; alturaLinha = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(t))
            x += t.width + espaco
            alturaLinha = max(alturaLinha, t.height)
        }
    }
}
