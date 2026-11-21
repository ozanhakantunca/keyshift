import KeyshiftConfig
import KeyshiftCore
import SwiftUI

/// All conflicts in the active profile, grouped by kind.
struct ConflictsView: View {
    @ObservedObject private var model = AppModel.shared
    @EnvironmentObject private var navigation: SettingsNavigation

    @ViewBuilder
    private func conflictSection(title: String, symbol: String, tint: Color, items: [Conflict]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(Array(items.enumerated()), id: \.offset) { _, conflict in
                    ConflictRow(conflict: conflict) { navigation.showRule(conflict.ruleID) }
                }
            } header: {
                Label("\(title) (\(items.count))", systemImage: symbol).foregroundStyle(tint)
            }
        }
    }

    var body: some View {
        if model.conflicts.isEmpty {
            EmptyStateView(
                symbol: "checkmark.seal",
                title: String(localized: "No conflicts"),
                message: String(localized: "None of your shortcuts overlap with each other or with macOS shortcuts.")
            )
        } else {
            List {
                Section {
                    Text("Overlapping shortcuts are allowed — the first matching one wins — but they can make a key behave unexpectedly. Overriding a macOS shortcut is usually intentional.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                conflictSection(
                    title: String(localized: "Conflicts between your rules"),
                    symbol: "exclamationmark.triangle.fill", tint: .orange,
                    items: model.conflicts.filter { $0.kind.isRuleConflict }
                )
                conflictSection(
                    title: String(localized: "macOS shortcuts you override"),
                    symbol: "info.circle", tint: .secondary,
                    items: model.conflicts.filter { !$0.kind.isRuleConflict }
                )
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
        }
    }
}

private struct ConflictRow: View {
    @ObservedObject private var model = AppModel.shared
    let conflict: Conflict
    let onShow: () -> Void

    var body: some View {
        let profile = model.activeProfile
        let rule = profile?.rules.first { $0.id == conflict.ruleID }
        let mapping = rule?.mappings.first { $0.id == conflict.mappingID }
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if let mapping {
                        MappingLine(mapping: mapping)
                    } else {
                        TriggerKeycaps(trigger: conflict.trigger)
                    }
                }
                Text(ConflictText.message(conflict, profile: profile, systemShortcuts: model.systemShortcuts))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let rule {
                    Text("In rule “\(rule.name)”").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(String(localized: "Show Rule"), action: onShow)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
