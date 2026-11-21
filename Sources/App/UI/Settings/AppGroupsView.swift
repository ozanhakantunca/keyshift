import KeyshiftCore
import SwiftUI

/// Manage `app_groups`: named lists of apps that rules can refer to ("Except Terminals").
struct AppGroupsView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var renaming: String?
    @State private var nameText = ""
    @State private var groupToDelete: String?
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(
                    title: String(localized: "App groups"),
                    subtitle: String(localized: "Name a set of apps once (like Terminals or Browsers), then use it in any rule's “Where”.")
                )
                Button {
                    nameText = model.config.uniqueGroupName(String(localized: "new_group"))
                    creating = true
                } label: {
                    Label(String(localized: "New Group"), systemImage: "plus")
                }
            }
            .padding(20)
            Divider()
            if model.config.appGroups.isEmpty {
                EmptyStateView(
                    symbol: "square.stack.3d.up",
                    title: String(localized: "No app groups"),
                    message: String(localized: "Presets add groups such as Terminals automatically. You can also make your own.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(model.config.appGroups.keys.sorted(), id: \.self) { name in
                            AppGroupCard(
                                name: name,
                                apps: model.config.appGroups[name] ?? [],
                                usage: model.config.ruleCount(referencing: name),
                                onRename: { nameText = name; renaming = name },
                                onDelete: { groupToDelete = name }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .alert(String(localized: "Group Name"), isPresented: Binding(
            get: { renaming != nil || creating },
            set: { if !$0 { renaming = nil; creating = false } }
        )) {
            TextField(String(localized: "Name"), text: $nameText)
            Button(String(localized: "Cancel"), role: .cancel) { renaming = nil; creating = false }
            Button(String(localized: "Save"), action: commitName).disabled(!isValidName)
        } message: {
            Text(isNameTaken ? String(localized: "A group with this name already exists.") : String(localized: "Use letters, digits and underscores, e.g. remote_desktop."))
        }
        .confirmationDialog(
            String(localized: "Delete the group “\(groupToDelete ?? "")”?"),
            isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
            presenting: groupToDelete
        ) { name in
            Button(String(localized: "Delete Group"), role: .destructive) {
                model.update { $0.deleteGroup(name) }
                groupToDelete = nil
            }
        } message: { name in
            let usage = model.config.ruleCount(referencing: name)
            if usage > 0 {
                Text("It is used by \(usage) rules; it will be removed from them.")
            } else {
                Text("No rule uses this group.")
            }
        }
    }

    private var cleanedName: String {
        nameText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private var isNameTaken: Bool {
        cleanedName != renaming && model.config.appGroups[cleanedName] != nil
    }

    private var isValidName: Bool {
        !cleanedName.isEmpty && !isNameTaken && !cleanedName.contains("/") && !cleanedName.hasPrefix("@")
            && !cleanedName.contains(".")
    }

    private func commitName() {
        guard isValidName else { return }
        let name = cleanedName
        if let old = renaming {
            model.update { $0.renameGroup(old, to: name) }
        } else {
            model.update { $0.appGroups[name] = [] }
        }
        renaming = nil
        creating = false
    }
}

private struct AppGroupCard: View {
    @ObservedObject private var model = AppModel.shared
    let name: String
    let apps: [String]
    let usage: Int
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var pathText = ""
    @State private var addingPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.accentColor)
                Text(ScopeEntryInfo.groupTitle(name)).font(.headline)
                Text(name).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(usage == 0 ? String(localized: "Not used") : String(localized: "Used by \(usage) rules"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    Button(String(localized: "Rename…"), action: onRename)
                    Button(String(localized: "Delete…"), role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(12)
            Divider()
            if apps.isEmpty {
                Text("No apps in this group yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(12)
            }
            ForEach(apps, id: \.self) { entry in
                HStack(spacing: 10) {
                    AppIconView(entry: entry, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        if AppScope.isPathFragment(entry) {
                            Text("Apps whose path contains").font(.callout)
                            Text(entry).font(.caption.monospaced()).foregroundStyle(.secondary)
                        } else if model.appDisplayName(for: entry) == entry {
                            Text(entry).font(.callout.monospaced())
                            Text("Not installed on this Mac").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(model.appDisplayName(for: entry)).font(.callout)
                            Text(entry).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        model.update { $0.appGroups[name]?.removeAll { $0 == entry } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Remove from group"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            Divider()
            HStack(spacing: 12) {
                AppPickerMenu(includeGroups: false, excluded: Set(apps), onPick: add) {
                    Label(String(localized: "Add App"), systemImage: "plus")
                }
                if addingPath {
                    TextField(String(localized: "Path fragment"), text: $pathText, prompt: Text(verbatim: "/Applications/Steam/"))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .onSubmit(addPath)
                    Button(String(localized: "Add"), action: addPath)
                        .disabled(!pathText.contains("/"))
                } else {
                    Button(String(localized: "Add Path…")) { addingPath = true }
                        .buttonStyle(.borderless)
                        .help(Text("Match every app inside a folder, e.g. games in a launcher folder"))
                }
                Spacer()
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func add(_ entry: String) {
        model.update { config in
            if !(config.appGroups[name] ?? []).contains(entry) { config.appGroups[name, default: []].append(entry) }
        }
    }

    private func addPath() {
        let value = pathText.trimmingCharacters(in: .whitespaces)
        guard value.contains("/") else { return }
        add(value)
        pathText = ""
        addingPath = false
    }
}
