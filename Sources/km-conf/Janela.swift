import SwiftUI
import ConfCore

struct Janela: View {
    @Bindable var modelo: ModeloJanela

    var body: some View {
        NavigationSplitView {
            BarraLateral(modelo: modelo)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 320)
        } detail: {
            Group {
                switch modelo.modo {
                case .formulario: Formulario(modelo: modelo)
                case .texto: TextoView(modelo: modelo)
                }
            }
            .frame(minWidth: 380)
            .inspector(isPresented: $modelo.mostrarAlteracoes) {
                PainelAlteracoes(modelo: modelo)
                    .inspectorColumnWidth(min: 220, ideal: 280, max: 460)
            }
            .toolbar { barra }
        }
    }

    @ToolbarContentBuilder
    var barra: some ToolbarContent {
        ToolbarItem {
            Button(action: modelo.desfazer) {
                Label("Desfazer", systemImage: "arrow.uturn.backward")
            }
            .disabled(!modelo.podeDesfazer)
            .help("Desfazer (⌘Z)")
        }
        ToolbarItem {
            Picker("Modo", selection: Binding(get: { modelo.modo }, set: { modelo.trocarModo($0) })) {
                Text("Formulário").tag(Modo.formulario)
                Text("Texto").tag(Modo.texto)
            }
            .pickerStyle(.segmented)
            .help("Formulário (⌘1) ou texto do arquivo inteiro (⌘2)")
        }
        ToolbarItem {
            Button {
                modelo.mostrarAlteracoes.toggle()
            } label: {
                Label("Alterações", systemImage: "sidebar.right")
            }
            .help("Mostrar ou ocultar o painel de alterações (⌥⌘I)")
        }
    }
}

// MARK: - Barra lateral

struct BarraLateral: View {
    @Bindable var modelo: ModeloJanela

    /// Seções soltas ou agrupadas por `[[lista]]`, na ordem do arquivo.
    enum No: Identifiable {
        case secao(Secao)
        case grupo(String, [Secao])
        var id: String {
            switch self {
            case .secao(let s): return s.id
            case .grupo(let g, let s): return "grupo:\(g):\(s.first?.id ?? "")"
            }
        }
    }

    var nos: [No] {
        var r: [No] = []
        for s in modelo.secoes {
            // seção aninhada dentro de um item do grupo atual (`[t.sub]`, `tarefas[0].ambiente`): fica no grupo
            if case .grupo(let g, var itens)? = r.last, let lista = itens.first?.caminho.dropLast(),
               s.caminho.count > lista.count + 1, s.caminho.starts(with: lista) {
                itens.append(s)
                r[r.count - 1] = .grupo(g, itens)
                continue
            }
            if let g = s.grupo {
                if case .grupo(let atual, var itens)? = r.last, atual == g, s.indiceItem ?? 0 > 0 {
                    itens.append(s)
                    r[r.count - 1] = .grupo(g, itens)
                    continue
                }
                r.append(.grupo(g, [s]))
            } else {
                r.append(.secao(s))
            }
        }
        return r
    }

