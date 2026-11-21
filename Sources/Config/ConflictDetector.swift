import Foundation
import KeyshiftCore

public struct Conflict: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case duplicate, shadowed, systemShortcut

        /// True for conflicts between the user's own rules; macOS shortcut overrides are informational.
        public var isRuleConflict: Bool { self != .systemShortcut }
    }

    public let kind: Kind
    public let ruleID: UUID
    public let mappingID: UUID
    public let otherRuleID: UUID?
    public let otherMappingID: UUID?
    public let trigger: Trigger
    public let message: String
}

public enum ConflictDetector {
    public static func find(in profile: Profile, config: Config,
                            systemShortcuts: [KeyCombo: String] = [:]) -> [Conflict] {
        let entries = profile.rules.filter(\.enabled).flatMap { rule in
            let apps = ScopedApps(rule.scope, config: config)
            return rule.mappings.map { Entry(rule: rule, mapping: $0, apps: apps) }
        }
        let byInput = Dictionary(grouping: entries, by: \.input)
        let shortcuts = Dictionary(grouping: systemShortcuts.sorted { $0.key.description < $1.key.description },
                                   by: { $0.key.key })
        var earlier: [Input: [Entry]] = [:]
        var conflicts: [Conflict] = []

        for entry in entries where !entry.apps.isEmpty {
            for previous in earlier[entry.input, default: []] {
                let apps = entry.apps.intersection(previous.apps)
                let focus = [false, true].filter { entry.matchesFocus($0) && previous.matchesFocus($0) }
                guard !apps.isEmpty, !focus.isEmpty else { continue }

                if entry.mapping.trigger == previous.mapping.trigger {
                    conflicts.append(entry.conflict(
                        .duplicate, trigger: entry.mapping.trigger, other: previous,
                        message: "\(entry.mapping.trigger) already appears in '\(previous.rule.name)' with overlapping scope."
                    ))
                } else if !entry.mapping.isTapAlone,
                          let modifiers = shadowedModifiers(entry, by: previous, apps: apps, focus: focus,
                                                            entries: byInput[entry.input, default: []]) {
                    let trigger = entry.mapping.trigger.input.trigger(modifiers)
                    conflicts.append(entry.conflict(
                        .shadowed, trigger: trigger, other: previous,
                        message: "'\(previous.rule.name)' matches \(trigger) first through passthrough."
                    ))
                }
            }
            earlier[entry.input, default: []].append(entry)

            if case .key(let combo) = entry.mapping.trigger, !entry.mapping.isTapAlone {
                for (systemCombo, title) in shortcuts[combo.key, default: []] where entry.matches(systemCombo.modifiers) {
                    conflicts.append(entry.conflict(
                        .systemShortcut, trigger: .key(systemCombo), other: nil,
                        message: "\(systemCombo) is also assigned to the macOS shortcut '\(title)'."
                    ))
                }
            }
        }
        return conflicts
    }

    private static func shadowedModifiers(_ entry: Entry, by previous: Entry, apps: ScopedApps,
                                          focus: [Bool], entries: [Entry]) -> Modifiers? {
        let current = entry.mapping.trigger.modifiers
        let preceding = previous.mapping.trigger.modifiers
        let required = current.union(preceding)
        let allowed = current.union(entry.rule.passthrough).intersection(preceding.union(previous.rule.passthrough))
        guard allowed.isSuperset(of: required) else { return nil }

        let beforePrevious = entries.prefix { $0.mapping.id != previous.mapping.id }
        for modifiers in modifierCombinations where modifiers.isSuperset(of: required) &&
            allowed.isSuperset(of: modifiers) && modifiers != current && modifiers != preceding {
            let exact = entries.filter { $0.mapping.trigger.modifiers == modifiers }
            let higherPriority = exact + beforePrevious.filter { $0.matches(modifiers) }
            for textInput in focus {
                var remaining = apps
                for match in higherPriority where match.matchesFocus(textInput) {
                    remaining = remaining.subtracting(match.apps)
                }
                if !remaining.isEmpty { return modifiers }
            }
        }
        return nil
    }

