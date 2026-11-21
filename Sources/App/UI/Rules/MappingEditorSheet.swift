import KeyshiftConfig
import KeyshiftCore
import SwiftUI

/// Editable form of a mapping's action.
struct ActionDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case sequence, openApp, openURL, shell, system, disable
        var id: String { rawValue }

        var title: String {
            switch self {
            case .openApp: return String(localized: "Open an app")
            case .openURL: return String(localized: "Open a website")
            case .shell: return String(localized: "Run a shell command")
            case .system: return String(localized: "System action")
            case .disable: return String(localized: "Do nothing (disable the key)")
            case .sequence: return String(localized: "Type a sequence of keys")
            }
        }

        var symbol: String {
            switch self {
            case .openApp: return "app.badge"
            case .openURL: return "link"
            case .shell: return "terminal"
            case .system: return "gearshape.2"
            case .disable: return "nosign"
            case .sequence: return "text.line.first.and.arrowtriangle.forward"
            }
        }
    }

    enum Mode: Hashable { case send, doAction }

    var mode: Mode = .send
    var kind: Kind = .openApp
    var send: Trigger?
    var sequence: [Trigger?] = [nil, nil]
    var app = ""
    var url = "https://"
    var shell = ""
    var system: SystemAction = .launchpad

    init() {}

    init(_ action: Action) {
        switch action {
        case .keys(let combos) where combos.count == 1:
            mode = .send
            send = .key(combos[0])
        case .keys(let combos):
            mode = .doAction
            kind = .sequence
            sequence = combos.map { .key($0) }
        case .mouse(let button, let modifiers):
            mode = .send
            send = .mouse(button, modifiers)
        case .openApp(let value):
            mode = .doAction; kind = .openApp; app = value
        case .openURL(let value):
            mode = .doAction; kind = .openURL; url = value
        case .shell(let value):
            mode = .doAction; kind = .shell; shell = value
        case .system(let value):
            mode = .doAction; kind = .system; system = value
        case .none:
            mode = .doAction; kind = .disable
        }
    }

    /// nil while incomplete.
    var action: Action? {
        switch mode {
        case .send:
            switch send {
            case .key(let combo): return .keys([combo])
            case .mouse(let button, let modifiers): return .mouse(button, modifiers)
            case nil: return nil
            }
        case .doAction:
            switch kind {
            case .openApp: return app.isEmpty ? nil : .openApp(app)
            case .openURL:
                let value = url.trimmingCharacters(in: .whitespaces)
                guard let parsed = URL(string: value), parsed.scheme != nil, value != "https://" else { return nil }
                return .openURL(value)
            case .shell:
                let value = shell.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : .shell(value)
            case .system: return .system(system)
            case .disable: return Action.none
            case .sequence:
                let combos: [KeyCombo] = sequence.compactMap {
                    if case .key(let combo) = $0 { return combo }
                    return nil
                }
                return combos.isEmpty ? nil : .keys(combos)
            }
        }
    }
}

/// "When I press" → "Send" / "Do", with live conflict warnings.
struct MappingEditorSheet: View {
    @ObservedObject private var model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    let target: MappingSheetTarget

    @State private var trigger: Trigger?
    @State private var tapAlone: Bool
    @State private var draft: ActionDraft
    private let mappingID: UUID

    init(target: MappingSheetTarget) {
        self.target = target
        mappingID = target.mapping?.id ?? UUID()
        _trigger = State(initialValue: target.mapping?.trigger)
        _tapAlone = State(initialValue: target.mapping?.isTapAlone ?? false)
        _draft = State(initialValue: target.mapping.map { ActionDraft($0.action) } ?? ActionDraft())
    }

