import Carbon.HIToolbox
import Foundation
import KeyshiftCore

/// Reads the active keyboard layout so config keys follow the character on the keycap, not the US position.
public enum KeyboardLayout {
    public static let changeNotification = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    /// Characters typed under ⌘ by the US layout, at the key codes the config names refer to.
    static let reference: [KeyCode: String] = {
        var table: [KeyCode: String] = [:]
        let letters: [(String, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28),
            ("0", 29), ("=", 24), ("-", 27), ("]", 30), ("[", 33), ("'", 39), (";", 41), ("\\", 42),
            (",", 43), ("/", 44), (".", 47), ("`", 50),
        ]
        for (character, code) in letters { table[KeyCode(code)] = character }
        return table
    }()

    public static func currentMap() -> KeyLayoutMap {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return .identity }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return .identity }
        var current: [KeyCode: String] = [:]
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for code in reference.keys {
                var dead: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, code.rawValue, UInt16(kUCKeyActionDisplay),
                                            UInt32(cmdKey >> 8), UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, characters.count,
                                            &length, &characters)
                if status == noErr, length > 0 {
                    current[code] = String(utf16CodeUnits: characters, count: length).lowercased()
                }
            }
        }
        return KeyLayoutMap.make(reference: reference, current: current)
    }
}
