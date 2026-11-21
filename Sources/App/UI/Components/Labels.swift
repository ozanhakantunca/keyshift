import Foundation
import KeyshiftConfig
import KeyshiftCore

/// User-facing names for model values. Every string goes through the localization table.
enum UIText {
    static func name(_ action: SystemAction) -> String {
        switch action {
        case .launchpad: return String(localized: "Launchpad")
        case .missionControl: return String(localized: "Mission Control")
        case .appWindows: return String(localized: "App windows (App Exposé)")
        case .showDesktop: return String(localized: "Show desktop")
        case .spotlight: return String(localized: "Spotlight search")
        case .lockScreen: return String(localized: "Lock screen")
        case .sleepDisplay: return String(localized: "Turn display off")
        case .logout: return String(localized: "Log out")
        case .screenshot: return String(localized: "Screenshot of the whole screen")
        case .screenshotArea: return String(localized: "Screenshot of an area")
        case .screenshotWindow: return String(localized: "Screenshot of a window")
        case .notificationCenter: return String(localized: "Notification Center")
        case .forceQuit: return String(localized: "Force Quit apps")
        case .tileLeft: return String(localized: "Tile window to the left half")
        case .tileRight: return String(localized: "Tile window to the right half")
        case .tileTop: return String(localized: "Tile window to the top half")
        case .tileBottom: return String(localized: "Tile window to the bottom half")
        case .maximize: return String(localized: "Maximize window")
        case .center: return String(localized: "Center window")
        }
    }

    static func symbol(_ action: SystemAction) -> String {
        switch action {
        case .launchpad: return "square.grid.3x3.fill"
        case .missionControl: return "rectangle.3.group"
        case .appWindows: return "rectangle.stack"
        case .showDesktop: return "menubar.dock.rectangle"
        case .spotlight: return "magnifyingglass"
        case .lockScreen: return "lock.fill"
        case .sleepDisplay: return "display"
        case .logout: return "rectangle.portrait.and.arrow.right"
        case .screenshot: return "camera.viewfinder"
        case .screenshotArea: return "rectangle.dashed"
        case .screenshotWindow: return "macwindow"
        case .notificationCenter: return "bell.fill"
        case .forceQuit: return "xmark.octagon"
        case .tileLeft: return "rectangle.lefthalf.inset.filled"
        case .tileRight: return "rectangle.righthalf.inset.filled"
        case .tileTop: return "rectangle.tophalf.inset.filled"
        case .tileBottom: return "rectangle.bottomhalf.inset.filled"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .center: return "rectangle.center.inset.filled"
        }
    }

    static func name(_ button: MouseButton) -> String {
        switch button {
        case .left: return String(localized: "Left click")
        case .right: return String(localized: "Right click")
        case .middle: return String(localized: "Middle click")
        case .button4: return String(localized: "Mouse button 4")
        case .button5: return String(localized: "Mouse button 5")
        }
    }

    static func name(_ focus: FocusCondition) -> String {
        switch focus {
        case .any: return String(localized: "Always")
        case .textInput: return String(localized: "Only when typing")
        case .notTextInput: return String(localized: "Only when not typing")
        }
    }

    static func badge(_ focus: FocusCondition) -> (text: String, symbol: String)? {
        switch focus {
        case .any: return nil
        case .textInput: return (String(localized: "While typing"), "character.cursor.ibeam")
        case .notTextInput: return (String(localized: "Not while typing"), "cursorarrow")
        }
    }

    static func name(_ kind: Conflict.Kind) -> String {
        switch kind {
        case .duplicate: return String(localized: "Same key used twice")
        case .shadowed: return String(localized: "Caught by an earlier rule")
        case .systemShortcut: return String(localized: "macOS shortcuts you override")
        }
    }

    static func symbol(_ kind: Conflict.Kind) -> String {
        switch kind {
        case .duplicate: return "square.on.square"
        case .shadowed: return "arrow.up.to.line"
        case .systemShortcut: return "info.circle"
        }
    }

