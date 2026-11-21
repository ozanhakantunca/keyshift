import Foundation

/// Modifier flags, side-insensitive. Sided modifiers (left_cmd, right_alt…) exist only as `KeyCode`s.
public struct Modifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
    public static let function = Modifiers(rawValue: 1 << 4)

    /// Canonical order used when printing combos: ctrl, alt, shift, cmd, fn.
    public static let canonical: [(flag: Modifiers, name: String, symbol: String)] = [
        (.control, "ctrl", "⌃"),
        (.option, "alt", "⌥"),
        (.shift, "shift", "⇧"),
        (.command, "cmd", "⌘"),
        (.function, "fn", "fn"),
    ]

    /// Accepted spellings (lowercased). Windows/Linux names map to their Mac physical equivalents:
    /// `win`/`super`/`meta` → command (same physical key position on PC keyboards), `alt` → option.
    public static let aliases: [String: Modifiers] = [
        "ctrl": .control, "control": .control, "ctl": .control, "⌃": .control, "^": .control,
        "alt": .option, "opt": .option, "option": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "cmd": .command, "command": .command, "⌘": .command, "win": .command, "super": .command, "meta": .command,
        "fn": .function, "function": .function, "globe": .function,
    ]

    public var names: [String] { Self.canonical.filter { contains($0.flag) }.map(\.name) }
    public var symbols: String { Self.canonical.filter { contains($0.flag) }.map(\.symbol).joined() }
}

/// A macOS virtual key code (`kVK_*`), layout-independent (physical position on an ANSI keyboard).
public struct KeyCode: RawRepresentable, Sendable, Hashable, Codable, Comparable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ raw: UInt16) { self.rawValue = raw }
    public static func < (a: KeyCode, b: KeyCode) -> Bool { a.rawValue < b.rawValue }

    /// Canonical name, e.g. "c", "home", "left_cmd", or "code:110" if unnamed.
    public var name: String { KeyNames.name(for: self) }

    /// The modifier this key produces when it is itself a modifier key (left_cmd → .command).
    public var modifier: Modifiers? { KeyNames.modifierKeys[self] }
    public var isModifier: Bool { modifier != nil }

    public static func named(_ s: String) -> KeyCode? { KeyNames.code(for: s) }
}

/// Key name table. Names follow Windows/Linux conventions where Mac names are ambiguous:
/// `backspace` = Mac "delete" (51), `delete` = forward delete (117), `enter`/`return` = 36.
public enum KeyNames {
    /// Canonical name → code. The first name listed for a code is its canonical name.
    public static let table: [(String, UInt16)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
        ("section", 10), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17),
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("equal", 24), ("9", 25), ("7", 26),
        ("minus", 27), ("8", 28), ("0", 29), ("right_bracket", 30), ("o", 31), ("u", 32), ("left_bracket", 33),
        ("i", 34), ("p", 35), ("return", 36), ("l", 37), ("j", 38), ("quote", 39), ("k", 40), ("semicolon", 41),
        ("backslash", 42), ("comma", 43), ("slash", 44), ("n", 45), ("m", 46), ("period", 47), ("tab", 48),
        ("space", 49), ("grave", 50), ("backspace", 51), ("escape", 53),
        ("right_cmd", 54), ("left_cmd", 55), ("left_shift", 56), ("caps_lock", 57), ("left_alt", 58),
        ("left_ctrl", 59), ("right_shift", 60), ("right_alt", 61), ("right_ctrl", 62), ("fn", 63),
        ("f17", 64), ("keypad_period", 65), ("keypad_multiply", 67), ("keypad_plus", 69), ("keypad_clear", 71),
        ("volume_up", 72), ("volume_down", 73), ("mute", 74), ("keypad_divide", 75), ("keypad_enter", 76),
        ("keypad_minus", 78), ("f18", 79), ("f19", 80), ("keypad_equal", 81),
        ("keypad_0", 82), ("keypad_1", 83), ("keypad_2", 84), ("keypad_3", 85), ("keypad_4", 86),
        ("keypad_5", 87), ("keypad_6", 88), ("keypad_7", 89), ("f20", 90), ("keypad_8", 91), ("keypad_9", 92),
        ("f5", 96), ("f6", 97), ("f7", 98), ("f3", 99), ("f8", 100), ("f9", 101), ("f11", 103), ("f13", 105),
        ("f16", 106), ("f14", 107), ("f10", 109), ("menu", 110), ("f12", 111), ("f15", 113), ("insert", 114),
        ("home", 115), ("page_up", 116), ("delete", 117), ("f4", 118), ("end", 119), ("f2", 120),
        ("page_down", 121), ("f1", 122), ("left", 123), ("right", 124), ("down", 125), ("up", 126),
    ]

    public static let aliases: [String: UInt16] = [
        "enter": 36, "esc": 53, "bksp": 51, "delete_or_backspace": 51, "del": 117, "delete_forward": 117,
        "forward_delete": 117, "help": 114, "pgup": 116, "pgdn": 121, "pageup": 116, "pagedown": 121,
        "left_arrow": 123, "right_arrow": 124, "down_arrow": 125, "up_arrow": 126,
        "`": 50, "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44,
        "lcmd": 55, "rcmd": 54, "left_command": 55, "right_command": 54, "left_win": 55, "right_win": 54,
        "left_option": 58, "right_option": 61, "lalt": 58, "ralt": 61, "left_control": 59, "right_control": 62,
        "lctrl": 59, "rctrl": 62, "lshift": 56, "rshift": 60, "capslock": 57, "caps": 57, "application": 110,
        "grave_accent_and_tilde": 50, "non_us_backslash": 10,
    ]

    public static let modifierKeys: [KeyCode: Modifiers] = [
        KeyCode(54): .command, KeyCode(55): .command, KeyCode(56): .shift, KeyCode(60): .shift,
        KeyCode(58): .option, KeyCode(61): .option, KeyCode(59): .control, KeyCode(62): .control,
        KeyCode(63): .function,
    ]

    private static let byName: [String: UInt16] = {
        var d = aliases
        for (n, c) in table { d[n] = c }
        return d
    }()

    private static let byCode: [UInt16: String] = {
        var d: [UInt16: String] = [:]
        for (n, c) in table where d[c] == nil { d[c] = n }
        return d
    }()

    public static func code(for name: String) -> KeyCode? {
        let s = name.lowercased()
        if let c = byName[s] { return KeyCode(c) }
        if s.hasPrefix("code:"), let n = UInt16(s.dropFirst(5)) { return KeyCode(n) }
        return nil
    }

    public static func name(for code: KeyCode) -> String { byCode[code.rawValue] ?? "code:\(code.rawValue)" }
}

