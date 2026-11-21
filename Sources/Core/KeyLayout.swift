import Foundation

/// Translates the key positions written in a config (named after the US ANSI layout, e.g. `i`, `minus`) to
/// the positions where the active keyboard layout types the same character.
///
/// Config keys such as `ctrl+i` mean "the key labelled I". macOS shortcuts match the character produced under
/// ⌘, so on a layout whose I lives elsewhere (Turkish-PC puts dotless ı at the US I position and i at the US
/// quote position) both the trigger and the emitted `cmd+i` must use that other position. Non-character keys
/// (arrows, F-keys, modifiers, Enter…) never move and are not listed.
public struct KeyLayoutMap: Sendable, Equatable {
    /// US position → position of the same character on the active layout. Missing entries are unchanged.
    public var positions: [KeyCode: KeyCode]
    /// US positions whose character cannot be typed unshifted on the active layout and whose own position now
    /// types a different shortcut character. Mappings that use them are not installed.
    public var unavailable: Set<KeyCode>

    public init(positions: [KeyCode: KeyCode] = [:], unavailable: Set<KeyCode> = []) {
        self.positions = positions
        self.unavailable = unavailable
    }

    public static let identity = KeyLayoutMap()
    public var isIdentity: Bool { positions.isEmpty && unavailable.isEmpty }

    /// `nil` when the key has no usable position on this layout.
    public func resolve(_ key: KeyCode) -> KeyCode? {
        if unavailable.contains(key) { return nil }
        return positions[key] ?? key
    }

    /// `reference` and `current` map key codes to the character typed under ⌘ on the US and active layouts.
    public static func make(reference: [KeyCode: String], current: [KeyCode: String]) -> KeyLayoutMap {
        var owner: [String: KeyCode] = [:]
        for (code, character) in current.sorted(by: { $0.key < $1.key }) where owner[character] == nil {
            owner[character] = code
        }
        var positions: [KeyCode: KeyCode] = [:]
        var pending: [KeyCode] = []
        for (code, character) in reference.sorted(by: { $0.key < $1.key }) {
            if current[code] == character { continue }
            if let target = owner[character] { positions[code] = target } else { pending.append(code) }
        }
        let claimed = Set(positions.values)
        let unavailable = Set(pending.filter { claimed.contains($0) })
        return KeyLayoutMap(positions: positions, unavailable: unavailable)
    }

    /// The config with every key trigger and emitted key translated. Ids are kept, so rule and mapping
    /// identities used by diagnostics and the event viewer do not change.
    public func apply(to config: Config) -> Config {
        guard !isIdentity else { return config }
        func combo(_ combo: KeyCombo) -> KeyCombo? { resolve(combo.key).map { KeyCombo($0, combo.modifiers) } }
        var result = config
        for p in result.profiles.indices {
            for r in result.profiles[p].rules.indices {
                result.profiles[p].rules[r].mappings = result.profiles[p].rules[r].mappings.compactMap { mapping in
                    var mapping = mapping
                    if case .key(let trigger) = mapping.trigger {
                        guard let moved = combo(trigger) else { return nil }
                        mapping.trigger = .key(moved)
                    }
                    if case .keys(let combos) = mapping.action {
                        let moved = combos.compactMap(combo)
                        guard moved.count == combos.count else { return nil }
                        mapping.action = .keys(moved)
                    }
                    return mapping
                }
            }
        }
        return result
    }
}
