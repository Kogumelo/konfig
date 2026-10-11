import AppKit
import SwiftUI
import ConfCore

/// One row of the form: label, kind, help and the control for the right kind.
struct FieldView: View {
    let field: Field
    let model: WindowModel

    var isChanged: Bool { model.changed.contains(field.id) }

    var body: some View {
        LabeledContent {
            control
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(field.label)
                    Text(field.value == .null ? NSLocalizedString("null", comment: "Value kind shown next to a field label") : field.kind.name(at: model.format))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if isChanged {
                        Text(NSLocalizedString("changed", comment: "Badge next to a field changed since opening/saving"))
                            .font(.caption2.bold())
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.tint, lineWidth: 1))
                    }
                }
                if let a = field.help {
                    Text(a).font(.caption).foregroundStyle(.secondary)
                }
            }
            .help(String(format: NSLocalizedString("%@ · line %ld", comment: "Field label tooltip; %@ = key path, %ld = line number"), field.path.text, field.line))
        }
    }

    func assign(_ v: Value) { model.assign(field, .value(v)) }

    @ViewBuilder var control: some View {
        let v = model.value(field)
        let conv = Conversion(format: model.format)
        switch (field.kind, v) {
        case (.text, .text(let s)):
            TextBox(current: s, several: s.contains("\n"), validate: { _ in nil }) { assign(.text($0)) }
        case (.choice(let opts), .text(let s)):
            Picker("", selection: Binding(get: { s }, set: { assign(.text($0)) })) {
                ForEach(opts.contains(s) ? opts : [s] + opts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
        case (.integer, .integer(let n)):
            TextBox(current: String(n), width: 140, validate: { conv.integer($0).error }) {
                if let n = conv.integer($0).value { assign(.integer(n)) }
            }
        case (.decimal, .decimal(let d)):
            TextBox(current: TOMLFormat.decimal(d), width: 140, validate: { conv.decimal($0).error }) {
                if let d = conv.decimal($0).value { assign(.decimal(d)) }
            }
        case (.boolean, .boolean(let b)):
            Toggle("", isOn: Binding(get: { b }, set: { assign(.boolean($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
        case (.date, .dateTime(let dh)):
            DateField(current: dh) { assign(.dateTime($0)) }
        case (.array(let t), .array(let items)):
            ArrayField(items: items, kind: t, format: model.format) { assign(.array($0)) }
        default:
            // .raw, or a value of a different kind than the original, coming from raw text
            TextBox(current: model.rawText(field), several: true, monospacedFont: true, width: 300,
                       validate: { s in
                           do { _ = try model.format.parseValue(s); return nil } catch { return "\(error)" }
                       }) { model.assign(field, .raw($0)) }
        }
    }
}

/// Converts what is typed into values (in the syntax of the file's format), with localized messages.
struct Conversion {
    var format: Format

    func integer(_ s: String) -> (value: Int64?, error: String?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if case .integer(let n)? = try? format.parseValue(t) { return (n, nil) }
        return (nil, NSLocalizedString("invalid integer", comment: "Validation error under a field"))
    }

    func decimal(_ s: String) -> (value: Double?, error: String?) {
        var t = s.trimmingCharacters(in: .whitespaces)
        if !t.contains("."), t.filter({ $0 == "," }).count == 1 { t = t.replacingOccurrences(of: ",", with: ".") }
        switch try? format.parseValue(t) {
        case .decimal(let d)?: return (d, nil)
        case .integer(let n)?: return (Double(n), nil)
        default: return (nil, NSLocalizedString("invalid decimal", comment: "Validation error under a field"))
        }
    }
}

/// Text box that only commits on Return or when leaving the field.
struct TextBox: View {
    let current: String
    var several = false
    var monospacedFont = false
    var width: CGFloat = 240
    let validate: (String) -> String?
    let confirm: (String) -> Void

    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focus: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Group {
                if several {
                    TextField("", text: $draft, axis: .vertical)
                        .lineLimit(1...10)
                } else {
                    TextField("", text: $draft)
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(monospacedFont ? .body.monospaced() : .body)
            .frame(width: width)
            .focused($focus)
            .onSubmit(confirms)
            .onExitCommand { draft = current; error = nil }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: width, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { draft = current }
        .onChange(of: current) { _, updated in draft = updated; error = nil }
        .onChange(of: focus) { _, f in if !f { confirms() } }
        .onDisappear { if draft != current && validate(draft) == nil { confirm(draft) } }
    }

    func confirms() {
        guard draft != current else { error = nil; return }
        if let e = validate(draft) { error = e; return }
        error = nil
        confirm(draft)
    }
}

/// The four TOML date/time kinds in a `DatePicker`.
struct DateField: View {
    let current: DateTime
    let confirm: (DateTime) -> Void

    var zone: TimeZone {
        current.kind == .withOffset ? TimeZone(secondsFromGMT: current.offsetMinutes * 60) ?? .gmt : .gmt
    }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    var elements: NSDatePicker.ElementFlags {
        switch current.kind {
        case .withOffset, .local: return [.yearMonthDay, .hourMinuteSecond]
        case .date: return .yearMonthDay
        case .time: return .hourMinuteSecond
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            DatePickerControl(date: toDate(), elements: elements, zone: zone, calendar: calendar) {
                confirm(fromDate($0))
            }
            .fixedSize()
            if current.kind == .withOffset {
                Text(current.offsetIsZ && current.offsetMinutes == 0 ? "UTC" : String(current.iso.suffix(6)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help(NSLocalizedString("Time zone from the file (kept when saving)", comment: "Tooltip on the UTC offset next to a date field"))
            }
        }
    }

    func toDate() -> Date {
        var c = DateComponents()
        c.year = current.hasDate ? max(1, current.year) : 2000
        c.month = current.hasDate ? current.month : 1
        c.day = current.hasDate ? current.day : 1
        c.hour = current.hour
        c.minute = current.minute
        c.second = min(current.second, 59)
        return calendar.date(from: c) ?? Date()
    }

    func fromDate(_ d: Date) -> DateTime {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        var n = current
        if n.hasDate {
            n.year = c.year ?? n.year; n.month = c.month ?? n.month; n.day = c.day ?? n.day
        }
        if n.hasTime {
            n.hour = c.hour ?? n.hour; n.minute = c.minute ?? n.minute
            let s = c.second ?? n.second
            if s != min(n.second, 59) { n.second = s }
        }
        return n
    }
}

/// `NSDatePicker` (the SwiftUI one on the Mac does not show seconds).
struct DatePickerControl: NSViewRepresentable {
    var date: Date
    var elements: NSDatePicker.ElementFlags
    var zone: TimeZone
    var calendar: Calendar
    var didChange: (Date) -> Void

    func makeCoordinator() -> Target { Target() }

    func makeNSView(context: Context) -> NSDatePicker {
        let p = NSDatePicker()
        p.datePickerStyle = .textFieldAndStepper
        p.isBezeled = true
        p.target = context.coordinator
        p.action = #selector(Target.didChange(_:))
        return p
    }

    func updateNSView(_ p: NSDatePicker, context: Context) {
        context.coordinator.didChange = didChange
        p.datePickerElements = elements
        p.timeZone = zone
        p.calendar = calendar
        p.locale = .autoupdatingCurrent  // date format follows the user's region
        if p.dateValue != date { p.dateValue = date }
    }

    final class Target: NSObject {
        var didChange: ((Date) -> Void)?
        @objc func didChange(_ p: NSDatePicker) { didChange?(p.dateValue) }
    }
}

/// Simple array as tags, with add and remove.
struct ArrayField: View {
    let items: [Value]
    let kind: ValueKind
    let format: Format
    let confirm: ([Value]) -> Void

    @State private var updated = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                if !items.isEmpty {
                    FlowLayout(space: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, v in
                            tag(v) {
                                var l = items
                                l.remove(at: i)
                                confirm(l)
                            }
                        }
                    }
                }
                TextField(NSLocalizedString("+ add", comment: "Placeholder of the box that adds an item to an array field"), text: $updated)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .onSubmit(add)
            }
            .padding(5)
            .frame(width: 280, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    func tag(_ v: Value, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Text(label(v)).font(.callout.monospaced())
            Button(action: remove) {
                Image(systemName: "xmark").font(.caption2.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(format: NSLocalizedString("Remove %@", comment: "Tooltip on an array item's remove button; %@ = the item"), label(v)))
        }
        .padding(.leading, 6).padding(.trailing, 4).padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }

    func label(_ v: Value) -> String {
        if case .text(let s) = v { return s }
        return format.write(v)
    }

    func add() {
        let t = updated.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var v: Value?
        switch kind {
        case .text: v = .text(updated)
        case .integer: v = Conversion(format: format).integer(t).value.map(Value.integer)
        case .decimal: v = Conversion(format: format).decimal(t).value.map(Value.decimal)
        default:
            if let x = try? format.parseValue(t), x.kind == kind { v = x }
        }
        guard let v else { error = String(format: NSLocalizedString("not a %@", comment: "Validation error when adding an array item; %@ = value kind name"), kind.name); return }
        error = nil
        updated = ""
        confirm(items + [v])
    }
}

/// Lays the tags out in rows, wrapping when they don't fit.
struct FlowLayout: Layout {
    var space: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, greater: CGFloat = 0
        for s in subviews {
            let t = s.sizeThatFits(.unspecified)
            if x > 0 && x + t.width > width { x = 0; y += lineHeight + space; lineHeight = 0 }
            x += t.width + space
            greater = max(greater, x - space)
            lineHeight = max(lineHeight, t.height)
        }
        return CGSize(width: min(width, greater), height: y + lineHeight)
    }

    func placeSubviews(in r: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = r.minX, y = r.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let t = s.sizeThatFits(.unspecified)
            if x > r.minX && x + t.width > r.maxX { x = r.minX; y += lineHeight + space; lineHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(t))
            x += t.width + space
            lineHeight = max(lineHeight, t.height)
        }
    }
}
