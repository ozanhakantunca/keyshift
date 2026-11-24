import Foundation
import KeyshiftConfig
import KeyshiftCore

enum ConfigEdits {
    static var defaultKarabinerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner/karabiner.json")
    }

    /// Keep the existing profile unless this is the first import or the caller selects the addition.
    static func append(_ incoming: Config, to config: inout Config, selectIncoming: Bool = false) {
        let selected = selectIncoming || config.activeProfile == nil ? incoming.activeProfile?.id : nil
        var names = Set(config.profiles.map { $0.name.lowercased() })
        for var profile in incoming.profiles {
            let base = profile.name
            var suffix = 2
            while !names.insert(profile.name.lowercased()).inserted {
                profile.name = "\(base) (\(suffix))"
                suffix += 1
            }
            config.profiles.append(profile)
            if profile.id == selected { config.selectedProfile = profile.name }
        }
        for (group, entries) in incoming.appGroups {
            var existing = Set(config.appGroups[group, default: []].map { $0.lowercased() })
            config.appGroups[group, default: []].append(contentsOf: entries.filter {
                existing.insert($0.lowercased()).inserted
            })
        }
    }

    static func select(_ name: String, in config: inout Config) throws {
        guard config.profiles.contains(where: { $0.name == name }) else {
            throw ConfigEditError.unknownProfile(name)
        }
        config.selectedProfile = name
    }

    static func hasErrors(_ diagnostics: [Diagnostic]) -> Bool {
        diagnostics.contains { $0.severity == .error }
    }

    /// `new` with the ids of `old`'s profiles (same name), rules (same name and settings) and mappings
    /// (same trigger and action) where they are unchanged, preferring the same position. A reload
    /// decodes fresh ids; carrying them over keeps open sheets pointed at the item they show.
    static func carryingIDs(from old: Config, to new: Config) -> Config {
        var result = new
        let profiles = matches(old.profiles, result.profiles) { $0.name == $1.name }
        for (p, o) in profiles.enumerated() {
            guard let o else { continue }
            let previous = old.profiles[o]
            result.profiles[p].id = previous.id
            let rules = matches(previous.rules, result.profiles[p].rules) { $0.settingsEqual($1) }
            for (r, match) in rules.enumerated() {
                guard let match else { continue }
                let oldRule = previous.rules[match]
                result.profiles[p].rules[r].id = oldRule.id
                let mappings = matches(oldRule.mappings, result.profiles[p].rules[r].mappings) { $0.contentEqual($1) }
                for (m, match) in mappings.enumerated() {
                    if let match { result.profiles[p].rules[r].mappings[m].id = oldRule.mappings[match].id }
                }
            }
        }
        return result
    }

    /// For each element of `new`, the index of an equal, otherwise unmatched element of `old`
    /// (same position first, then the first free one).
    private static func matches<T>(_ old: [T], _ new: [T], equal: (T, T) -> Bool) -> [Int?] {
        var result = [Int?](repeating: nil, count: new.count)
        var used = Set<Int>()
        for i in new.indices where i < old.count && equal(old[i], new[i]) {
            result[i] = i
            used.insert(i)
        }
        for i in new.indices where result[i] == nil {
            if let j = old.indices.first(where: { !used.contains($0) && equal(old[$0], new[i]) }) {
                result[i] = j
                used.insert(j)
            }
        }
        return result
    }

    static func conflicts(in config: Config, shortcuts: [KeyCombo: String]) -> [Conflict] {
        guard let profile = config.activeProfile else { return [] }
        return ConflictDetector.find(in: profile, config: config, systemShortcuts: shortcuts)
    }
}

enum ConfigEditError: LocalizedError {
    case unknownProfile(String)
    case invalidConfig(URL)
    /// UI edit refused because the file on disk has errors.
    case fileHasErrors
    /// The item being edited changed or disappeared in an external reload.
    case changedOnDisk
    case recording
    case remappingDisabled

    var errorDescription: String? {
        switch self {
        case .unknownProfile(let name): return "Profile '\(name)' was not found."
        case .invalidConfig(let url): return "Fix the errors in \(url.path) before editing it with the CLI."
        case .recording: return "Finish recording the shortcut before running the self-test."
        case .fileHasErrors: return String(localized: "The config file has errors. Fix the file before editing here.")
        case .changedOnDisk: return String(localized: "The config changed on disk. Reopen and try again.")
        case .remappingDisabled: return "Keyshift is disabled. Enable remapping before running a self-test."
        }
    }
}

extension Rule {
    /// Everything but the ids and the mappings.
    func settingsEqual(_ other: Rule) -> Bool {
        name == other.name && enabled == other.enabled && scope == other.scope && focus == other.focus
            && passthrough == other.passthrough
    }

    /// Same settings and the same mappings in the same order, ignoring ids.
    func contentEqual(_ other: Rule) -> Bool {
        settingsEqual(other) && mappings.count == other.mappings.count
            && zip(mappings, other.mappings).allSatisfy { $0.contentEqual($1) }
    }
}

extension Mapping {
    func contentEqual(_ other: Mapping) -> Bool {
        trigger == other.trigger && action == other.action && isTapAlone == other.isTapAlone
    }
}
