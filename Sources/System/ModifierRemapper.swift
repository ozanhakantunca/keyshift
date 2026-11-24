import Foundation
import IOKit.hidsystem
import KeyshiftCore

/// Remembers which HID remaps Keyshift installed. UserKeyMapping outlives the process, so after a
/// crash or kill the next process must not mistake those leftovers for the user's own mappings.
public protocol HIDRemapLedger: AnyObject {
    /// Remaps recorded by earlier processes, minus any this process has installed itself.
    func leftovers() -> [ModifierRemapper.Remap]
    /// Replaces what this owner currently has installed.
    func record(_ remaps: [ModifierRemapper.Remap])
    /// This owner has nothing installed.
    func clear()
    /// Every connected keyboard was cleaned of earlier leftovers.
    func forgetLeftovers()
}

/// Ledger entries live in one defaults dictionary, keyed by process session and owner.
public final class UserDefaultsRemapLedger: HIDRemapLedger {
    public static let key = "appliedHIDRemaps"
    private static let processSession = UUID().uuidString

    private let defaults: UserDefaults
    private let session: String
    private let entry: String

    public init(owner: String, defaults: UserDefaults = .standard, session: String? = nil) {
        self.defaults = defaults
        self.session = session ?? Self.processSession
        entry = self.session + "/" + owner
    }

    private var entries: [String: [[NSNumber]]] {
        get { defaults.dictionary(forKey: Self.key) as? [String: [[NSNumber]]] ?? [:] }
        set { newValue.isEmpty ? defaults.removeObject(forKey: Self.key) : defaults.set(newValue, forKey: Self.key) }
    }

    private func isCurrent(_ key: String) -> Bool { key.hasPrefix(session + "/") }

    public func leftovers() -> [ModifierRemapper.Remap] {
        var earlier: [ModifierRemapper.Remap] = []
        var current: Set<ModifierRemapper.Remap> = []
        for (key, pairs) in entries.sorted(by: { $0.key < $1.key }) {
            let remaps = pairs.compactMap { pair in
                pair.count == 2 ? ModifierRemapper.Remap(source: pair[0].uint64Value, destination: pair[1].uint64Value) : nil
            }
            if isCurrent(key) { current.formUnion(remaps) } else { earlier += remaps }
        }
        var seen: Set<ModifierRemapper.Remap> = []
        return earlier.filter { !current.contains($0) && seen.insert($0).inserted }
    }

    public func record(_ remaps: [ModifierRemapper.Remap]) {
        let pairs = remaps.map { [NSNumber(value: $0.source), NSNumber(value: $0.destination)] }
        var entries = entries
        guard entries[entry] != pairs else { return }
        entries[entry] = pairs
        self.entries = entries
    }

    public func clear() {
        var entries = entries
        guard entries.removeValue(forKey: entry) != nil else { return }
        self.entries = entries
    }

    public func forgetLeftovers() {
        let entries = entries
        let kept = entries.filter { isCurrent($0.key) }
        if kept.count != entries.count { self.entries = kept }
    }
}

/// Installs the same per-keyboard UserKeyMapping property as hidutil.
public final class ModifierRemapper {
    public struct Remap: Hashable {
        public let source: UInt64
        public let destination: UInt64

        public init(source: UInt64, destination: UInt64) {
            self.source = source
            self.destination = destination
        }

        private static let sourceKey = "HIDKeyboardModifierMappingSrc"
        private static let destinationKey = "HIDKeyboardModifierMappingDst"

        fileprivate var property: [String: UInt64] {
            [Self.sourceKey: source, Self.destinationKey: destination]
        }

        fileprivate static func source(in property: [String: Any]) -> UInt64? {
            (property[sourceKey] as? NSNumber)?.uint64Value
        }

        init?(property: [String: Any]) {
            guard let source = Self.source(in: property),
                  let destination = (property[Self.destinationKey] as? NSNumber)?.uint64Value else { return nil }
            self.init(source: source, destination: destination)
        }
    }

    public struct Plan {
        public let remaps: [Remap]
        public let eventTapConfig: Config
    }

    private struct Keyboard {
        let service: IOHIDServiceClient
        let previous: [[String: Any]]
        var applied: [Remap]?
    }

    private static let property = "UserKeyMapping" as CFString
    private let ledger: HIDRemapLedger
    private var client: IOHIDEventSystemClient?
    private var keyboards: [UInt64: Keyboard] = [:]

    /// Each concurrently used remapper needs its own ledger owner.
    public init(ledger: HIDRemapLedger = UserDefaultsRemapLedger(owner: "app")) {
        self.ledger = ledger
    }

