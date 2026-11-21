import KeyshiftConfig
import KeyshiftCore
import SwiftUI

/// Opens the rule editor sheet. `index` is the rule's position when it was opened (fallback lookup).
struct RuleSheetTarget: Identifiable {
    let id = UUID()
    var rule: Rule
    var index: Int?
    var isNew: Bool
}

/// Opens the mapping editor sheet for a rule.
struct MappingSheetTarget: Identifiable {
    let id = UUID()
    var ruleID: UUID
    var ruleIndex: Int?
    var mapping: Mapping?
    var mappingIndex: Int?
}

/// Main screen: profile bar + reorderable rule cards.
struct RulesView: View {
    @ObservedObject private var model = AppModel.shared
    @EnvironmentObject private var navigation: SettingsNavigation
    @State private var ruleSheet: RuleSheetTarget?
    @State private var mappingSheet: MappingSheetTarget?
    @State private var pendingMappingSheet: MappingSheetTarget?
    @State private var ruleToDelete: Rule?
    @State private var highlightedRule: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ProfileBar(onAddRule: addRule)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            content
        }
        .sheet(item: $ruleSheet, onDismiss: {
            if let pending = pendingMappingSheet {
                pendingMappingSheet = nil
                mappingSheet = pending
            }
        }) { target in
            RuleEditorSheet(target: target) { rule in save(rule, target: target) }
                .environmentObject(model)
        }
        .sheet(item: $mappingSheet) { target in
            MappingEditorSheet(target: target)
                .environmentObject(model)
        }
        .confirmationDialog(
            String(localized: "Delete the rule “\(ruleToDelete?.name ?? "")”?"),
            isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }),
            presenting: ruleToDelete
        ) { rule in
            Button(String(localized: "Delete Rule"), role: .destructive) { delete(rule) }
        } message: { rule in
            Text("Its \(rule.mappings.count) shortcuts will be removed. This can't be undone (a backup of the previous file is kept as config.yaml.bak).")
        }
    }

    @ViewBuilder private var content: some View {
        if let profile = model.activeProfile, !profile.rules.isEmpty {
            rulesList(profile)
        } else if model.activeProfile == nil {
            EmptyStateView(
                symbol: "keyboard",
                title: String(localized: "No profiles yet"),
                message: String(localized: "Start from a preset that matches your habits, or create an empty rule and record your own shortcuts.")
            ) {
                HStack {
                    Button(String(localized: "Browse Presets")) { navigation.section = .presets }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "Add a Rule"), action: addRule)
                }
            }
        } else {
            EmptyStateView(
                symbol: "rectangle.dashed",
                title: String(localized: "This profile has no rules"),
                message: String(localized: "A rule is a group of shortcuts that apply in the apps you choose.")
            ) {
                Button(String(localized: "Add a Rule"), action: addRule)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func rulesList(_ profile: Profile) -> some View {
        let conflicts = Dictionary(grouping: model.conflicts, by: \.mappingID)
        return ScrollViewReader { proxy in
            List {
                ForEach(Array(profile.rules.enumerated()), id: \.element.id) { index, rule in
                    RuleCard(
                        rule: rule,
                        index: index,
                        count: profile.rules.count,
                        conflicts: conflicts,
                        highlighted: highlightedRule == rule.id,
                        actions: actions(for: rule, index: index)
                    )
                    .id(rule.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                }
                .onMove { from, to in
                    model.update { config in config.editActiveProfile { $0.rules.move(fromOffsets: from, toOffset: to) } }
                }
                Text("Rules are checked from top to bottom; the first matching shortcut wins. Drag cards to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 6)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { scrollToFocused(proxy) }
            .onChange(of: navigation.focusedRuleID) { _ in scrollToFocused(proxy) }
        }
    }

    private func scrollToFocused(_ proxy: ScrollViewProxy) {
        guard let id = navigation.focusedRuleID else { return }
        navigation.focusedRuleID = nil
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .top) }
            highlightedRule = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation { if highlightedRule == id { highlightedRule = nil } }
            }
        }
    }

    private func actions(for rule: Rule, index: Int) -> RuleCard.Actions {
        RuleCard.Actions(
            edit: { ruleSheet = RuleSheetTarget(rule: rule, index: index, isNew: false) },
            delete: { ruleToDelete = rule },
            duplicate: { duplicate(rule, index: index) },
            move: { offset in move(rule, index: index, by: offset) },
            setEnabled: { enabled in
                model.update { config in
                    config.editActiveProfile { profile in
                        if let i = profile.ruleIndex(id: rule.id, fallback: index) { profile.rules[i].enabled = enabled }
                    }
                }
            },
            addMapping: { mappingSheet = MappingSheetTarget(ruleID: rule.id, ruleIndex: index) },
            editMapping: { mapping, mappingIndex in
                mappingSheet = MappingSheetTarget(ruleID: rule.id, ruleIndex: index, mapping: mapping, mappingIndex: mappingIndex)
            },
            deleteMapping: { mapping, mappingIndex in
                model.update { config in
                    config.editActiveProfile { profile in
                        guard let r = profile.ruleIndex(id: rule.id, fallback: index),
                              let m = profile.rules[r].mappingIndex(id: mapping.id, fallback: mappingIndex) else { return }
                        profile.rules[r].mappings.remove(at: m)
                    }
                }
            }
        )
    }

    private func addRule() {
        let name = String(localized: "New rule")
        ruleSheet = RuleSheetTarget(rule: Rule(name: name), index: nil, isNew: true)
    }

    private func save(_ rule: Rule, target: RuleSheetTarget) {
        var insertedIndex: Int?
        model.update { config in
            config.editActiveProfile { profile in
                if target.isNew {
                    profile.rules.append(rule)
                    insertedIndex = profile.rules.count - 1
                } else if let i = profile.ruleIndex(id: rule.id, fallback: target.index) {
                    var updated = rule
                    updated.mappings = profile.rules[i].mappings // mappings are edited separately
                    profile.rules[i] = updated
                }
            }
        }
        if target.isNew {
            pendingMappingSheet = MappingSheetTarget(ruleID: rule.id, ruleIndex: insertedIndex)
        }
    }

    private func duplicate(_ rule: Rule, index: Int) {
        var copy = rule
        copy.id = UUID()
        copy.name = String(localized: "\(rule.name) copy")
        copy.mappings = rule.mappings.map { var m = $0; m.id = UUID(); return m }
        model.update { config in
            config.editActiveProfile { profile in
                let at = (profile.ruleIndex(id: rule.id, fallback: index) ?? profile.rules.count - 1) + 1
                profile.rules.insert(copy, at: min(at, profile.rules.count))
            }
        }
    }

    private func move(_ rule: Rule, index: Int, by offset: Int) {
        model.update { config in
            config.editActiveProfile { profile in
                guard let i = profile.ruleIndex(id: rule.id, fallback: index) else { return }
                let j = i + offset
                guard profile.rules.indices.contains(j) else { return }
                profile.rules.swapAt(i, j)
            }
        }
    }

    private func delete(_ rule: Rule) {
        let index = model.activeProfile?.rules.firstIndex { $0.id == rule.id }
        model.update { config in
            config.editActiveProfile { profile in
                if let i = profile.ruleIndex(id: rule.id, fallback: index) { profile.rules.remove(at: i) }
            }
        }
        ruleToDelete = nil
    }
}
