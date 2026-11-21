import KeyshiftCore
import SwiftUI

/// Name, where the rule applies, text-field condition and passthrough modifiers.
struct RuleEditorSheet: View {
    @ObservedObject private var model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    let target: RuleSheetTarget
    let onSave: (Rule) -> Void

    @State private var draft: Rule
    @State private var showAdvanced = false

    init(target: RuleSheetTarget, onSave: @escaping (Rule) -> Void) {
        self.target = target
        self.onSave = onSave
        _draft = State(initialValue: target.rule)
        _showAdvanced = State(initialValue: target.rule.passthrough != [.shift])
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(target.isNew ? String(localized: "New Rule") : String(localized: "Edit Rule"))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField(String(localized: "Name"), text: $draft.name, prompt: Text("e.g. Windows shortcuts"))
                }
                Section {
                    Picker(String(localized: "Where"), selection: $draft.scope.kind) {
                        Text("Everywhere").tag(AppScope.Kind.everywhere)
                        Text("Only in these apps").tag(AppScope.Kind.only)
                        Text("Everywhere except these apps").tag(AppScope.Kind.except)
                    }
                    .pickerStyle(.radioGroup)
                    if draft.scope.kind != .everywhere {
                        AppListEditor(apps: $draft.scope.apps)
                    }
                } header: {
                    Text("Where should it work?")
                }
                Section {
                    Picker(String(localized: "When typing in a text field"), selection: $draft.focus) {
                        Text(UIText.name(FocusCondition.any)).tag(FocusCondition.any)
                        Text(UIText.name(FocusCondition.textInput)).tag(FocusCondition.textInput)
                        Text(UIText.name(FocusCondition.notTextInput)).tag(FocusCondition.notTextInput)
                    }
                    .pickerStyle(.segmented)
                    Text(focusHelp).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup(String(localized: "Advanced"), isExpanded: $showAdvanced) {
                        PassthroughEditor(passthrough: $draft.passthrough)
                            .padding(.top, 4)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if draft.scope.kind == .only && draft.scope.apps.isEmpty {
                    Label(String(localized: "Add at least one app, or the rule never applies."), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target.isNew ? String(localized: "Create Rule") : String(localized: "Save")) {
                    var rule = draft
                    rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if rule.scope.kind == .everywhere { rule.scope.apps = [] }
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
    }

    private var focusHelp: String {
        switch draft.focus {
        case .any: return String(localized: "The shortcuts work no matter what is focused.")
        case .textInput: return String(localized: "Only while you are typing in a text field, e.g. Home/End in a document.")
        case .notTextInput: return String(localized: "Only when no text field is focused, e.g. Enter to open a file in Finder.")
        }
    }
}

/// Editable list of scope entries (apps, groups, path fragments) with an add menu.
struct AppListEditor: View {
    @ObservedObject private var model = AppModel.shared
    @Binding var apps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if apps.isEmpty {
                Text("No apps chosen yet.").foregroundStyle(.secondary).font(.callout)
            } else {
                FlowLayoutCompat(apps) { entry in
                    ScopeEntryChip(entry: entry) { apps.removeAll { $0 == entry } }
                }
            }
            AppPickerMenu(excluded: Set(apps), onPick: { entry in
                if !apps.contains(entry) { apps.append(entry) }
            }) {
                Label(String(localized: "Add App"), systemImage: "plus")
            }
        }
    }
}

/// Wraps chips onto multiple lines (macOS 13 has `Layout`, so this uses it directly).
struct FlowLayoutCompat<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Which held modifiers a rule lets through (default Shift), with a one-line explanation.
struct PassthroughEditor: View {
    @Binding var passthrough: Modifiers

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keep these extra keys held")
                .font(.callout.weight(.medium))
            HStack(spacing: 14) {
                ForEach([Modifiers.shift, .control, .option, .command], id: \.rawValue) { flag in
                    Toggle(isOn: Binding(
                        get: { passthrough.contains(flag) },
                        set: { on in if on { passthrough.insert(flag) } else { passthrough.remove(flag) } }
                    )) {
                        Text("\(flagSymbol(flag)) \(UIText.modifierName(flag))")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Text("With Shift checked, Home → ⌘← also makes Shift+Home → Shift+⌘← (select to line start).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func flagSymbol(_ flag: Modifiers) -> String {
        Modifiers.canonical.first { $0.flag == flag }?.symbol ?? ""
    }
}
