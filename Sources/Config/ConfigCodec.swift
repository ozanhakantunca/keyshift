import Foundation
import KeyshiftCore
import Yams

public struct Diagnostic: Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable {
        case warning, error
    }

    public let line: Int?
    public let message: String
    public let severity: Severity

    public init(line: Int? = nil, message: String, severity: Severity = .error) {
        self.line = line
        self.message = message
        self.severity = severity
    }
}

/// The result of decoding a config document.
public struct DecodedConfig: Sendable {
    public var config: Config
    public var diagnostics: [Diagnostic]
    /// False when nothing could be read: a YAML syntax error, too many nodes, or a root that is
    /// not a mapping. `config` is then empty because of the error, not because the file is empty.
    public var hasUsableRoot: Bool

    public init(config: Config, diagnostics: [Diagnostic], hasUsableRoot: Bool) {
        self.config = config
        self.diagnostics = diagnostics
        self.hasUsableRoot = hasUsableRoot
    }
}

public enum ConfigCodec {
    /// Upper bound on YAML nodes after alias expansion. Real configs have a few thousand at most;
    /// the cap stops alias "bombs" that expand a small file into billions of nodes.
    public static let maximumNodeCount = 100_000

    public static func decode(_ yaml: String) -> (Config, [Diagnostic]) {
        let decoded = decodeDocument(yaml)
        return (decoded.config, decoded.diagnostics)
    }

    public static func decodeDocument(_ yaml: String) -> DecodedConfig {
        let root: Node
        do {
            guard let composed = try Yams.compose(yaml: yaml) else {
                return DecodedConfig(config: Config(), diagnostics: [], hasUsableRoot: true)
            }
            root = composed
        } catch {
            return DecodedConfig(config: Config(), diagnostics: syntaxDiagnostics(error), hasUsableRoot: false)
        }
        guard !exceedsNodeLimit(root) else {
            let message = "Config has more than \(maximumNodeCount) YAML nodes after expanding aliases. "
                + "Remove YAML anchors and aliases (&name, *name)."
            return DecodedConfig(config: Config(), diagnostics: [Diagnostic(message: message)], hasUsableRoot: false)
        }
        let (config, diagnostics) = decode(root)
        return DecodedConfig(config: config, diagnostics: diagnostics, hasUsableRoot: root.mapping != nil)
    }

    /// Counts nodes with an explicit stack and stops at the limit, so expanded aliases are never walked in full.
    static func exceedsNodeLimit(_ root: Node, limit: Int = maximumNodeCount) -> Bool {
        var stack = [root]
        var count = 0
        while let node = stack.popLast() {
            count += 1
            if count > limit { return true }
            switch node {
            case .mapping(let mapping):
                for (key, value) in mapping {
                    stack.append(key)
                    stack.append(value)
                }
            case .sequence(let sequence):
                stack.append(contentsOf: sequence)
            case .scalar, .alias:
                break
            }
        }
        return false
    }

    private static func syntaxDiagnostics(_ error: Error) -> [Diagnostic] {
        guard let error = error as? YamlError else { return [Diagnostic(message: error.localizedDescription)] }
        switch error {
        case let .scanner(_, problem, mark, _), let .parser(_, problem, mark, _),
             let .composer(_, problem, mark, _):
            return [Diagnostic(line: mark.line, message: problem)]
        case let .duplicatedKeysInMapping(duplicates, _):
            let diagnostics = duplicates.values.flatMap { nodes in
                nodes.sorted { ($0.mark?.line ?? 0, $0.mark?.column ?? 0) <
                    ($1.mark?.line ?? 0, $1.mark?.column ?? 0) }.dropFirst().map { node in
                    Diagnostic(line: node.mark?.line, message: "Duplicate YAML key '\(node.scalar?.string ?? "")'.")
                }
            }
            return diagnostics.sorted { ($0.line ?? 0, $0.message) < ($1.line ?? 0, $1.message) }
        default:
            return [Diagnostic(message: String(describing: error))]
        }
    }

    public static func encode(_ config: Config) -> String {
        ConfigEncoder.encode(config)
    }

    static func decode(_ root: Node) -> (Config, [Diagnostic]) {
        var decoder = ConfigDecoder()
        let config = decoder.config(root)
        return (config, decoder.diagnostics)
    }
}

private struct ConfigDecoder {
    var diagnostics: [Diagnostic] = []

