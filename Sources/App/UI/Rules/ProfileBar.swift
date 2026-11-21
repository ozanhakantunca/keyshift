import KeyshiftCore
import SwiftUI

/// Profile picker + profile actions + "Add Rule".
struct ProfileBar: View {
    @ObservedObject private var model = AppModel.shared
    @EnvironmentObject private var navigation: SettingsNavigation
    let onAddRule: () -> Void

    private enum NamePrompt: Identifiable {
        case new, rename(String)
        var id: String {
            switch self {
            case .new: return "new"
            case .rename(let name): return "rename:" + name
            }
        }
    }

    @State private var namePrompt: NamePrompt?
    @State private var nameText = ""
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.rectangle.stack")
                .foregroundStyle(.secondary)
            if model.config.profiles.isEmpty {
                Text("No profile").foregroundStyle(.secondary)
            } else {
                Picker(String(localized: "Profile"), selection: Binding(
                    get: { model.activeProfile?.name ?? "" },
                    set: { model.selectProfile($0) }
                )) {
                    ForEach(model.config.profiles) { profile in
                        Text(profile.name).tag(profile.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .help(Text("Only the selected profile is active"))
            }
            profileMenu
            Spacer()
            if let profile = model.activeProfile {
                let mappings = profile.rules.reduce(0) { $0 + $1.mappings.count }
                Text("\(profile.rules.count) rules · \(mappings) shortcuts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button(action: onAddRule) {
                Label(String(localized: "Add Rule"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: .command)
        }
        .alert(promptTitle, isPresented: Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } })) {
            TextField(String(localized: "Name"), text: $nameText)
            Button(String(localized: "Cancel"), role: .cancel) { namePrompt = nil }
            Button(String(localized: "Save")) { commitName() }
                .disabled(!isValidName)
        } message: {
            Text(isNameTaken ? String(localized: "A profile with this name already exists.") : String(localized: "Profiles let you switch between sets of rules from the menu bar."))
        }
        .confirmationDialog(
            String(localized: "Delete the profile “\(model.activeProfile?.name ?? "")”?"),
            isPresented: $confirmDelete
        ) {
            Button(String(localized: "Delete Profile"), role: .destructive, action: deleteProfile)
        } message: {
            Text("All of its rules will be removed. A backup of the previous file is kept as config.yaml.bak.")
        }
    }

    private var profileMenu: some View {
        Menu {
            Button(String(localized: "New Empty Profile…")) {
                nameText = model.config.uniqueProfileName(String(localized: "My profile"))
                namePrompt = .new
            }
            Button(String(localized: "Add from Preset…")) { navigation.section = .presets }
            if let profile = model.activeProfile {
                Divider()
                Button(String(localized: "Duplicate “\(profile.name)”")) { duplicate(profile) }
                Button(String(localized: "Rename “\(profile.name)”…")) {
                    nameText = profile.name
                    namePrompt = .rename(profile.name)
                }
                Divider()
                Button(String(localized: "Delete “\(profile.name)”…"), role: .destructive) { confirmDelete = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text("Profile actions"))
    }

    private var promptTitle: String {
        if case .rename = namePrompt { return String(localized: "Rename Profile") }
        return String(localized: "New Profile")
    }

    private var trimmedName: String { nameText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isNameTaken: Bool {
        if case .rename(let old) = namePrompt, old == trimmedName { return false }
        return model.config.profiles.contains { $0.name == trimmedName }
    }

    private var isValidName: Bool { !trimmedName.isEmpty && !isNameTaken }

    private func commitName() {
        guard isValidName, let prompt = namePrompt else { return }
        let name = trimmedName
        switch prompt {
        case .new:
            model.update { config in
                config.profiles.append(Profile(name: name))
                config.selectedProfile = name
            }
        case .rename(let old):
            model.update { config in
                guard let i = config.profiles.firstIndex(where: { $0.name == old }) else { return }
                config.profiles[i].name = name
                if config.selectedProfile == old || config.selectedProfile == nil { config.selectedProfile = name }
            }
        }
        namePrompt = nil
    }

    private func duplicate(_ profile: Profile) {
        model.update { config in
            var copy = profile
            copy.id = UUID()
            copy.name = config.uniqueProfileName(String(localized: "\(profile.name) copy"))
            copy.rules = profile.rules.map { rule in
                var r = rule
                r.id = UUID()
                r.mappings = rule.mappings.map { var m = $0; m.id = UUID(); return m }
                return r
            }
            config.profiles.append(copy)
            config.selectedProfile = copy.name
        }
    }

    private func deleteProfile() {
        guard let name = model.activeProfile?.name else { return }
        model.update { config in
            config.profiles.removeAll { $0.name == name }
            config.selectedProfile = config.profiles.first?.name
        }
    }
}