/// One key plus held modifiers, e.g. `ctrl+shift+c`. Text form: `mod+mod+key`, case-insensitive.
public struct KeyCombo: Sendable, Hashable, Codable, CustomStringConvertible {
    public var key: KeyCode
    public var modifiers: Modifiers

    public init(_ key: KeyCode, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public init?(parsing text: String) {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        // "ctrl++" → key "+" is not supported; use "equal"/"shift+equal".
        guard let last = parts.last, !last.isEmpty else { return nil }
        var mods: Modifiers = []
        for p in parts.dropLast() {
            guard let m = Modifiers.aliases[p] else { return nil }
            mods.insert(m)
        }
        // A bare modifier name as the key ("cmd") means the left-side key.
        if let key = KeyCode.named(last) {
            self.init(key, mods)
        } else if let m = Modifiers.aliases[last] {
            let left: [Modifiers: UInt16] = [.control: 59, .option: 58, .shift: 56, .command: 55, .function: 63]
            self.init(KeyCode(left[m]!), mods)
        } else {
            return nil
        }
    }

    public var description: String { (modifiers.names + [key.name]).joined(separator: "+") }
    /// e.g. "⌃⇧C"
    public var displayString: String { modifiers.symbols + KeyDisplay.label(for: key) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = KeyCombo(parsing: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad key combo: \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

public enum MouseButton: String, Sendable, Hashable, Codable, CaseIterable {
    case left = "left_click", right = "right_click", middle = "middle_click", button4, button5
}

/// What a rule listens for.
public enum Trigger: Sendable, Hashable, CustomStringConvertible {
    case key(KeyCombo)
    case mouse(MouseButton, Modifiers)

    public init?(parsing text: String) {
        let parts = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if let last = parts.last, let b = MouseButton(rawValue: last) {
            var mods: Modifiers = []
            for p in parts.dropLast() {
                guard let m = Modifiers.aliases[p] else { return nil }
                mods.insert(m)
            }
            self = .mouse(b, mods)
        } else if let c = KeyCombo(parsing: text) {
            self = .key(c)
        } else {
            return nil
        }
    }

    public var modifiers: Modifiers {
        switch self { case .key(let c): return c.modifiers; case .mouse(_, let m): return m }
    }

    public var description: String {
        switch self {
        case .key(let c): return c.description
        case .mouse(let b, let m): return (m.names + [b.rawValue]).joined(separator: "+")
        }
    }
}

/// Human-facing key labels for the UI (Windows-style names, Mac symbols for modifiers).
public enum KeyDisplay {
    public static func label(for key: KeyCode) -> String {
        let special: [String: String] = [
            "return": "Enter", "backspace": "Backspace", "delete": "Delete", "escape": "Esc", "tab": "Tab",
            "space": "Space", "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "Home", "end": "End",
            "page_up": "PgUp", "page_down": "PgDn", "left_cmd": "Left ⌘", "right_cmd": "Right ⌘",
            "left_alt": "Left ⌥", "right_alt": "Right ⌥", "left_ctrl": "Left ⌃", "right_ctrl": "Right ⌃",
            "left_shift": "Left ⇧", "right_shift": "Right ⇧", "caps_lock": "Caps Lock", "fn": "fn",
        ]
        let n = key.name
        if let s = special[n] { return s }
        return n.count == 1 ? n.uppercased() : n.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
