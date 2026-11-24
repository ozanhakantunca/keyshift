import Foundation
import KeyshiftCore

public struct ImportReport: Sendable {
    public fileprivate(set) var importedCount = 0
    public fileprivate(set) var skippedCount = 0
    public fileprivate(set) var skippedByReason: [String: Int] = [:]
    /// Imported manipulators that became identical to an earlier one (Karabiner configs often repeat a
    /// manipulator once per accessibility role) and were folded into it. Included in `importedCount`.
    public fileprivate(set) var mergedDuplicateCount = 0
    public fileprivate(set) var warnings: [String] = []
    /// Every imported mapping that runs a shell command, as "Profile 'X', rule 'Y': command"
    /// (long commands truncated). Also listed in `warnings`; review these before using the rules.
    public fileprivate(set) var shellCommands: [String] = []

    fileprivate mutating func skip(_ reason: String, at location: String, count: Int = 1) {
        skippedCount += count
        skippedByReason[reason, default: 0] += count
        warnings.append("\(location) skipped. \(reason).")
    }
}

public enum KarabinerImporter {
    /// Larger files are refused before reading.
    public static let maximumFileSize = 8 * 1024 * 1024

    public static func importFile(at url: URL) throws -> (Config, ImportReport) {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileSize else {
            throw ImportError("\(url.path) is larger than \(maximumFileSize / 1024 / 1024) MB")
        }
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data)
        guard let root = root as? Object, let profiles = root["profiles"] as? [Any] else {
            throw ImportError("Expected a Karabiner config containing a 'profiles' array")
        }