    private static let modifierCombinations: [Modifiers] = Modifiers.canonical.reduce([[]]) { combinations, modifier in
        combinations + combinations.map { $0.union(modifier.flag) }
    }

    private struct Input: Hashable {
        let event: TriggerInput
        let tap: Bool
    }

    private struct Entry {
        let rule: Rule
        let mapping: Mapping
        let apps: ScopedApps

        var input: Input { Input(event: mapping.trigger.input, tap: mapping.isTapAlone) }

        func matches(_ modifiers: Modifiers) -> Bool {
            let required = mapping.trigger.modifiers
            return modifiers.isSuperset(of: required) && rule.passthrough.isSuperset(of: modifiers.subtracting(required))
        }

        func matchesFocus(_ textInput: Bool) -> Bool {
            switch rule.focus {
            case .any: return true
            case .textInput: return textInput
            case .notTextInput: return !textInput
            }
        }

        func conflict(_ kind: Conflict.Kind, trigger: Trigger, other: Entry?, message: String) -> Conflict {
            Conflict(kind: kind, ruleID: rule.id, mappingID: mapping.id, otherRuleID: other?.rule.id,
                     otherMappingID: other?.mapping.id, trigger: trigger, message: message)
        }
    }
}

enum TriggerInput: Hashable {
    case key(KeyCode)
    case mouse(MouseButton)

    func trigger(_ modifiers: Modifiers) -> Trigger {
        switch self {
        case .key(let key): return .key(KeyCombo(key, modifiers))
        case .mouse(let button): return .mouse(button, modifiers)
        }
    }
}

extension Trigger {
    var input: TriggerInput {
        switch self {
        case .key(let combo): return .key(combo.key)
        case .mouse(let button, _): return .mouse(button)
        }
    }
}

enum ScopedApps {
    case only(Set<String>)
    case except(Set<String>)

    init(_ scope: AppScope, config: Config = Config()) {
        let apps = Set(config.resolveApps(scope.apps))
        switch scope.kind {
        case .everywhere: self = .except([])
        case .only: self = .only(apps)
        case .except: self = .except(apps)
        }
    }

    var isEmpty: Bool {
        if case .only(let apps) = self { return apps.isEmpty }
        return false
    }

    func overlaps(_ other: ScopedApps) -> Bool {
        !intersection(other).isEmpty
    }

    /// Entries are lowercased bundle ids or path fragments (containing "/"). Two bundle ids are
    /// disjoint unless equal. A path fragment can't be proven disjoint from anything, so overlaps that
    /// involve one are kept; it is only subtracted when a listed fragment is contained in it.
    func intersection(_ other: ScopedApps) -> ScopedApps {
        switch (self, other) {
        case (.only(let lhs), .only(let rhs)): return .only(Self.overlap(lhs, rhs))
        case (.only(let lhs), .except(let rhs)), (.except(let rhs), .only(let lhs)):
            return .only(lhs.filter { !Self.covered($0, by: rhs) })
        case (.except(let lhs), .except(let rhs)): return .except(lhs.union(rhs))
        }
    }

    private static func overlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Set<String> {
        var result = lhs.intersection(rhs)
        for l in lhs where AppScope.isPathFragment(l) { if !rhs.isEmpty { result.insert(l) } }
        for r in rhs where AppScope.isPathFragment(r) { if !lhs.isEmpty { result.insert(r) } }
        return result
    }

    /// Every app matching `entry` surely matches one of `excluded`.
    private static func covered(_ entry: String, by excluded: Set<String>) -> Bool {
        if excluded.contains(entry) { return true }
        guard AppScope.isPathFragment(entry) else { return false }
        return excluded.contains { AppScope.isPathFragment($0) && entry.contains($0) }
    }

    func subtracting(_ other: ScopedApps) -> ScopedApps {
        switch other {
        case .only(let apps): return intersection(.except(apps))
        case .except(let apps): return intersection(.only(apps))
        }
    }
}