    var body: some View {
        List(selection: $modelo.selecao) {
            Section(modelo.nomeArquivo) {
                ForEach(nos) { no in
                    switch no {
                    case .secao(let s):
                        linha(s, icone: s.id == "raiz" ? "doc" : "tablecells")
                    case .grupo(let g, let itens):
                        HStack {
                            Label(g, systemImage: "list.bullet")
                            Spacer()
                            Text("\(itens.first?.totalItens ?? itens.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .selectionDisabled()
                        let nivel = (itens.first?.caminho.count ?? 0)
                        ForEach(itens) { s in
                            if s.caminho.count == nivel {
                                linha(s, icone: nil).padding(.leading, 18)
                            } else {
                                linha(s, icone: nil, titulo: s.grupo.map { "\($0) › \(s.titulo)" } ?? s.titulo)
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if modelo.avisoJSONC {
                Label("JSON com comentários", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .help("Este .json tem comentários ou vírgula final (JSONC, como o settings.json do VS Code "
                          + "e o tsconfig.json). O km-conf mantém tudo ao gravar, mas nem todo programa que lê "
                          + "JSON aceita esse arquivo.")
            }
        }
        .overlay {
            if modelo.secoes.isEmpty {
                Text(modelo.edicao.somenteTexto ? "Só no modo Texto"
                     : modelo.edicao.documento == nil ? "Arquivo com erro de \(modelo.formato.nome)" : "Arquivo vazio")
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    func linha(_ s: Secao, icone: String?, titulo: String? = nil) -> some View {
        HStack {
            if let icone { Label(titulo ?? s.titulo, systemImage: icone) } else { Text(titulo ?? s.titulo).lineLimit(1) }
            Spacer()
            if s.campos.contains(where: { modelo.alterados.contains($0.id) }) {
                Circle().fill(.tint).frame(width: 6, height: 6).help("Seção com alterações não salvas")
            }
        }
        .tag(s.id)
    }
}

// MARK: - Formulário

struct Formulario: View {
    @Bindable var modelo: ModeloJanela

    var body: some View {
        if modelo.edicao.documento == nil {
            ContentUnavailableView {
                if modelo.edicao.somenteTexto {
                    Label("Este \(modelo.formato.nome) só pode ser editado como texto", systemImage: "doc.plaintext")
                } else {
                    Label("O arquivo não é \(modelo.formato.nome) válido", systemImage: "exclamationmark.triangle")
                }
            } description: {
                Text(modelo.edicao.erro.map { "Linha \($0.linha), coluna \($0.coluna): \($0.mensagem)" } ?? "")
            } actions: {
                Button(modelo.edicao.somenteTexto ? "Editar no modo Texto" : "Corrigir no modo Texto") { modelo.trocarModo(.texto) }
            }
        } else if let s = modelo.secaoSelecionada {
            Form {
                Section {
                    if s.campos.isEmpty {
                        Text(modelo.formato.ehJSON
                             ? "Este objeto não tem valores próprios. Para criar chaves, use o modo Texto."
                             : modelo.formato == .env
                             ? "O arquivo não tem variáveis. Para criar, use o modo Texto."
                             : modelo.formato == .ini
                             ? "Esta seção não tem chaves. Para criar, use o modo Texto."
                             : modelo.formato == .yaml
                             ? "Este mapa não tem valores próprios. Para criar chaves, use o modo Texto."
                             : "Esta tabela não tem valores próprios. Para criar chaves, use o modo Texto.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(s.campos) { c in
                        CampoView(campo: c, modelo: modelo)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.grupo.map { "\($0) › \(s.titulo)" } ?? s.titulo)
                            .font(.title2.bold())
                            .foregroundStyle(.primary)
                        Text(subtitulo(s))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let a = s.ajuda {
                            Text(a).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
            }
            .formStyle(.grouped)
            .id(s.id)
        } else {
            ContentUnavailableView("Arquivo vazio", systemImage: "doc",
                                   description: Text("Use o modo Texto para escrever o conteúdo."))
        }
    }

    func subtitulo(_ s: Secao) -> String {
        var t = s.subtitulo
        if let i = s.indiceItem, let n = s.totalItens { t += " · item \(i + 1) de \(n)" }
        return t
    }
}

// MARK: - Painel de alterações

struct PainelAlteracoes: View {
    let modelo: ModeloJanela

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("ALTERAÇÕES NÃO SALVAS")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if let e = modelo.erroGravacao {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                } else if modelo.trechos.isEmpty {
                    Text("Nenhuma alteração. O arquivo no disco é igual ao que está na tela.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Ao salvar, só estas linhas mudam. Uma cópia do arquivo atual fica em .bak.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(modelo.trechos) { t in
                    cartao(t)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func cartao(_ t: TrechoRotulado) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(t.rotulo ?? "texto").bold().lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("linha \(t.trecho.adicionadas.isEmpty ? t.trecho.linhaAntes : t.trecho.linhaDepois)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            ForEach(Array(t.trecho.removidas.enumerated()), id: \.offset) { _, l in
                linha("- " + l, cor: .red)
            }
            ForEach(Array(t.trecho.adicionadas.enumerated()), id: \.offset) { _, l in
                linha("+ " + l, cor: .green)
            }
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            if let r = t.rotulo, let s = modelo.secao(doCampo: r) {
                modelo.selecao = s
                if modelo.modo == .texto { modelo.trocarModo(.formulario) }
            }
        }
        .help("Clique para ir ao campo")
    }

    func linha(_ s: String, cor: Color) -> some View {
        Text(s)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(cor)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(cor.opacity(0.12))
    }
}