    mutating func config(_ node: Node) -> Config {
        var config = Config()
        guard let fields = fields(node, allowed: ["version", "profile", "settings", "app_groups", "profiles", "description"],
                                  label: "Config") else { return config }
        if let version = fields["version"] {
            if let number = version.int, number > 0 {
                config.version = number
                if number != 1 { report(version, "Config version \(number) is newer than supported version 1.", .warning) }
            } else {
                report(version, "Version must be a positive integer.")
            }
        }
        if let profile = fields["profile"] {
            config.selectedProfile = nonemptyString(profile, label: "Selected profile")
        }
        if let settings = fields["settings"] {
            config.settings = self.settings(settings)
        }
        if let groups = fields["app_groups"] {
            if let mapping = groups.mapping {
                for (key, value) in mapping {
                    if let name = nonemptyString(key, label: "App group name"),
                       let apps = stringList(value, label: "App group '\(name)'") {
                        config.appGroups[name] = apps
                    }
                }
            } else {
                report(groups, "App groups must be a mapping.")
            }
        }
        if let profiles = fields["profiles"] {
            if let sequence = profiles.sequence {
                config.profiles = sequence.compactMap { profile($0) }
            } else {
                report(profiles, "Profiles must be a list.")
            }
        }
        return config
    }

    mutating func settings(_ node: Node) -> Settings {
        var settings = Settings()
        guard let fields = fields(node, allowed: ["tap_timeout_ms", "menu_bar_icon", "launch_at_login"],
                                  label: "Settings") else { return settings }
        if let timeout = fields["tap_timeout_ms"] {
            if let milliseconds = timeout.int, milliseconds >= 0 {
                settings.tapTimeoutMs = milliseconds
            } else {
                report(timeout, "Tap timeout must be a nonnegative integer.")
            }
        }
        if let icon = fields["menu_bar_icon"], let value = bool(icon, label: "Menu bar icon") {
            settings.showMenuBarIcon = value
        }
        if let launch = fields["launch_at_login"], let value = bool(launch, label: "Launch at login") {
            settings.launchAtLogin = value
        }
        return settings
    }

    mutating func profile(_ node: Node) -> Profile? {
        guard let fields = fields(node, allowed: ["name", "rules"], label: "Profile"),
              let name = name(fields, in: node, label: "Profile") else { return nil }
        guard let rules = fields["rules"] else { return Profile(name: name) }
        guard let sequence = rules.sequence else {
            report(rules, "Profile rules must be a list.")
            return nil
        }
        return Profile(name: name, rules: sequence.compactMap { rule($0) })
    }

    mutating func rule(_ node: Node) -> Rule? {
        guard let fields = fields(node, allowed: ["name", "enabled", "only", "except", "passthrough", "focus", "map"],
                                  label: "Rule"),
              let name = name(fields, in: node, label: "Rule") else { return nil }
        var rule = Rule(name: name)
        if let only = fields["only"] {
            if let except = fields["except"] {
                report(except, "A rule cannot specify both 'only' and 'except'.")
                return nil
            }
            guard let apps = stringList(only, label: "'only'") else { return nil }
            rule.scope = AppScope(.only, apps)
        } else if let except = fields["except"] {
            guard let apps = stringList(except, label: "'except'") else { return nil }
            rule.scope = AppScope(.except, apps)
        }
        if let enabled = fields["enabled"] {
            guard let value = bool(enabled, label: "Rule enabled") else { return nil }
            rule.enabled = value
        }
        if let focus = fields["focus"] {
            guard let raw = focus.scalar?.string, let condition = FocusCondition(rawValue: raw) else {
                report(focus, "Focus must be 'any', 'text_input', or 'not_text_input'.")
                return nil
            }
            rule.focus = condition
        }
        if let passthrough = fields["passthrough"] {
            guard let items = passthrough.sequence else {
                report(passthrough, "Passthrough must be a list of modifiers.")
                return nil
            }
            rule.passthrough = []
            for item in items {
                guard let raw = item.scalar?.string, let modifier = Modifiers.aliases[raw.lowercased()] else {
                    report(item, "Unknown passthrough modifier.")
                    return nil
                }
                rule.passthrough.insert(modifier)
            }
        }
        guard let mapping = fields["map"]?.mapping else {
            report(fields["map"] ?? node, "Rule 'map' must be a mapping of triggers to actions.")
            return nil
        }
        rule.mappings = mapping.flatMap { mappings(key: $0.key, value: $0.value) }
        return rule
    }

