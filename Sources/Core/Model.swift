import Foundation

/// Built-in system actions, executed by KeyshiftSystem.ActionExecutor.
public enum SystemAction: String, Sendable, Hashable, Codable, CaseIterable {
    case launchpad, missionControl = "mission_control", appWindows = "app_windows", showDesktop = "show_desktop"
    case spotlight, lockScreen = "lock_screen", sleepDisplay = "sleep_display", logout
    case screenshot, screenshotArea = "screenshot_area", screenshotWindow = "screenshot_window"
    case notificationCenter = "notification_center", forceQuit = "force_quit"
    /// Window management for the focused window, via Accessibility (see KeyshiftSystem.WindowTiler).
    case tileLeft = "tile_left", tileRight = "tile_right", tileTop = "tile_top", tileBottom = "tile_bottom"
    case maximize, center
}

/// What happens when a trigger fires.
public enum Action: Sendable, Hashable {
    /// Send these key combos in order (usually one). Modifiers held on input that the rule passes
    /// through (see `Rule.passthrough`) are added to every emitted combo.
    case keys([KeyCombo])
    /// Send a mouse click with these modifiers instead (ctrl+left_click → cmd+left_click).
    case mouse(MouseButton, Modifiers)
    /// Open/activate an app by name ("Ghostty"), bundle id, or path.
    case openApp(String)
    case openURL(String)
    /// Run with /bin/sh -c, detached; output discarded.
    case shell(String)
    case system(SystemAction)
    /// Swallow the input entirely.
    case none
}

/// One trigger → action pair inside a rule.
public struct Mapping: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var trigger: Trigger
    /// Action when pressed (for modifier-key triggers with `hold`, the action when tapped alone).
    public var action: Action
    /// Only for triggers that are bare modifier keys (e.g. `left_cmd`): if set, the key keeps
    /// behaving as `hold` (normally itself) while held/combined, and `action` runs only when it is
    /// pressed and released alone within `Rule.tapTimeout`. Example: `left_cmd: { tap: launchpad }`.
    public var isTapAlone: Bool

    public init(id: UUID = UUID(), trigger: Trigger, action: Action, isTapAlone: Bool = false) {
        self.id = id
        self.trigger = trigger
        self.action = action
        self.isTapAlone = isTapAlone
    }
}

/// App scope for a rule. Entries are bundle ids, path fragments (any entry containing "/", matched
/// case-insensitively as a substring of the frontmost app's path), or names of `Config.appGroups`
/// (optionally "@"-prefixed).
public struct AppScope: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable { case everywhere, only, except }
    public var kind: Kind
    public var apps: [String]

    public init(_ kind: Kind = .everywhere, _ apps: [String] = []) {
        self.kind = kind
        self.apps = apps
    }

    public static let everywhere = AppScope()

    /// Whether a (resolved) scope entry is a path fragment rather than a bundle id.
    public static func isPathFragment(_ entry: String) -> Bool { entry.contains("/") }
}

/// Extra condition on the focused UI element (resolved lazily through AX by the system layer).
public enum FocusCondition: String, Sendable, Hashable, Codable {
    case any
    /// Focus is in an editable text field/area.
    case textInput = "text_input"
    /// Focus is NOT in an editable text field/area (e.g. Finder file list).
    case notTextInput = "not_text_input"
}

/// A named group of mappings sharing conditions. Rules are evaluated top to bottom; the first
/// mapping that matches wins.
public struct Rule: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var scope: AppScope
    public var focus: FocusCondition
    /// Input modifiers that are allowed in addition to the trigger's own and copied to the output.
    /// Default `[.shift]`: `home → cmd+left` also makes `shift+home → cmd+shift+left`.
    /// An exact trigger match (e.g. an explicit `shift+home` mapping) always wins over a passthrough match.
    public var passthrough: Modifiers
    public var mappings: [Mapping]

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, scope: AppScope = .everywhere,
                focus: FocusCondition = .any, passthrough: Modifiers = [.shift], mappings: [Mapping] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.scope = scope
        self.focus = focus
        self.passthrough = passthrough
        self.mappings = mappings
    }
}

public struct Profile: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var rules: [Rule]

    public init(id: UUID = UUID(), name: String, rules: [Rule] = []) {
        self.id = id
        self.name = name
        self.rules = rules
    }
}

public struct Settings: Sendable, Hashable {
    /// Max press duration for tap-alone mappings.
    public var tapTimeoutMs: Int = 500
    public var showMenuBarIcon: Bool = true
    public var launchAtLogin: Bool = true
    public init() {}
}

/// The whole user configuration (one file: ~/.config/keyshift/config.yaml).
public struct Config: Sendable, Hashable {
    public var version: Int = 1
    public var selectedProfile: String?
    public var settings = Settings()
    /// name → bundle ids. Referenced from `AppScope.apps` by name (or "@name").
    public var appGroups: [String: [String]] = [:]
    public var profiles: [Profile] = []

    public init(selectedProfile: String? = nil, appGroups: [String: [String]] = [:], profiles: [Profile] = []) {
        self.selectedProfile = selectedProfile
        self.appGroups = appGroups
        self.profiles = profiles
    }

    public var activeProfile: Profile? {
        profiles.first { $0.name == selectedProfile } ?? profiles.first
    }

    /// Expand group references into bundle ids and path fragments (lowercased, deduplicated, order kept).
    public func resolveApps(_ entries: [String]) -> [String] {
        var out: [String] = []
        for e in entries {
            let name = e.hasPrefix("@") ? String(e.dropFirst()) : e
            let ids = appGroups[name] ?? (e.hasPrefix("@") ? [] : [e])
            for id in ids.map({ $0.lowercased() }) where !out.contains(id) { out.append(id) }
        }
        return out
    }
}
