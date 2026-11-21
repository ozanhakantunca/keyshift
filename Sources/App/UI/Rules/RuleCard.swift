import KeyshiftConfig
import KeyshiftCore
import SwiftUI

/// One rule: header (switch, name, scope, focus, menu) + its mappings.
struct RuleCard: View {
    struct Actions {
        var edit: () -> Void
        var delete: () -> Void
        var duplicate: () -> Void
        var move: (Int) -> Void
        var setEnabled: (Bool) -> Void
        var addMapping: () -> Void
        var editMapping: (Mapping, Int) -> Void
        var deleteMapping: (Mapping, Int) -> Void
    }

    @ObservedObject private var model = AppModel.shared
    let rule: Rule
    let index: Int
    let count: Int
    let conflicts: [UUID: [Conflict]]
    let highlighted: Bool
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            if !rule.mappings.isEmpty {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(Array(rule.mappings.enumerated()), id: \.element.id) { mappingIndex, mapping in
                        MappingRow(
                            mapping: mapping,
                            conflicts: conflicts[mapping.id] ?? [],
                            onEdit: { actions.editMapping(mapping, mappingIndex) },
                            onDelete: { actions.deleteMapping(mapping, mappingIndex) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            Divider().padding(.horizontal, 12)
            Button(action: actions.addMapping) {
                Label(String(localized: "Add Shortcut"), systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .opacity(rule.enabled ? 1 : 0.55)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: highlighted ? 2 : 1)
        )
        .contextMenu { menuItems }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(String(localized: "Enabled"), isOn: Binding(get: { rule.enabled }, set: actions.setEnabled))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(rule.enabled ? Text("Turn this rule off") : Text("Turn this rule on"))
            VStack(alignment: .leading, spacing: 5) {
                Text(rule.name.isEmpty ? String(localized: "Untitled rule") : rule.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ScopeSummary(scope: rule.scope)
                    if let badge = UIText.badge(rule.focus) {
                        Chip(badge.text, symbol: badge.symbol, tint: .purple)
                    }
                    if !rule.enabled {
                        Chip(String(localized: "Off"), symbol: "pause.circle")
                    }
                }
            }
            Spacer(minLength: 8)
            let ruleConflicts = rule.mappings.reduce(0) { $0 + (conflicts[$1.id]?.filter { $0.kind.isRuleConflict }.count ?? 0) }
            if ruleConflicts > 0 {
                Label("\(ruleConflicts)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help(Text("\(ruleConflicts) shortcuts in this rule overlap with others"))
            }
            Button(action: actions.edit) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help(Text("Edit name, apps and conditions"))
            Menu { menuItems } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More actions"))
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button(String(localized: "Edit Rule…"), action: actions.edit)
        Button(String(localized: "Add Shortcut…"), action: actions.addMapping)
        Button(String(localized: "Duplicate"), action: actions.duplicate)
        Divider()
        Button(String(localized: "Move Up")) { actions.move(-1) }.disabled(index == 0)
        Button(String(localized: "Move Down")) { actions.move(1) }.disabled(index >= count - 1)
        Divider()
        Button(String(localized: "Delete Rule…"), role: .destructive, action: actions.delete)
    }
}

/// `⌃ C → ⌘ C` with conflict badge and hover actions. Click to edit.
struct MappingRow: View {
    @ObservedObject private var model = AppModel.shared
    let mapping: Mapping
    let conflicts: [Conflict]
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            MappingLine(mapping: mapping)
            if !conflicts.isEmpty {
                let isWarning = conflicts.contains { $0.kind.isRuleConflict }
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help(conflictText)
                    .accessibilityLabel(Text(isWarning ? String(localized: "Conflict: \(conflictText)") : String(localized: "Note: \(conflictText)")))
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .help(Text("Edit shortcut"))
                Button(action: onDelete) { Image(systemName: "trash") }
                    .help(Text("Delete shortcut"))
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.05) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 1, perform: onEdit)
        .contextMenu {
            Button(String(localized: "Edit Shortcut…"), action: onEdit)
            Button(String(localized: "Delete Shortcut"), role: .destructive, action: onDelete)
        }
    }

    private var conflictText: String {
        conflicts.map {
            ConflictText.message($0, profile: model.activeProfile, systemShortcuts: model.systemShortcuts)
        }.joined(separator: "\n")
    }
}
