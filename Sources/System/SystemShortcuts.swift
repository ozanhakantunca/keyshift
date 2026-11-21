import CoreGraphics
import Darwin
import Foundation
import KeyshiftCore

public enum SystemShortcuts {
    private struct Binding {
        let key: KeyCode
        let flags: UInt64

        var combo: KeyCombo {
            var modifiers = SystemShortcuts.modifiers(fromMask: flags)
            // The preference records the intrinsic Fn bit for arrows and function keys.
            if EventCodec.hasIntrinsicFnFlag(key) { modifiers.remove(.function) }
            return KeyCombo(key, modifiers)
        }
    }

    /// Enabled keyboard shortcuts. WindowServer supplies the defaults absent from the preferences.
    public static func enabled() -> [KeyCombo: String] {
        let preferences = readPreferences()
        var bindings = preferenceBindings(preferences)
        if LiveShortcuts.isAvailable {
            for id in 0...300 where preferences[String(id)] == nil {
                bindings[id] = LiveShortcuts.binding(for: id)
            }
        }
        return namedCombos(bindings)
    }

    /// Parses the contents of AppleSymbolicHotKeys, without consulting the current session.
    public static func parse(_ preferences: [String: Any]) -> [KeyCombo: String] {
        namedCombos(preferenceBindings(preferences))
    }

    /// The symbolic hotkey modifier word is an NSEvent modifier mask (same bits as CGEventFlags).
    static func modifiers(fromMask mask: UInt64) -> Modifiers {
        var result: Modifiers = []
        if mask & 0x20000 != 0 { result.insert(.shift) }
        if mask & 0x40000 != 0 { result.insert(.control) }
        if mask & 0x80000 != 0 { result.insert(.option) }
        if mask & 0x100000 != 0 { result.insert(.command) }
        if mask & 0x800000 != 0 { result.insert(.function) }
        return result
    }

    static func currentCombo(for id: Int) -> KeyCombo? {
        // The live setting includes user overrides and reflects whether the shortcut is enabled.
        if LiveShortcuts.isAvailable { return LiveShortcuts.binding(for: id)?.combo }
        return preferenceBinding(readPreferences()[String(id)])?.combo
    }

    private static func readPreferences() -> [String: Any] {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
            as? [String: Any] ?? [:]
    }

    private static func preferenceBindings(_ preferences: [String: Any]) -> [Int: Binding] {
        var result: [Int: Binding] = [:]
        for (id, entry) in preferences {
            guard let id = Int(id), let binding = preferenceBinding(entry) else { continue }
            result[id] = binding
        }
        return result
    }

    private static func preferenceBinding(_ entry: Any?) -> Binding? {
        guard let entry = entry as? [String: Any], (entry["enabled"] as? NSNumber) == NSNumber(value: true),
              let value = entry["value"] as? [String: Any], value["type"] as? String == "standard",
              let parameters = value["parameters"] as? [Int], parameters.count >= 3,
              let key = UInt16(exactly: parameters[1]), key != UInt16.max,
              let flags = UInt64(exactly: parameters[2]) else { return nil }
        return Binding(key: KeyCode(key), flags: flags)
    }

    private static func namedCombos(_ bindings: [Int: Binding]) -> [KeyCombo: String] {
        var namesByCombo: [KeyCombo: [String]] = [:]
        for id in bindings.keys.sorted() {
            // Unknown ids are left out rather than shown as "System Shortcut N". Hardware brightness and
            // keyboard-backlight keys are media keys, not F-key events, so they cannot conflict.
            guard !nonConflictingIDs.contains(id), let name = names[id], let combo = bindings[id]?.combo else { continue }
            if namesByCombo[combo]?.contains(name) != true { namesByCombo[combo, default: []].append(name) }
        }
        return namesByCombo.mapValues { $0.joined(separator: " / ") }
    }

    private static let nonConflictingIDs: Set<Int> = [53, 54, 55, 56]

    static let names: [Int: String] = {
        var names = [
            7: "Move Focus to the Menu Bar", 8: "Move Focus to the Dock", 9: "Move Focus to Active or Next Window",
            10: "Move Focus to the Window Toolbar", 11: "Move Focus to the Floating Window",
            12: "Turn Keyboard Navigation On or Off", 13: "Move Focus to Status Menus",
            15: "Turn Zoom On or Off", 17: "Zoom In", 19: "Zoom Out", 21: "Invert Colors",
            23: "Increase Contrast", 25: "Decrease Contrast",
            27: "Move Focus to the Next Window in the App",
            28: "Save Screenshot", 29: "Copy Screenshot",
            30: "Save Screenshot of Selection", 31: "Copy Screenshot of Selection",
            32: "Mission Control", 33: "Application Windows",
            34: "Mission Control", 35: "Application Windows",
            36: "Show Desktop", 37: "Show Desktop",
            52: "Turn Dock Hiding On or Off",
            53: "Decrease Display Brightness", 54: "Increase Display Brightness",
            55: "Decrease Keyboard Brightness", 56: "Increase Keyboard Brightness",
            57: "Change the Way Tabbing Moves Focus", 59: "Turn VoiceOver On or Off",
            60: "Select the Previous Input Source", 61: "Select the Next Input Source",
            64: "Spotlight", 65: "Finder Search",
            70: "Look Up", 98: "Show Help Menu",
            79: "Move Left a Space", 80: "Move Left a Space",
            81: "Move Right a Space", 82: "Move Right a Space",
            160: "Launchpad", 162: "Show Dashboard", 163: "Notification Center",
            175: "Do Not Disturb",
            176: "Dictation", 179: "Dictation", 184: "Screenshot and Recording Options",
            190: "Quick Note",
        ]
        for id in 118...133 { names[id] = "Switch to Desktop \(id - 117)" }
        return names
    }()

    // Adapted from Vitrin's GPL-3.0 symbolic-hotkey reader. Read only.
    private enum LiveShortcuts {
        typealias IsEnabled = @convention(c) (Int32) -> Bool
        typealias GetValue = @convention(c) (
            Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt64>
        ) -> Int32

        private static let library = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL
        )
        private static let isEnabled = resolve("IsSymbolicHotKeyEnabled", as: IsEnabled.self)
        private static let getValue = resolve("GetSymbolicHotKeyValue", as: GetValue.self)
        static var isAvailable: Bool { isEnabled != nil && getValue != nil }

        private static func resolve<T>(_ name: String, as type: T.Type) -> T? {
            if let fn = library.flatMap({ dlsym($0, "SLS" + name) })
                ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGS" + name) {
                return unsafeBitCast(fn, to: type)
            }
            return nil
        }

        static func binding(for id: Int) -> Binding? {
            guard let id = Int32(exactly: id), isEnabled?(id) == true, let getValue else { return nil }
            var character: UInt16 = 0
            var key: UInt16 = 0
            var flags: UInt64 = 0
            guard getValue(id, &character, &key, &flags) == 0, key != UInt16.max,
                  key != 0 || character != UInt16.max || flags != 0 else { return nil }
            return Binding(key: KeyCode(key), flags: flags)
        }
    }
}
