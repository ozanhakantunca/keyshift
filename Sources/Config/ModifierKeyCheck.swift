import Foundation
import KeyshiftCore

/// Modifier keys and Caps Lock reach the event tap only as flag changes, which the engine handles
/// for tap-alone mappings. Any other mapping on such a key works only as a HID remap, which the
/// system layer (`ModifierRemapper.plan`) installs for: an enabled rule that applies everywhere with
/// any focus, a trigger without modifiers, and an action that is a single key without modifiers.
public enum ModifierKeyCheck {
    public static let explanation =
        "Modifier and Caps Lock keys can only be remapped to a single key, in rules that apply everywhere, or given a tap action."

    /// Whether `key` arrives as a flags-changed event (modifiers and Caps Lock).
    public static func isFlagsKey(_ key: KeyCode) -> Bool {
        key.isModifier || key == KeyCode(57)
    }

    /// Mappings in the profile's enabled rules that can never fire. `hasHIDUsage` tells whether a
    /// key can be used in a HID remap (the system layer knows; every key is assumed usable otherwise).
    public static func ineffectiveMappings(in profile: Profile,
                                           hasHIDUsage: (KeyCode) -> Bool = { _ in true }) -> [(rule: Rule, mapping: Mapping)] {
        profile.rules.filter(\.enabled).flatMap { rule in
            rule.mappings.compactMap { mapping -> (rule: Rule, mapping: Mapping)? in
                guard !mapping.isTapAlone, case .key(let input) = mapping.trigger, isFlagsKey(input.key) else { return nil }
                return worksAsHIDRemap(mapping, in: rule, input: input, hasHIDUsage: hasHIDUsage) ? nil : (rule, mapping)
            }
        }
    }

    /// Warning-level diagnostics for `ineffectiveMappings`.
    public static func diagnostics(in profile: Profile, hasHIDUsage: (KeyCode) -> Bool = { _ in true }) -> [Diagnostic] {
        ineffectiveMappings(in: profile, hasHIDUsage: hasHIDUsage).map { rule, mapping in
            Diagnostic(message: "'\(mapping.trigger)' in rule '\(rule.name)' has no effect. \(explanation)",
                       severity: .warning)
        }
    }

    private static func worksAsHIDRemap(_ mapping: Mapping, in rule: Rule, input: KeyCombo,
                                        hasHIDUsage: (KeyCode) -> Bool) -> Bool {
        guard rule.scope.kind == .everywhere, rule.focus == .any, input.modifiers.isEmpty,
              case .keys(let keys) = mapping.action, keys.count == 1, let output = keys.first,
              output.modifiers.isEmpty else { return false }
        return hasHIDUsage(input.key) && hasHIDUsage(output.key)
    }
}