    /// A keyboard's map without entries that exactly match a remap an earlier process left behind.
    public static func removingLeftovers(_ mappings: [[String: Any]], _ leftovers: Set<Remap>) -> [[String: Any]] {
        guard !leftovers.isEmpty else { return mappings }
        return mappings.filter { Remap(property: $0).map { !leftovers.contains($0) } ?? true }
    }

    private var installed: [Remap] {
        var seen: Set<Remap> = []
        return keyboards.keys.sorted().flatMap { keyboards[$0]?.applied ?? [] }.filter { seen.insert($0).inserted }
    }

    /// Selects HID mappings from the active profile, in rule order, and removes them from
    /// the configuration delivered to Quartz. A physical source has a single HID destination.
    public static func plan(for config: Config) -> Plan {
        guard let profile = config.activeProfile,
              let index = config.profiles.firstIndex(where: { $0.id == profile.id }) else {
            return Plan(remaps: [], eventTapConfig: config)
        }
        var eventTapConfig = config
        var remaps: [Remap] = []
        var sources: Set<UInt64> = []
        for ruleIndex in profile.rules.indices {
            let rule = profile.rules[ruleIndex]
            guard rule.enabled, rule.scope.kind == .everywhere, rule.focus == .any else { continue }
            eventTapConfig.profiles[index].rules[ruleIndex].mappings = rule.mappings.filter { mapping in
                guard let remap = remap(for: mapping) else { return true }
                if sources.insert(remap.source).inserted { remaps.append(remap) }
                return false
            }
        }
        return Plan(remaps: remaps, eventTapConfig: eventTapConfig)
    }

    private static func remap(for mapping: Mapping) -> Remap? {
        guard !mapping.isTapAlone,
              case .key(let input) = mapping.trigger, input.modifiers.isEmpty,
              case .keys(let keys) = mapping.action, keys.count == 1, let output = keys.first,
              output.modifiers.isEmpty,
              isModifierOrCapsLock(input.key) || isModifierOrCapsLock(output.key),
              let source = hidUsage(for: input.key), let destination = hidUsage(for: output.key)
        else { return nil }
        return Remap(source: source, destination: destination)
    }

    private static func isModifierOrCapsLock(_ key: KeyCode) -> Bool {
        key.isModifier || key == KeyCode(57)
    }

    /// Encoded HID page and usage in the layout expected by UserKeyMapping.
    public static func hidUsage(for key: KeyCode) -> UInt64? {
        // Apple reports Fn on its Top Case page. USB Keyboard/Keypad has no Fn usage.
        if key == KeyCode(63) { return 0xFF_0000_0003 }
        return keyboardUsages[key.rawValue].map { 0x07_0000_0000 | $0 }
    }

    // macOS virtual key code → USB Keyboard/Keypad usage (page 7).
    private static let keyboardUsages: [UInt16: UInt64] = [
        0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A, 6: 0x1D, 7: 0x1B, 8: 0x06, 9: 0x19,
        10: 0x64, 11: 0x05, 12: 0x14, 13: 0x1A, 14: 0x08, 15: 0x15, 16: 0x1C, 17: 0x17,
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 22: 0x23, 23: 0x22, 24: 0x2E, 25: 0x26, 26: 0x24,
        27: 0x2D, 28: 0x25, 29: 0x27, 30: 0x30, 31: 0x12, 32: 0x18, 33: 0x2F, 34: 0x0C, 35: 0x13,
        36: 0x28, 37: 0x0F, 38: 0x0D, 39: 0x34, 40: 0x0E, 41: 0x33, 42: 0x31, 43: 0x36, 44: 0x38,
        45: 0x11, 46: 0x10, 47: 0x37, 48: 0x2B, 49: 0x2C, 50: 0x35, 51: 0x2A, 53: 0x29,
        54: 0xE7, 55: 0xE3, 56: 0xE1, 57: 0x39, 58: 0xE2, 59: 0xE0, 60: 0xE5, 61: 0xE6, 62: 0xE4,
        64: 0x6C, 65: 0x63, 67: 0x55, 69: 0x57, 71: 0x53, 72: 0x80, 73: 0x81, 74: 0x7F,
        75: 0x54, 76: 0x58, 78: 0x56, 79: 0x6D, 80: 0x6E, 81: 0x67, 82: 0x62, 83: 0x59, 84: 0x5A,
        85: 0x5B, 86: 0x5C, 87: 0x5D, 88: 0x5E, 89: 0x5F, 90: 0x6F, 91: 0x60, 92: 0x61,
        96: 0x3E, 97: 0x3F, 98: 0x40, 99: 0x3C, 100: 0x41, 101: 0x42, 103: 0x44, 105: 0x68,
        106: 0x6B, 107: 0x69, 109: 0x43, 110: 0x65, 111: 0x45, 113: 0x6A, 114: 0x49, 115: 0x4A,
        116: 0x4B, 117: 0x4C, 118: 0x3D, 119: 0x4D, 120: 0x3B, 121: 0x4E, 122: 0x3A,
        123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52,
    ]