        var config = Config()
        var report = ImportReport()
        var names: Set<String> = []
        for (index, entry) in profiles.enumerated() {
            let location = "Profile \(index + 1)"
            guard let object = entry as? Object else {
                report.warnings.append("\(location) ignored. Expected a profile object.")
                continue
            }
            let baseName = nonemptyString(object["name"]) ?? location
            var name = baseName
            var suffix = 2
            while !names.insert(name).inserted {
                name = "\(baseName) (\(suffix))"
                suffix += 1
            }
            if name != baseName { report.warnings.append("\(location) renamed to '\(name)' to keep profile names unique.") }
            var rules = simpleModifications(object["simple_modifications"], at: location, report: &report)
            rules += complexModifications(object["complex_modifications"], at: location, report: &report)
            skipDeviceModifications(object["devices"], at: location, report: &report)
            config.profiles.append(Profile(name: name, rules: rules))
            if object["selected"] as? Bool == true, config.selectedProfile == nil {
                config.selectedProfile = name
            }
        }
        for profile in config.profiles {
            for rule in profile.rules {
                for case .shell(let command) in rule.mappings.map(\.action) {
                    let text = command.count > 200 ? String(command.prefix(200)) + "…" : command
                    report.shellCommands.append("Profile '\(profile.name)', rule '\(rule.name)': \(text)")
                    report.warnings.append("Profile '\(profile.name)', rule '\(rule.name)' runs the shell command "
                        + "`\(text)`. Review it before using this rule.")
                }
            }
            report.warnings += ModifierKeyCheck.diagnostics(in: profile).map { "Profile '\(profile.name)'. \($0.message)" }
        }
        return (config, report)
    }

    private typealias Object = [String: Any]

    private struct ImportError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason + "." }
    }

    private struct Converted {
        let mapping: Mapping
        let scope: AppScope
        let focus: FocusCondition
        let passthrough: Modifiers
        let warnings: [String]
    }

    /// Everything that decides when and what a converted manipulator does; equal keys are redundant.
    private struct DuplicateKey: Hashable {
        let scope: AppScope
        let focus: FocusCondition
        let passthrough: Modifiers
        let trigger: Trigger
        let action: Action
        let isTapAlone: Bool
    }

    private static func simpleModifications(_ raw: Any?, at location: String, report: inout ImportReport) -> [Rule] {
        var mappings: [Mapping] = []
        let entries = entries(raw, label: "simple_modifications", at: location, report: &report)
        for (index, raw) in entries.enumerated() {
            let entryLocation = "\(location), simple modification \(index + 1)"
            do {
                guard let object = raw as? Object, let from = object["from"] as? Object,
                      let to = object["to"] as? [Any] else { throw ImportError("Invalid simple modification") }
                let trigger = try event(from, modifiers: [])
                let action = try action(to)
                mappings.append(Mapping(trigger: trigger, action: action))
                report.importedCount += 1
            } catch let error as ImportError {
                report.skip(error.reason, at: entryLocation)
            } catch {
                report.skip("Invalid simple modification", at: entryLocation)
            }
        }
        guard !mappings.isEmpty else { return [] }
        return [Rule(name: "Simple Modifications", passthrough: allModifiers, mappings: mappings)]
    }

    private static func complexModifications(_ raw: Any?, at location: String, report: inout ImportReport) -> [Rule] {
        guard let raw else { return [] }
        // A later manipulator identical to an earlier one can never fire, so it is dropped.
        var seen: Set<DuplicateKey> = []
        guard let complex = raw as? Object else {
            report.warnings.append("\(location) has an invalid 'complex_modifications' object.")
            return []
        }
        var rules: [Rule] = []
        let entries = entries(complex["rules"], label: "complex rules", at: location, report: &report)
        for (index, entry) in entries.enumerated() {
            let ruleLocation = "\(location), complex rule \(index + 1)"
            guard let rule = entry as? Object, let manipulators = rule["manipulators"] as? [Any] else {
                report.warnings.append("\(ruleLocation) ignored. Expected a manipulators array.")
                continue
            }
            let name = nonemptyString(rule["description"]) ?? "Complex Rule \(index + 1)"
            var groups: [Rule] = []
            for (index, manipulator) in manipulators.enumerated() {
                let location = "\(ruleLocation), manipulator \(index + 1)"
                do {
                    let converted = try convert(manipulator)
                    report.importedCount += 1
                    let key = DuplicateKey(scope: converted.scope, focus: converted.focus,
                                           passthrough: converted.passthrough, trigger: converted.mapping.trigger,
                                           action: converted.mapping.action, isTapAlone: converted.mapping.isTapAlone)
                    guard seen.insert(key).inserted else {
                        report.mergedDuplicateCount += 1
                        continue
                    }
                    add(converted, to: &groups, name: name)
                    report.warnings += converted.warnings.map { "\(location). \($0)" }
                } catch let error as ImportError {
                    report.skip(error.reason, at: location)
                } catch {
                    report.skip("Invalid manipulator", at: location)
                }
            }
            rules += groups
        }
        return rules
    }

    private static func add(_ converted: Converted, to groups: inout [Rule], name: String) {
        // Combine matching scopes and modifier policies when moving this mapping preserves its priority.
        for index in groups.indices.reversed() {
            let group = groups[index]
            if group.scope == converted.scope, group.focus == converted.focus,
               group.passthrough == converted.passthrough {
                groups[index].mappings.append(converted.mapping)
                return
            }
            let disjointFocus = group.focus != .any && converted.focus != .any && group.focus != converted.focus
            if !disjointFocus, group.mappings.contains(where: { $0.trigger.input == converted.mapping.trigger.input }),
               ScopedApps(group.scope).overlaps(ScopedApps(converted.scope)) {
                break
            }
        }
        groups.append(Rule(name: name, scope: converted.scope, focus: converted.focus,
                           passthrough: converted.passthrough, mappings: [converted.mapping]))
    }

    private static func convert(_ raw: Any) throws -> Converted {
        guard let object = raw as? Object, let type = object["type"] as? String else {
            throw ImportError("Invalid manipulator")
        }
        guard type == "basic" else { throw ImportError("Unsupported manipulator type '\(type)'") }
        try checkFields(object, allowed: ["type", "from", "to", "to_if_alone", "conditions"])
        guard var from = object["from"] as? Object else { throw ImportError("Invalid from event") }
        let (mandatory, optional) = try sourceModifiers(from.removeValue(forKey: "modifiers"))
        let trigger = try event(from, modifiers: mandatory)
        let (scope, focus, warnings) = try conditions(object["conditions"])
        guard let to = object["to"] as? [Any] else { throw ImportError("Missing or invalid 'to' events") }

        if let alone = object["to_if_alone"] {
            guard let events = alone as? [Any], events.count == 1,
                  case .key(let combo) = trigger, combo.key.isModifier, combo.modifiers.isEmpty,
                  to.count == 1, var hold = to.first as? Object else {
                throw ImportError("Unsupported 'to_if_alone' behavior")
            }
            hold.removeValue(forKey: "lazy")
            guard try action([hold]) == .keys([combo]) else {
                throw ImportError("Unsupported 'to_if_alone' hold action")
            }
            let mapping = Mapping(trigger: trigger, action: try action(events), isTapAlone: true)
            let tapWarnings = optional.isEmpty ? [] : ["Keyshift tap actions require all other modifiers to be released."]
            return Converted(mapping: mapping, scope: scope, focus: focus, passthrough: optional,
                             warnings: warnings + tapWarnings)
        }

        let mapping = Mapping(trigger: trigger, action: try action(to))
        return Converted(mapping: mapping, scope: scope, focus: focus, passthrough: optional, warnings: warnings)
    }

    private static func action(_ events: [Any]) throws -> Action {
        let actions = try events.map { raw -> Action in
            guard var object = raw as? Object else { throw ImportError("Invalid output event") }
            if object["shell_command"] != nil {
                try checkFields(object, allowed: ["shell_command"])
                guard let command = nonemptyString(object["shell_command"]) else {
                    throw ImportError("Invalid shell command")
                }
                return openAction(command) ?? .shell(command)
            }
            let modifiers = try modifiers(object.removeValue(forKey: "modifiers"))
            if object.count == 1, modifiers.isEmpty, let name = object["key_code"] as? String,
               let system = systemKeys[name] {
                return .system(system)
            }
            switch try event(object, modifiers: modifiers) {
            case .key(let combo): return .keys([combo])
            case .mouse(let button, let modifiers): return .mouse(button, modifiers)
            }
        }
        if actions.isEmpty { return .none }
        if actions.count == 1, let action = actions.first { return action }

        var sequence: [KeyCombo] = []
        for action in actions {
            guard case .keys(let combos) = action else { throw ImportError("Unsupported mixed output sequence") }
            sequence += combos
        }
        return .keys(sequence)
    }

    private static func event(_ object: Object, modifiers: Modifiers) throws -> Trigger {
        try checkFields(object, allowed: ["key_code", "pointing_button"])
        guard object.count == 1 else { throw ImportError("Expected one key_code or pointing_button") }
        if let name = object["key_code"] as? String {
            guard let key = KeyCode.named(keyNames[name] ?? name) else {
                throw ImportError("Unsupported key code '\(name)'")
            }
            return .key(KeyCombo(key, modifiers))
        }
        if let name = object["pointing_button"] as? String {
            guard let button = mouseButtons[name] else { throw ImportError("Unsupported pointing button '\(name)'") }
            return .mouse(button, modifiers)
        }
        throw ImportError("Invalid key_code or pointing_button")
    }

    private static func sourceModifiers(_ raw: Any?) throws -> (Modifiers, Modifiers) {
        guard let raw else { return ([], []) }
        guard let object = raw as? Object else { throw ImportError("Invalid source modifiers") }
        try checkFields(object, allowed: ["mandatory", "optional"])
        let mandatory = try modifiers(object["mandatory"])
        guard let rawOptional = object["optional"] else { return (mandatory, []) }
        guard let optional = rawOptional as? [String] else { throw ImportError("Invalid optional modifier list") }
        if optional == ["any"] { return (mandatory, allModifiers) }
        // Keyshift does not match on Caps Lock state. An optional flag already allows either state.
        return (mandatory, try modifiers(optional.filter { $0 != "caps_lock" }))
    }

    private static func modifiers(_ raw: Any?) throws -> Modifiers {
        guard let raw else { return [] }
        guard let items = raw as? [String] else { throw ImportError("Invalid modifier list") }
        var modifiers: Modifiers = []
        for name in items {
            let baseName = name.hasPrefix("left_") ? String(name.dropFirst(5))
                : name.hasPrefix("right_") ? String(name.dropFirst(6)) : name
            guard let flag = Modifiers.aliases[baseName] else { throw ImportError("Unsupported modifier '\(name)'") }
            modifiers.insert(flag)
        }
        return modifiers
    }

    private static let roleVariable = "accessibility.focused_ui_element.role_string"
    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField",
    ]
    private static let nonTextRoles: Set<String> = [
        "AXOutline", "AXList", "AXBrowser", "AXScrollArea", "AXLayoutArea", "AXCollection", "AXTable",
        "AXGroup", "AXImage", "AXCell", "AXRow",
    ]

    private static func conditions(_ raw: Any?) throws -> (AppScope, FocusCondition, [String]) {
        guard let raw else { return (.everywhere, .any, []) }
        guard let conditions = raw as? [Object] else { throw ImportError("Invalid condition list") }
        var applications: [(AppScope.Kind, Object)] = []
        var focus = FocusCondition.any
        var warnings: [String] = []
        for condition in conditions {
            guard let type = condition["type"] as? String else { throw ImportError("Invalid condition type") }
            switch type {
            case "frontmost_application_if": applications.append((.only, condition))
            case "frontmost_application_unless": applications.append((.except, condition))
            case "variable_if", "variable_unless":
                guard condition["name"] as? String == roleVariable else {
                    throw ImportError("Unsupported condition '\(type)'")
                }
                let (condition, warning) = try roleFocus(condition, negated: type == "variable_unless")
                if let warning { warnings.append(warning) }
                guard focus == .any || focus == condition else {
                    throw ImportError("Contradictory focused element conditions")
                }
                focus = condition
            default: throw ImportError("Unsupported condition '\(type)'")
            }
        }
        let (scope, scopeWarnings) = try appScope(applications)
        return (scope, focus, warnings + scopeWarnings)
    }

    private static func roleFocus(_ condition: Object, negated: Bool) throws -> (FocusCondition, String?) {
        try checkFields(condition, allowed: ["type", "name", "value"])
        guard let role = condition["value"] as? String else { throw ImportError("Unsupported focused element role") }
        let isText: Bool
        if textRoles.contains(role) {
            isText = true
        } else if nonTextRoles.contains(role) {
            isText = false
        } else {
            throw ImportError("Unsupported focused element role '\(role)'")
        }
        let focus: FocusCondition = isText != negated ? .textInput : .notTextInput
        let warning = negated && !isText
            ? "Condition 'not \(role)' imported as text_input focus, which is narrower than Karabiner's."
            : nil
        return (focus, warning)
    }

    private static func appScope(_ conditions: [(AppScope.Kind, Object)]) throws -> (AppScope, [String]) {
        var included: Set<String>?
        var excluded: Set<String> = []
        var warnings: [String] = []
        for (scope, condition) in conditions {
            try checkFields(condition, allowed: ["type", "bundle_identifiers", "file_paths"])
            let patterns = try stringList(condition["bundle_identifiers"], "Invalid frontmost application bundle identifiers")
            let paths = try stringList(condition["file_paths"], "Invalid frontmost application file_paths")
            guard !patterns.isEmpty || !paths.isEmpty else {
                throw ImportError("Missing frontmost application bundle identifiers")
            }
            var entries: Set<String> = []
            for pattern in patterns {
                guard nonemptyString(pattern) != nil else {
                    throw ImportError("Empty frontmost application bundle identifier pattern")
                }
                let (id, exact) = literalBundleID(pattern)
                entries.insert(id)
                if !exact { warnings.append("Bundle ID pattern '\(pattern)' imported as the literal '\(id)'.") }
            }
            for pattern in paths {
                if let fragment = literalPathFragment(pattern) {
                    entries.insert(fragment)
                } else {
                    warnings.append("File path pattern '\(pattern)' is not a literal path fragment and was dropped.")
                }
            }
            guard !entries.isEmpty else {
                // Nothing usable is left: skipping beats silently widening the manipulator's scope.
                throw ImportError("Unsupported frontmost application file_paths")
            }
            if scope == .only {
                included = included.map { $0.intersection(entries) } ?? entries
            } else {
                excluded.formUnion(entries)
            }
        }
        if let included { return (AppScope(.only, included.subtracting(excluded).sorted()), warnings) }
        if !excluded.isEmpty { return (AppScope(.except, excluded.sorted()), warnings) }
        return (.everywhere, warnings)
    }

    private static func stringList(_ raw: Any?, _ error: String) throws -> [String] {
        guard let raw else { return [] }
        guard let list = raw as? [String] else { throw ImportError(error) }
        return list
    }

    /// Reduces a Karabiner `file_paths` regex to a lowercased path fragment, or nil when it is not
    /// a plain literal (alternation, wildcards, classes …) or has no "/" to tell it apart from a bundle id.
    private static func literalPathFragment(_ pattern: String) -> String? {
        var body = pattern[...]
        if body.first == "^" { body = body.dropFirst() }
        if body.last == "$", !body.hasSuffix(#"\$"#) { body = body.dropLast() }
        var fragment = ""
        var escaped = false
        for character in body {
            if escaped {
                // Only escaped punctuation is a literal; \d, \w, \b … are classes/anchors.
                guard !character.isLetter, !character.isNumber else { return nil }
                fragment.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if ".*+?()[]{}|^$".contains(character) {
                return nil
            } else {
                fragment.append(character)
            }
        }
        guard !escaped, fragment.contains("/") else { return nil }
        return fragment.lowercased()
    }

    private static func literalBundleID(_ pattern: String) -> (String, Bool) {
        let anchored = pattern.hasPrefix("^") && pattern.hasSuffix("$")
        var body = pattern[...]
        if body.first == "^" { body = body.dropFirst() }
        if body.last == "$" { body = body.dropLast() }
        let exact = anchored && body.range(of: #"^[a-zA-Z0-9_-]+(?:\\\.[a-zA-Z0-9_-]+)*$"#,
                                          options: .regularExpression) != nil
        let text = body.replacingOccurrences(of: #"\."#, with: ".")
        let withoutWildcards = text.replacingOccurrences(of: #"^(?:\.\*)+|(?:\.\*)+$"#,
                                                         with: "", options: .regularExpression)
        let candidate = withoutWildcards.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ((candidate.isEmpty ? pattern : candidate).lowercased(), exact)
    }

    private static func openAction(_ command: String) -> Action? {
        let word = #"(?:'[^']*'|"[^"\x60$\\]*"|[A-Za-z0-9_./:%@=+\-]+)"#
        let patterns = [
            #"^\s*(?:/usr/bin/)?open[ \t]+-a[ \t]+("# + word + #")[ \t]*$"#,
            #"^\s*(?:/usr/bin/)?open[ \t]+("# + word + #")[ \t]*$"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
                  match.range == NSRange(command.startIndex..., in: command),
                  let range = Range(match.range(at: 1), in: command) else { continue }
            var argument = command[range]
            if argument.first == "'" || argument.first == "\"" { argument = argument.dropFirst().dropLast() }
            guard !argument.isEmpty, !argument.hasPrefix("-") else { continue }
            if index == 0 { return .openApp(String(argument)) }
            if let url = URLComponents(string: String(argument)), url.scheme != nil { return .openURL(String(argument)) }
        }
        return nil
    }

    private static func checkFields(_ object: Object, allowed: Set<String>) throws {
        if let unexpected = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw ImportError("Unsupported '\(unexpected)'")
        }
    }

    private static func nonemptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func entries(_ raw: Any?, label: String, at location: String, report: inout ImportReport) -> [Any] {
        guard let raw else { return [] }
        if let entries = raw as? [Any] { return entries }
        report.warnings.append("\(location) has an invalid '\(label)' array.")
        return []
    }

    private static func skipDeviceModifications(_ raw: Any?, at location: String, report: inout ImportReport) {
        guard let devices = raw as? [Object] else { return }
        let count = devices.reduce(0) { $0 + (($1["simple_modifications"] as? [Any])?.count ?? 0) }
        if count > 0 { report.skip("Unsupported device-specific simple modifications", at: location, count: count) }
    }

    private static let allModifiers = Modifiers.canonical.reduce(into: Modifiers()) { $0.insert($1.flag) }

    private static let mouseButtons: [String: MouseButton] = [
        "button1": .left, "button2": .right, "button3": .middle, "button4": .button4, "button5": .button5,
    ]

    private static let systemKeys: [String: SystemAction] = [
        "launchpad": .launchpad, "mission_control": .missionControl, "spotlight": .spotlight,
    ]

    private static let keyNames: [String: String] = [
        "left_command": "left_cmd", "right_command": "right_cmd", "left_control": "left_ctrl",
        "right_control": "right_ctrl", "left_option": "left_alt", "right_option": "right_alt",
        "delete_or_backspace": "backspace", "delete_forward": "delete", "return_or_enter": "return",
        "grave_accent_and_tilde": "grave", "spacebar": "space", "open_bracket": "left_bracket",
        "close_bracket": "right_bracket", "hyphen": "minus", "equal_sign": "equal",
        "non_us_pound": "section", "keypad_num_lock": "keypad_clear", "keypad_slash": "keypad_divide",
        "keypad_asterisk": "keypad_multiply", "print_screen": "f13", "keypad_hyphen": "keypad_minus", "keypad_equal_sign": "keypad_equal",
    ]
}