    static func modifierName(_ flag: Modifiers) -> String {
        switch flag {
        case .control: return String(localized: "Control")
        case .option: return String(localized: "Option")
        case .shift: return String(localized: "Shift")
        case .command: return String(localized: "Command")
        default: return String(localized: "Fn")
        }
    }

    /// Key label for the keycap pill. Adds names for Apple keys that have no entry in `KeyNames`.
    static func keyLabel(_ key: KeyCode) -> String {
        switch key.rawValue {
        case 131: return String(localized: "Launchpad key")
        case 160: return String(localized: "Mission Control key")
        case 110: return String(localized: "Menu")
        case 114: return String(localized: "Insert")
        default:
            let punctuation: [String: String] = [
                "left_bracket": "[", "right_bracket": "]", "minus": "-", "equal": "=", "semicolon": ";",
                "quote": "'", "backslash": "\\", "comma": ",", "period": ".", "slash": "/", "grave": "`", "section": "§",
            ]
            return punctuation[key.name] ?? KeyDisplay.label(for: key)
        }
    }

    static func modifierSymbols(_ modifiers: Modifiers) -> [String] {
        Modifiers.canonical.filter { modifiers.contains($0.flag) }.map(\.symbol)
    }

    /// Compact single-line form, e.g. "⌃C", "⌘ Left click".
    static func display(_ trigger: Trigger) -> String {
        switch trigger {
        case .key(let combo): return combo.modifiers.symbols + keyLabel(combo.key)
        case .mouse(let button, let mods): return (mods.symbols.isEmpty ? "" : mods.symbols + " ") + name(button)
        }
    }

    static func display(_ combo: KeyCombo) -> String { display(.key(combo)) }

    /// "Windows habits: Ctrl shortcuts, …" → ("Windows habits", "Ctrl shortcuts, …").
    static func splitPresetDescription(_ preset: PresetInfo) -> (title: String, detail: String) {
        guard let description = preset.description, !description.isEmpty else { return (preset.name, "") }
        if let range = description.range(of: ": ") {
            let detail = String(description[range.upperBound...])
            return (String(description[..<range.lowerBound]), detail.prefix(1).uppercased() + detail.dropFirst())
        }
        return (preset.name, description)
    }

    static func presetSymbol(_ id: String) -> String {
        let id = id.lowercased()
        if id.contains("windows") { return "pc" }
        if id.contains("linux") || id.contains("gnome") { return "terminal" }
        if id.contains("terminal") { return "apple.terminal" }
        return "keyboard"
    }
}

/// Describes conflicts in plain language, with the other rule's name where there is one.
@MainActor
enum ConflictText {
    static func message(_ conflict: Conflict, profile: Profile?, systemShortcuts: [KeyCombo: String]) -> String {
        let trigger = UIText.display(conflict.trigger)
        switch conflict.kind {
        case .duplicate:
            if conflict.otherRuleID == conflict.ruleID {
                return String(localized: "\(trigger) appears twice in this rule; only the first one is used.")
            }
            let other = ruleName(conflict.otherRuleID, in: profile)
            return String(localized: "\(trigger) is already used by rule '\(other)', which comes first.")
        case .shadowed:
            let other = ruleName(conflict.otherRuleID, in: profile)
            return String(localized: "Rule '\(other)' catches \(trigger) first, because it lets extra modifier keys through.")
        case .systemShortcut:
            if case .key(let combo) = conflict.trigger, let title = systemShortcuts[combo] {
                return String(localized: "Overrides macOS shortcut '\(title)' (\(trigger)).")
            }
            return conflict.message
        }
    }

    private static func ruleName(_ id: UUID?, in profile: Profile?) -> String {
        profile?.rules.first { $0.id == id }?.name ?? String(localized: "another rule")
    }
}
