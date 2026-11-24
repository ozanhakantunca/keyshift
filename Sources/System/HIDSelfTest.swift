import Foundation
import KeyshiftConfig

enum HIDSelfTest {
    static func run() -> SelfTestSuite.Row {
        let name = "HID Caps Lock → Escape"
        let keyboardArguments = ["property", "--matching", "keyboard", "--get", "UserKeyMapping"]
        let globalArguments = ["property", "--get", "UserKeyMapping"]

        guard let baseline = ProbeCommand.run("/usr/bin/hidutil", keyboardArguments),
              let global = ProbeCommand.run("/usr/bin/hidutil", globalArguments) else {
            return .init(name, .fail, "Could not read UserKeyMapping before applying the probe.")
        }
        guard baseline.contains("UserKeyMapping"), baseline.split(separator: "\n").count > 1 else {
            return .init(name, .skip, "hidutil reported no keyboard services.")
        }

        let (config, _) = ConfigCodec.decode("""
            version: 1
            profile: HID probe
            profiles:
              - name: HID probe
                rules:
                  - name: Caps Lock to Escape
                    map: {caps_lock: escape}
            """)
        let plan = ModifierRemapper.plan(for: config)
        let remapper = ModifierRemapper(ledger: UserDefaultsRemapLedger(owner: "hid-self-test"))
        var restored = false
        let installed: String? = {
            defer {
                restored = remapper.restore()
                if !restored { restored = remapper.restore() }
            }
            guard plan.remaps.count == 1, remapper.apply(plan.remaps) else { return nil }
            return ProbeCommand.run("/usr/bin/hidutil", keyboardArguments)
        }()

        // An absent property and an empty array both mean that no mappings are installed.
        guard restored, let after = ProbeCommand.run("/usr/bin/hidutil", keyboardArguments),
              let globalAfter = ProbeCommand.run("/usr/bin/hidutil", globalArguments),
              normalized(after) == normalized(baseline), normalized(globalAfter) == normalized(global) else {
            return .init(name, .fail, "Could not verify restoration of the previous UserKeyMapping.")
        }
        let pair = ["HIDKeyboardModifierMappingSrc": 0x700000039 as UInt64,
                    "HIDKeyboardModifierMappingDst": 0x700000029 as UInt64]
        guard let installed, containsMapping(pair, in: installed) else {
            return .init(name, .fail, "hidutil did not report Caps Lock → Escape. The previous map was restored.")
        }
        return .init(name, .pass, "hidutil verified Caps Lock → Escape and restoration.")
    }

    private static func normalized(_ value: String) -> String {
        value.filter { !$0.isWhitespace }.replacingOccurrences(of: "(null)", with: "()")
    }

    private static func containsMapping(_ mapping: [String: UInt64], in output: String) -> Bool {
        // hidutil prints each mapping as an OpenStep dictionary within the keyboard's array.
        for entry in output.split(separator: "{").dropFirst() {
            guard let end = entry.firstIndex(of: "}") else { continue }
            let fields = entry[..<end].split(separator: ";").reduce(into: [String: UInt64]()) { fields, field in
                let parts = field.split(separator: "=").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.count == 2 else { return }
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                fields[parts[0]] = value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
            }
            if fields == mapping { return true }
        }
        return false
    }
}