    private var isNew: Bool { target.mapping == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isNew ? String(localized: "New Shortcut") : String(localized: "Edit Shortcut")).font(.title3.weight(.semibold))
                if let rule = currentRule {
                    Text("In rule “\(rule.name)”").foregroundStyle(.secondary).font(.callout)
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    triggerSection
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    actionSection
                    warnings
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()
            footer.padding(16)
        }
        .frame(width: 540, height: 580)
        .onChange(of: trigger) { newValue in
            if !(newValue?.isBareModifierKey ?? false) { tapAlone = false }
        }
    }

    // MARK: Sections

    private var triggerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                KeyRecorderField(value: $trigger, allowMouse: true)
                if trigger?.isBareModifierKey == true {
                    Toggle(isOn: $tapAlone) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Only when tapped alone")
                            Text("Pressed and released on its own it does the action below; held with other keys it keeps working as usual.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("When I press").font(.headline)
        }
    }

    private var actionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker(String(localized: "Result"), selection: $draft.mode) {
                    Text("Send keys").tag(ActionDraft.Mode.send)
                    Text("Do something").tag(ActionDraft.Mode.doAction)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch draft.mode {
                case .send:
                    KeyRecorderField(value: $draft.send, allowMouse: true, placeholder: "Click to record the keys to send")
                case .doAction:
                    doActionEditor
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(draft.mode == .send ? String(localized: "Send") : String(localized: "Do")).font(.headline)
        }
    }

    @ViewBuilder private var doActionEditor: some View {
        Picker(String(localized: "Action"), selection: $draft.kind) {
            ForEach(ActionDraft.Kind.allCases) { kind in
                Label(kind.title, systemImage: kind.symbol).tag(kind)
            }
        }
        switch draft.kind {
        case .openApp:
            HStack(spacing: 8) {
                if !draft.app.isEmpty {
                    AppIconView(entry: draft.app, size: 20)
                    Text(model.appDisplayName(for: draft.app)).lineLimit(1)
                }
                Spacer()
                AppPickerMenu(includeGroups: false, onPick: { draft.app = $0 }) {
                    Text(draft.app.isEmpty ? String(localized: "Choose App") : String(localized: "Change"))
                }
            }
        case .openURL:
            TextField(String(localized: "Website address"), text: $draft.url, prompt: Text(verbatim: "https://example.com"))
                .textFieldStyle(.roundedBorder)
        case .shell:
            VStack(alignment: .leading, spacing: 4) {
                TextField(String(localized: "Command"), text: $draft.shell, prompt: Text(verbatim: "open ~/Downloads"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Runs with /bin/sh in the background. Output is discarded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .system:
            Picker(String(localized: "System action"), selection: $draft.system) {
                ForEach(SystemAction.allCases, id: \.self) { action in
                    Label(UIText.name(action), systemImage: UIText.symbol(action)).tag(action)
                }
            }
        case .disable:
            Text("The key will do nothing in the apps this rule applies to.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .sequence:
            sequenceEditor
        }
    }

    private var sequenceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(draft.sequence.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                    KeyRecorderField(value: Binding(
                        get: { draft.sequence.indices.contains(index) ? draft.sequence[index] : nil },
                        set: { if draft.sequence.indices.contains(index) { draft.sequence[index] = $0 } }
                    ), allowMouse: false)
                    Button {
                        draft.sequence.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(draft.sequence.count <= 1)
                }
            }
            Button {
                draft.sequence.append(nil)
            } label: {
                Label(String(localized: "Add Key"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var warnings: some View {
        let found = liveConflicts()
        let warnings = found.filter { !$0.isInfo }.map(\.text)
        let notes = found.filter(\.isInfo).map(\.text)
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings, id: \.self) { message in
                    Label {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    .font(.callout)
                }
                Text("You can save anyway.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.35)))
        }
        ForEach(notes, id: \.self) { message in
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Button(role: .destructive) {
                    delete()
                    dismiss()
                } label: {
                    Text("Delete")
                }
            }
            Spacer()
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? String(localized: "Add") : String(localized: "Save")) {
                save()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(builtMapping == nil)
        }
    }

    // MARK: Model

    private var currentRule: Rule? {
        guard let profile = model.activeProfile,
              let index = profile.ruleIndex(id: target.ruleID, fallback: target.ruleIndex) else { return nil }
        return profile.rules[index]
    }

    private var builtMapping: Mapping? {
        guard let trigger, let action = draft.action else { return nil }
        return Mapping(id: mappingID, trigger: trigger, action: action, isTapAlone: tapAlone && trigger.isBareModifierKey)
    }

    /// Runs the conflict detector on a copy of the config with this mapping applied.
    private func liveConflicts() -> [(text: String, isInfo: Bool)] {
        guard let mapping = builtMapping else { return [] }
        var config = model.config
        var found = false
        config.editActiveProfile { profile in
            guard let r = profile.ruleIndex(id: target.ruleID, fallback: target.ruleIndex) else { return }
            profile.rules[r].enabled = true
            Self.apply(mapping, to: &profile.rules[r], fallback: target.mappingIndex)
            found = true
        }
        guard found, let profile = config.activeProfile else { return [] }
        let conflicts = ConflictDetector.find(in: profile, config: config, systemShortcuts: model.systemShortcuts)
            .filter { $0.mappingID == mapping.id || $0.otherMappingID == mapping.id }
        var seen = Set<String>()
        return conflicts.compactMap { conflict -> (text: String, isInfo: Bool)? in
            let text: String
            if conflict.otherMappingID == mapping.id, conflict.mappingID != mapping.id {
                let other = profile.rules.first { $0.id == conflict.ruleID }?.name ?? ""
                text = String(localized: "This hides \(UIText.display(conflict.trigger)) in the later rule '\(other)'.")
            } else {
                text = ConflictText.message(conflict, profile: profile, systemShortcuts: model.systemShortcuts)
            }
            return seen.insert(text).inserted ? (text, !conflict.kind.isRuleConflict) : nil
        }
    }

    private static func apply(_ mapping: Mapping, to rule: inout Rule, fallback: Int?) {
        if let m = rule.mappingIndex(id: mapping.id, fallback: fallback) {
            rule.mappings[m] = mapping
        } else {
            rule.mappings.append(mapping)
        }
    }

    private func save() {
        guard let mapping = builtMapping else { return }
        let isNew = self.isNew
        model.update { config in
            config.editActiveProfile { profile in
                guard let r = profile.ruleIndex(id: target.ruleID, fallback: target.ruleIndex) else { return }
                if isNew {
                    profile.rules[r].mappings.append(mapping)
                } else {
                    Self.apply(mapping, to: &profile.rules[r], fallback: target.mappingIndex)
                }
            }
        }
    }

    private func delete() {
        guard let original = target.mapping else { return }
        model.update { config in
            config.editActiveProfile { profile in
                guard let r = profile.ruleIndex(id: target.ruleID, fallback: target.ruleIndex),
                      let m = profile.rules[r].mappingIndex(id: original.id, fallback: target.mappingIndex) else { return }
                profile.rules[r].mappings.remove(at: m)
            }
        }
    }
}
