import Foundation
import KeyshiftCore
import Yams

public struct PresetInfo: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
}

public enum Presets {
    public static func all() -> [PresetInfo] {
        entries.map(\.info)
    }

    public static func load(_ id: String) -> (Profile, appGroups: [String: [String]])? {
        guard let entry = entries.first(where: { $0.info.id == id }) else { return nil }
        let (config, _) = ConfigCodec.decode(entry.yaml)
        guard let profile = config.profiles.first else { return nil }
        return (profile, config.appGroups)
    }

    /// The complete decoded preset with every diagnostic (bundled presets are expected to have none).
    public static func decode(_ id: String) -> (Config, [Diagnostic])? {
        entries.first { $0.info.id == id }.map { ConfigCodec.decode($0.yaml) }
    }

    private struct Entry {
        let info: PresetInfo
        let yaml: String
    }

    private static let entries: [Entry] = {
        guard let directory = Bundle.module.url(forResource: "Presets", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
              ) else { return [] }
        return files.filter { $0.pathExtension == "yaml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                guard let yaml = try? String(contentsOf: file, encoding: .utf8),
                      let root = try? Yams.compose(yaml: yaml) else { return nil }
                let (config, diagnostics) = ConfigCodec.decode(root)
                guard config.profiles.count == 1, let profile = config.profiles.first,
                      !diagnostics.contains(where: { $0.severity == .error }) else { return nil }
                let description = root["description"]?.scalar?.string
                let id = file.deletingPathExtension().lastPathComponent
                let info = PresetInfo(id: id, name: profile.name, description: description)
                return Entry(info: info, yaml: yaml)
            }
    }()
}