    /// Call from the same thread as restore(). Returns false if any keyboard rejected the update.
    @discardableResult
    public func apply(_ remaps: [Remap], reapply: Bool = false) -> Bool {
        guard !remaps.isEmpty else { return restore() }
        if client == nil { client = IOHIDEventSystemClientCreateSimpleClient(nil) }
        guard let connected = connectedKeyboards() else { return false }
        // Read before recording, which would hide this owner's pairs.
        let leftovers = Set(ledger.leftovers())
        var pending = installed
        pending += remaps.filter { !pending.contains($0) }
        ledger.record(pending)
        var succeeded = true
        let sources = Set(remaps.map(\.source))
        for (registryID, service) in connected {
            if !reapply, keyboards[registryID]?.applied == remaps { continue }
            if keyboards[registryID] == nil {
                let value = IOHIDServiceClientCopyProperty(service, Self.property)
                guard value == nil || value is [[String: Any]] else {
                    succeeded = false
                    continue
                }
                keyboards[registryID] = Keyboard(
                    service: service, previous: Self.removingLeftovers(value as? [[String: Any]] ?? [], leftovers))
            }
            guard let keyboard = keyboards[registryID] else { continue }
            let unrelated = keyboard.previous.filter { property in
                Remap.source(in: property).map { !sources.contains($0) } ?? true
            }
            let merged = unrelated + remaps.map(\.property)
            if IOHIDServiceClientSetProperty(service, Self.property, merged as CFArray) {
                keyboards[registryID]?.applied = remaps
            } else {
                succeeded = false
            }
        }
        keyboards = keyboards.filter { connected[$0.key] != nil }
        ledger.record(installed)
        if succeeded { ledger.forgetLeftovers() }
        return succeeded
    }

    /// Restores each keyboard's original map. Keeps failed restores available for a retry.
    /// With nothing installed, removes leftovers of an earlier process from connected keyboards.
    @discardableResult
    public func restore() -> Bool {
        for (id, keyboard) in keyboards {
            if IOHIDServiceClientSetProperty(keyboard.service, Self.property, keyboard.previous as CFArray) {
                keyboards.removeValue(forKey: id)
            }
        }
        if !keyboards.isEmpty, let connected = connectedKeyboards() {
            keyboards = keyboards.filter { connected[$0.key] != nil }
        }
        guard keyboards.isEmpty else {
            ledger.record(installed)
            return false
        }
        ledger.clear()
        let cleaned = removeLeftovers()
        client = nil
        return cleaned
    }

    private func removeLeftovers() -> Bool {
        let leftovers = Set(ledger.leftovers())
        guard !leftovers.isEmpty else { return true }
        if client == nil { client = IOHIDEventSystemClientCreateSimpleClient(nil) }
        guard let connected = connectedKeyboards() else { return false }
        var succeeded = true
        for service in connected.values {
            guard let value = IOHIDServiceClientCopyProperty(service, Self.property) else { continue }
            guard let current = value as? [[String: Any]] else {
                succeeded = false
                continue
            }
            let cleaned = Self.removingLeftovers(current, leftovers)
            if cleaned.count != current.count,
               !IOHIDServiceClientSetProperty(service, Self.property, cleaned as CFArray) {
                succeeded = false
            }
        }
        if succeeded { ledger.forgetLeftovers() }
        return succeeded
    }

    private func connectedKeyboards() -> [UInt64: IOHIDServiceClient]? {
        guard let client, let services = IOHIDEventSystemClientCopyServices(client) else { return nil }
        var keyboards: [UInt64: IOHIDServiceClient] = [:]
        for object in services as [AnyObject] {
            guard CFGetTypeID(object) == IOHIDServiceClientGetTypeID() else { continue }
            let service = object as! IOHIDServiceClient
            // Generic Desktop page, Keyboard usage.
            guard IOHIDServiceClientConformsTo(service, 0x01, 0x06) != 0,
                  let id = IOHIDServiceClientGetRegistryID(service) as? NSNumber else { continue }
            keyboards[id.uint64Value] = service
        }
        return keyboards
    }
}