    mutating func mappings(key: Node, value: Node) -> [Mapping] {
        let raw: String
        if let sequence = key.sequence, sequence.allSatisfy({ $0.scalar != nil }) {
            // YAML reads an unquoted bare bracket group as a flow sequence in key position.
            raw = "[" + sequence.compactMap { $0.scalar?.string }.joined(separator: ",") + "]"
        } else if let text = nonemptyString(key, label: "Mapping trigger") {
            raw = text
        } else {
            return []
        }
        guard let expansions = expand(raw) else {
            report(key, "Invalid bracket expansion in trigger '\(raw)'.")
            return []
        }
        return expansions.compactMap { text, item in
            guard let trigger = trigger(text) else {
                report(key, "Invalid trigger '\(text)'.")
                return nil
            }
            if let map = value.mapping, map.count == 1, let pair = map.first, pair.key.scalar?.string == "tap" {
                guard case .key(let combo) = trigger, combo.key.isModifier, combo.modifiers.isEmpty else {
                    report(key, "Tap actions require a bare modifier key.")
                    return nil
                }
                let text = pair.value.scalar.map { substitution($0.string, item) }
                if let text, let system = SystemAction(rawValue: text) {
                    return Mapping(trigger: trigger, action: .system(system), isTapAlone: true)
                }
                if pair.value.sequence != nil || text?.lowercased() == "none" {
                    report(pair.value, "Tap actions require a combo, a system action, or an action map.")
                    return nil
                }
                guard let action = action(pair.value, replacing: item) else { return nil }
                return Mapping(trigger: trigger, action: action, isTapAlone: true)
            }
            guard let action = action(value, replacing: item) else { return nil }
            return Mapping(trigger: trigger, action: action)
        }
    }

    mutating func action(_ node: Node, replacing item: String?) -> Action? {
        if let raw = node.scalar?.string {
            let text = substitution(raw, item)
            if text.lowercased() == "none" { return Action.none }
            if let trigger = trigger(text) {
                switch trigger {
                case .key(let combo): return .keys([combo])
                case .mouse(let button, let modifiers): return .mouse(button, modifiers)
                }
            }
            report(node, "Invalid action '\(text)'.")
            return nil
        }
        if let sequence = node.sequence {
            var combos: [KeyCombo] = []
            for itemNode in sequence {
                guard let text = itemNode.scalar?.string, let combo = KeyCombo(parsing: substitution(text, item)) else {
                    report(itemNode, "A key sequence must contain only keyboard combos.")
                    return nil
                }
                combos.append(combo)
            }
            return .keys(combos)
        }
        guard let map = node.mapping, map.count == 1, let pair = map.first,
              let key = pair.key.scalar?.string else {
            report(node, "Expected a combo, key sequence, 'none', or a one-key action map.")
            return nil
        }
        switch key {
        case "open", "url", "shell", "system":
            guard let raw = nonemptyString(pair.value, label: "'\(key)' action") else { return nil }
            let text = substitution(raw, item)
            switch key {
            case "open": return .openApp(text)
            case "url": return .openURL(text)
            case "shell": return .shell(text)
            default:
                if let system = SystemAction(rawValue: text) { return .system(system) }
                report(pair.value, "Unknown system action '\(text)'.")
                return nil
            }
        default:
            report(pair.key, "Unknown action type '\(key)'.")
            return nil
        }
    }

    private func expand(_ text: String) -> [(String, String?)]? {
        if trigger(text) != nil || (!text.contains("[") && !text.contains("]")) { return [(text, nil)] }
        guard let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]"), open < close else {
            return nil
        }
        let group = text[text.index(after: open)..<close]
        let prefix = text[..<open]
        let suffix = text[text.index(after: close)...]
        guard !group.contains("["), !suffix.contains("["), !suffix.contains("]") else { return nil }
        let items = group.split { $0.isWhitespace || $0 == "," }
        guard !items.isEmpty else { return nil }
        return items.map { ("\(prefix)\($0)\(suffix)", String($0)) }
    }

    private func trigger(_ text: String) -> Trigger? {
        // Core's mouse parser omits empty components. YAML combos require every component.
        guard !text.split(separator: "+", omittingEmptySubsequences: false)
            .contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return Trigger(parsing: text)
    }

    private mutating func fields(_ node: Node, allowed: Set<String>, label: String) -> [String: Node]? {
        guard let map = node.mapping else {
            report(node, "\(label) must be a mapping.")
            return nil
        }
        var fields: [String: Node] = [:]
        for (key, value) in map {
            guard let name = key.scalar?.string else {
                report(key, "\(label) field names must be strings.")
                continue
            }
            guard allowed.contains(name) else {
                report(key, "Unknown \(label.lowercased()) field '\(name)'. It is ignored and is removed when Keyshift saves the file.", .warning)
                continue
            }
            fields[name] = value
        }
        return fields
    }

    private mutating func name(_ fields: [String: Node], in node: Node, label: String) -> String? {
        guard let name = fields["name"] else {
            report(node, "\(label) is missing a name.")
            return nil
        }
        return nonemptyString(name, label: "\(label) name")
    }

    private mutating func nonemptyString(_ node: Node, label: String) -> String? {
        guard let text = node.scalar?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              node.null == nil else {
            report(node, "\(label) must be a nonempty string.")
            return nil
        }
        return text
    }

    private mutating func stringList(_ node: Node, label: String) -> [String]? {
        guard let sequence = node.sequence else {
            report(node, "\(label) must be a list of app names or bundle IDs.")
            return nil
        }
        var values: [String] = []
        for item in sequence {
            guard let value = nonemptyString(item, label: "\(label) entry") else { return nil }
            values.append(value)
        }
        return values
    }

    private mutating func bool(_ node: Node, label: String) -> Bool? {
        guard let value = node.bool else {
            report(node, "\(label) must be a boolean.")
            return nil
        }
        return value
    }

    private mutating func report(_ node: Node, _ message: String, _ severity: Diagnostic.Severity = .error) {
        diagnostics.append(Diagnostic(line: node.mark?.line, message: message, severity: severity))
    }
}

