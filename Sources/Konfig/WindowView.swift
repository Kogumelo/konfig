import SwiftUI
import ConfCore

struct WindowView: View {
    @Bindable var model: WindowModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 320)
        } detail: {
            Group {
                switch model.mode {
                case .form: FormView(model: model)
                case .text: TextModeView(model: model)
                }
            }
            .frame(minWidth: 380)
            .inspector(isPresented: $model.showChanges) {
                ChangesPanel(model: model)
                    .inspectorColumnWidth(min: 220, ideal: 280, max: 460)
            }
            .toolbar { toolbarContent }
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button(action: model.undo) {
                Label(NSLocalizedString("Undo", comment: "Toolbar button"), systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .help(NSLocalizedString("Undo (⌘Z)", comment: "Toolbar help"))
        }
        ToolbarItem {
            Picker(NSLocalizedString("Mode", comment: "Toolbar picker: Form or Text"), selection: Binding(get: { model.mode }, set: { model.switchMode($0) })) {
                Text(NSLocalizedString("Form", comment: "Toolbar picker; Form mode")).tag(Mode.form)
                Text(NSLocalizedString("Text", comment: "Toolbar picker; Text mode")).tag(Mode.text)
            }
            .pickerStyle(.segmented)
            .help(NSLocalizedString("Form (⌘1) or text of the whole file (⌘2)", comment: "Toolbar help"))
        }
        ToolbarItem {
            Button {
                model.showChanges.toggle()
            } label: {
                Label(NSLocalizedString("Changes", comment: "Toolbar button: changes panel"), systemImage: "sidebar.right")
            }
            .help(NSLocalizedString("Show or hide the changes panel (⌥⌘I)", comment: "Toolbar help"))
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var model: WindowModel

    /// Sections standalone or grouped by `[[array]]`, in file order.
    enum Node: Identifiable {
        case section(FormSection)
        case group(String, [FormSection])
        var id: String {
            switch self {
            case .section(let s): return s.id
            case .group(let g, let s): return "group:\(g):\(s.first?.id ?? "")"
            }
        }
    }

    var nodes: [Node] {
        var r: [Node] = []
        for s in model.sections {
            // section nested inside an item of the current group (`[t.sub]`, `tasks[0].environment`): stays in the group
            if case .group(let g, var items)? = r.last, let array = items.first?.path.dropLast(),
               s.path.count > array.count + 1, s.path.starts(with: array) {
                items.append(s)
                r[r.count - 1] = .group(g, items)
                continue
            }
            if let g = s.group {
                if case .group(let current, var items)? = r.last, current == g, s.itemIndex ?? 0 > 0 {
                    items.append(s)
                    r[r.count - 1] = .group(g, items)
                    continue
                }
                r.append(.group(g, [s]))
            } else {
                r.append(.section(s))
            }
        }
        return r
    }

    var body: some View {
        List(selection: $model.selection) {
            Section(model.fileName) {
                if model.preambleComment != nil {
                    Label(NSLocalizedString("About the file", comment: "Sidebar item: the preamble comment page"), systemImage: "text.quote")
                        .tag(WindowModel.preambleID)
                        .help(NSLocalizedString("The comment at the beginning of the file", comment: "Sidebar help"))
                }
                ForEach(nodes) { node in
                    switch node {
                    case .section(let s):
                        line(s, icon: s.id == FormSection.rootID ? "doc" : "tablecells")
                    case .group(let g, let items):
                        HStack {
                            Label(g, systemImage: "list.bullet")
                            Spacer()
                            Text("\(items.first?.totalItems ?? items.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .selectionDisabled()
                        let level = (items.first?.path.count ?? 0)
                        ForEach(items) { s in
                            if s.path.count == level {
                                line(s, icon: nil).padding(.leading, 18)
                            } else {
                                line(s, icon: nil, title: s.group.map { "\($0) › \(s.title)" } ?? s.title)
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if model.jsoncNotice {
                Label(NSLocalizedString("JSON with comments", comment: "Sidebar notice"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .help(NSLocalizedString("This .json has comments or trailing commas (JSONC, like VS Code's settings.json and tsconfig.json). Konfig keeps everything when saving, but not every program that reads JSON accepts this file.", comment: "Sidebar notice help"))
            }
        }
        .overlay {
            if model.sections.isEmpty {
                Text(model.session.textOnly ? NSLocalizedString("Text mode only", comment: "Empty sidebar")
                     : model.session.document == nil ? String(format: NSLocalizedString("File with a %@ error", comment: "Empty sidebar; %@ = format name"), model.format.name) : NSLocalizedString("Empty file", comment: "Empty sidebar / empty form"))
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    func line(_ s: FormSection, icon: String?, title: String? = nil) -> some View {
        HStack {
            if let icon { Label(title ?? s.title, systemImage: icon) } else { Text(title ?? s.title).lineLimit(1) }
            Spacer()
            if s.fields.contains(where: { model.changed.contains($0.id) }) {
                Circle().fill(.tint).frame(width: 6, height: 6).help(NSLocalizedString("Section with unsaved changes", comment: "Sidebar dot help"))
            }
        }
        .tag(s.id)
    }
}

// MARK: - Form

struct FormView: View {
    @Bindable var model: WindowModel

    var body: some View {
        if model.session.document == nil {
            ContentUnavailableView {
                if model.session.textOnly {
                    Label(String(format: NSLocalizedString("This %@ can only be edited as text", comment: "Form placeholder; %@ = format name"), model.format.name), systemImage: "doc.plaintext")
                } else {
                    Label(String(format: NSLocalizedString("The file is not valid %@", comment: "Form placeholder; %@ = format name"), model.format.name), systemImage: "exclamationmark.triangle")
                }
            } description: {
                Text(model.session.error.map { String(format: NSLocalizedString("Line %ld, column %ld: %@", comment: "Parse error position; %ld = line, %ld = column, %@ = message"), $0.line, $0.column, $0.message) } ?? "")
            } actions: {
                Button(model.session.textOnly ? NSLocalizedString("Edit in Text mode", comment: "Form placeholder button") : NSLocalizedString("Fix in Text mode", comment: "Form placeholder button")) { model.switchMode(.text) }
            }
        } else if model.selection == WindowModel.preambleID, let c = model.preambleComment {
            PreamblePage(model: model, comment: c)
        } else if let s = model.selectedSection {
            Form {
                Section {
                    if s.fields.isEmpty {
                        Text(model.format.isJSON
                             ? NSLocalizedString("This object has no values of its own. To create keys, use Text mode.", comment: "Empty section (JSON)")
                             : model.format == .env
                             ? NSLocalizedString("The file has no variables. To create them, use Text mode.", comment: "Empty section (.env)")
                             : model.format == .ini
                             ? NSLocalizedString("This section has no keys. To create them, use Text mode.", comment: "Empty section (INI)")
                             : model.format == .yaml
                             ? NSLocalizedString("This map has no values of its own. To create keys, use Text mode.", comment: "Empty section (YAML)")
                             : NSLocalizedString("This table has no values of its own. To create keys, use Text mode.", comment: "Empty section (TOML)"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(s.fields) { c in
                        FieldView(field: c, model: model)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.group.map { "\($0) › \(s.title)" } ?? s.title)
                            .font(.title2.bold())
                            .foregroundStyle(.primary)
                        Text(subtitle(s))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let a = s.help {
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
            ContentUnavailableView(NSLocalizedString("Empty file", comment: "Empty sidebar / empty form"), systemImage: "doc",
                                   description: Text(NSLocalizedString("Use Text mode to write the content.", comment: "Empty file placeholder")))
        }
    }

    func subtitle(_ s: FormSection) -> String {
        var t = s.subtitle
        if let i = s.itemIndex, let n = s.totalItems { t += String(format: NSLocalizedString(" · item %ld of %ld", comment: "Section subtitle suffix; %ld = position, %ld = total"), i + 1, n) }
        return t
    }
}

/// "About the file": the preamble comment, editable. Takes effect when leaving the box or on Apply;
/// each apply goes into the document's undo (individual keystrokes don't).
struct PreamblePage: View {
    let model: WindowModel
    let comment: String
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var differs: Bool { draft != comment }

    var body: some View {
        Form {
            Section {
                // monospaced, as in the file: the comment's lists and indents stay aligned
                TextEditor(text: $draft)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .focused($isFocused)
                    .onChange(of: isFocused) { _, f in if !f { apply() } }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("About the file", comment: "Sidebar item: the preamble comment page"))
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                    Text(String(format: NSLocalizedString("comment at the beginning of the file, without the %@ on each line", comment: "Preamble page subtitle; %@ = comment marker, e.g. #"), marker))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .textCase(nil)
                .padding(.bottom, 4)
            } footer: {
                HStack {
                    Text(NSLocalizedString("Takes effect when leaving the box or on Apply. Empty text deletes the comment.", comment: "Preamble page footer"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(NSLocalizedString("Discard", comment: "Preamble page button")) { draft = comment }
                        .disabled(!differs)
                    Button(NSLocalizedString("Apply", comment: "Preamble page button"), action: apply)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!differs)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = comment }
        // undo, Text mode or another program changed the comment
        .onChange(of: comment) { _, c in draft = c }
    }

    var marker: String {
        switch model.format {
        case .ini: return NSLocalizedString("; or #", comment: "INI comment markers, shown in %@ of the preamble page subtitle")
        case .json, .json5: return "//"
        default: return "#"
        }
    }

    func apply() {
        guard differs else { return }
        model.setPreamble(draft)
        // only trailing spaces or blank lines at the ends: the file doesn't change, the box reverts
        if model.preambleComment == comment { draft = comment }
    }
}

// MARK: - Changes panel

struct ChangesPanel: View {
    let model: WindowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(NSLocalizedString("UNSAVED CHANGES", comment: "Changes panel header"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if let e = model.saveError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                } else if model.hunks.isEmpty {
                    Text(NSLocalizedString("No changes. The file on disk is the same as what is on screen.", comment: "Changes panel"))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(NSLocalizedString("When saving, only these lines change. A copy of the current file is kept in .bak.", comment: "Changes panel"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.hunks) { t in
                    card(t)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func card(_ t: LabeledHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(t.label ?? NSLocalizedString("text", comment: "Field kind")).bold().lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(String(format: NSLocalizedString("line %ld", comment: "Changes panel card; %ld = line number"), t.hunk.added.isEmpty ? t.hunk.lineBefore : t.hunk.lineAfter))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            ForEach(Array(t.hunk.removed.enumerated()), id: \.offset) { _, l in
                line("- " + l, color: .red)
            }
            ForEach(Array(t.hunk.added.enumerated()), id: \.offset) { _, l in
                line("+ " + l, color: .green)
            }
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            if let r = t.label, let s = model.section(ofField: r) {
                model.selection = s
                if model.mode == .text { model.switchMode(.form) }
            }
        }
        .help(NSLocalizedString("Click to go to the field", comment: "Changes panel card help"))
    }

    func line(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(color.opacity(0.12))
    }
}
