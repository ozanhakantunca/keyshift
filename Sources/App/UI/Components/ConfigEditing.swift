import Foundation
import KeyshiftCore

/// Small, pure helpers the views use inside `model.update { … }`. Rules and mappings are found by
/// id first (a reload keeps the ids of unchanged items) and by their former index second, but only
/// while the item there still equals the snapshot the view was showing; otherwise the edit is
/// refused with `ConfigEditError.changedOnDisk` instead of hitting a different item.
extension Config {
    var activeProfileIndex: Int? {
        if let i = profiles.firstIndex(where: { $0.name == selectedProfile }) { return i }
        return profiles.isEmpty ? nil : 0
    }

    /// Runs `body` on the active profile, creating a "Default" profile first when there is none.
    mutating func editActiveProfile(_ body: (inout Profile) throws -> Void) rethrows {
        if activeProfileIndex == nil {
            let name = uniqueProfileName(String(localized: "Default"))
            profiles.append(Profile(name: name))
            selectedProfile = name
        }
        guard let index = activeProfileIndex else { return }
        try body(&profiles[index])
    }

    func uniqueProfileName(_ base: String) -> String {
        let names = Set(profiles.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func uniqueGroupName(_ base: String) -> String {
        guard appGroups[base] != nil else { return base }
        var n = 2
        while appGroups["\(base)_\(n)"] != nil { n += 1 }
        return "\(base)_\(n)"
    }

    /// Whether a scope entry names an app group (optionally "@"-prefixed).
    func groupName(for entry: String) -> String? {
        let name = entry.hasPrefix("@") ? String(entry.dropFirst()) : entry
        return appGroups[name] != nil ? name : nil
    }

    /// Number of rules (all profiles) whose scope mentions the group.
    func ruleCount(referencing group: String) -> Int {
        profiles.flatMap(\.rules).filter { rule in
            rule.scope.apps.contains { $0 == group || $0 == "@" + group }
        }.count
    }

    mutating func renameGroup(_ old: String, to new: String) {
        guard old != new, let apps = appGroups[old], appGroups[new] == nil else { return }
        appGroups[old] = nil
        appGroups[new] = apps
        replaceScopeEntries { entry in
            if entry == old { return new }
            if entry == "@" + old { return "@" + new }
            return entry
        }
    }

    mutating func deleteGroup(_ name: String) {
        appGroups[name] = nil
        replaceScopeEntries { $0 == name || $0 == "@" + name ? nil : $0 }
    }

    private mutating func replaceScopeEntries(_ transform: (String) -> String?) {
        for p in profiles.indices {
            for r in profiles[p].rules.indices {
                profiles[p].rules[r].scope.apps = profiles[p].rules[r].scope.apps.compactMap(transform)
                if profiles[p].rules[r].scope.apps.isEmpty && profiles[p].rules[r].scope.kind == .except {
                    profiles[p].rules[r].scope.kind = .everywhere
                }
            }
        }
    }
}

extension Profile {
    /// The rule `snapshot` shows. Throws when it changed or disappeared; nil only without a snapshot.
    func ruleIndex(id: UUID, fallback: Int?, snapshot: Rule?) throws -> Int? {
        if let i = rules.firstIndex(where: { $0.id == id }) { return i }
        guard let snapshot else { return nil }
        if let fallback, rules.indices.contains(fallback), rules[fallback].contentEqual(snapshot) { return fallback }
        throw ConfigEditError.changedOnDisk
    }
}

extension Rule {
    /// The mapping `snapshot` shows. Throws when it changed or disappeared; nil only without a snapshot.
    func mappingIndex(id: UUID, fallback: Int?, snapshot: Mapping?) throws -> Int? {
        if let i = mappings.firstIndex(where: { $0.id == id }) { return i }
        guard let snapshot else { return nil }
        if let fallback, mappings.indices.contains(fallback), mappings[fallback].contentEqual(snapshot) { return fallback }
        throw ConfigEditError.changedOnDisk
    }
}

extension Trigger {
    /// A bare modifier key such as `left_cmd`: the only kind of trigger that may be "tap alone".
    var isBareModifierKey: Bool {
        if case .key(let combo) = self { return combo.key.isModifier && combo.modifiers.isEmpty }
        return false
    }

    func withModifiers(_ modifiers: Modifiers) -> Trigger {
        switch self {
        case .key(let combo): return .key(KeyCombo(combo.key, modifiers))
        case .mouse(let button, _): return .mouse(button, modifiers)
        }
    }
}
