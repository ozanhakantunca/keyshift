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

    static func conflicts(in config: Config, shortcuts: [KeyCombo: String]) -> [Conflict] {
        guard let profile = config.activeProfile else { return [] }
        return ConflictDetector.find(in: profile, config: config, systemShortcuts: shortcuts)
    }
}

enum ConfigEditError: LocalizedError {
    case unknownProfile(String)
    case invalidConfig(URL)
    case recording
    case remappingDisabled

    var errorDescription: String? {
        switch self {
        case .unknownProfile(let name): return "Profile '\(name)' was not found."
        case .invalidConfig(let url): return "Fix the errors in \(url.path) before editing it with the CLI."
        case .recording: return "Finish recording the shortcut before running the self-test."
        case .remappingDisabled: return "Enable remapping before running the live suite."
        }
    }
}