private func substitution(_ text: String, _ item: String?) -> String {
    guard let item else { return text }
    return text.replacingOccurrences(of: "$1", with: item)
}

private enum ConfigEncoder {
    static func encode(_ config: Config) -> String {
        var fields: [(String, Node)] = [("version", Node(String(config.version)))]
        if let profile = config.selectedProfile { fields.append(("profile", scalar(profile))) }
        fields.append(("settings", map([
            ("tap_timeout_ms", Node(String(config.settings.tapTimeoutMs))),
            ("menu_bar_icon", Node(String(config.settings.showMenuBarIcon))),
            ("launch_at_login", Node(String(config.settings.launchAtLogin))),
        ])))
        if !config.appGroups.isEmpty {
            fields.append(("app_groups", map(config.appGroups.sorted { $0.key < $1.key }.map {
                ($0.key, list($0.value))
            })))
        }
        fields.append(("profiles", Node(config.profiles.map(profile), .implicit, .block)))
        // The emitter receives only scalar strings, mappings, and sequences.
        return try! Yams.serialize(node: map(fields), indent: 2, width: -1, allowUnicode: true)
    }

    private static func profile(_ profile: Profile) -> Node {
        map([("name", scalar(profile.name)), ("rules", Node(profile.rules.map(rule), .implicit, .block))])
    }

    private static func rule(_ rule: Rule) -> Node {
        var fields: [(String, Node)] = [("name", scalar(rule.name))]
        if !rule.enabled { fields.append(("enabled", Node("false"))) }
        if rule.scope.kind != .everywhere { fields.append((rule.scope.kind.rawValue, list(rule.scope.apps))) }
        if rule.focus != .any { fields.append(("focus", scalar(rule.focus.rawValue))) }
        if rule.passthrough != [.shift] { fields.append(("passthrough", list(rule.passthrough.names))) }
        var triggerCounts: [Trigger: Int] = [:]
        let mappings = rule.mappings.map { mapping -> (String, Node) in
            let duplicates = triggerCounts[mapping.trigger, default: 0]
            triggerCounts[mapping.trigger] = duplicates + 1
            // Alternate spellings of the same trigger need distinct YAML keys.
            let key = mapping.trigger.description + String(repeating: " ", count: duplicates)
            if mapping.isTapAlone {
                let tap: Node
                if case .system(let system) = mapping.action {
                    tap = scalar(system.rawValue)
                } else {
                    tap = action(mapping.action)
                }
                return (key, map([("tap", tap)], style: .flow))
            }
            return (key, action(mapping.action))
        }
        fields.append(("map", map(mappings)))
        return map(fields)
    }

    private static func action(_ action: Action) -> Node {
        switch action {
        case .keys(let combos):
            if combos.count == 1, let combo = combos.first { return scalar(combo.description) }
            return list(combos.map(\.description))
        case .mouse(let button, let mods): return scalar(Trigger.mouse(button, mods).description)
        case .none: return scalar("none")
        case .openApp(let app): return map([("open", scalar(app))], style: .flow)
        case .openURL(let url): return map([("url", scalar(url))], style: .flow)
        case .shell(let command): return map([("shell", scalar(command))], style: .flow)
        case .system(let system): return map([("system", scalar(system.rawValue))], style: .flow)
        }
    }

    private static func scalar(_ string: String) -> Node {
        let node = Node(string)
        let style: Node.Scalar.Style = node.tag == Tag(.str) && !string.contains(where: \.isNewline)
            ? .any : .doubleQuoted
        return Node(string, .implicit, style)
    }

    private static func list(_ strings: [String]) -> Node {
        Node(strings.map(scalar), .implicit, .flow)
    }

    private static func map(_ fields: [(String, Node)], style: Node.Mapping.Style = .block) -> Node {
        Node(fields.map { (scalar($0.0), $0.1) }, .implicit, style)
    }
}
