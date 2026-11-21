import KeyshiftCore
import KeyshiftSystem
import XCTest

final class ModifierRemapperTests: XCTestCase {
    func testEveryNamedKeyHasAHIDUsage() {
        for (name, code) in KeyNames.table {
            XCTAssertNotNil(ModifierRemapper.hidUsage(for: KeyCode(code)), name)
        }
        XCTAssertNil(ModifierRemapper.hidUsage(for: KeyCode(0xFFFF)))
        XCTAssertEqual(ModifierRemapper.hidUsage(for: KeyCode(0)), 0x07_0000_0004) // A
        XCTAssertEqual(ModifierRemapper.hidUsage(for: KeyCode(53)), 0x07_0000_0029) // Escape
        XCTAssertEqual(ModifierRemapper.hidUsage(for: KeyCode(57)), 0x07_0000_0039) // Caps Lock
        XCTAssertEqual(ModifierRemapper.hidUsage(for: KeyCode(59)), 0x07_0000_00E0) // Left Control
        XCTAssertEqual(ModifierRemapper.hidUsage(for: KeyCode(54)), 0x07_0000_00E7) // Right Command
        XCTAssertEqual(ModifierRemapper.hidUsage(for: KeyCode(63)), 0xFF_0000_0003) // Fn
        XCTAssertEqual(ModifierRemapper.hidUsage(for: KeyCode(76)), 0x07_0000_0058) // Keypad Enter
    }

    func testSelectsBareGlobalModifierMappingsInActiveProfile() throws {
        let capsToEscape = try mapping("caps_lock", "escape")
        let ctrlToCmd = try mapping("left_ctrl", "left_cmd")
        let keyToModifier = try mapping("insert", "right_alt")
        let duplicateCaps = try mapping("caps_lock", "left_ctrl")
        let ordinaryKey = try mapping("home", "escape")
        let chordInput = try mapping("shift+caps_lock", "escape")
        let chordOutput = try mapping("right_cmd", "cmd+c")
        let unknownKey = try mapping("code:65535", "left_alt")
        let tapAlone = try mapping("left_cmd", "escape", tapAlone: true)
        let sequence = Mapping(trigger: try XCTUnwrap(Trigger(parsing: "right_ctrl")),
                               action: .keys([KeyCombo(KeyCode(53)), KeyCombo(KeyCode(57))]))
        let scoped = Rule(name: "scoped", scope: AppScope(.only, ["com.apple.finder"]), mappings: [capsToEscape])
        let focus = Rule(name: "focus", focus: .textInput, mappings: [ctrlToCmd])
        let disabled = Rule(name: "disabled", enabled: false, mappings: [keyToModifier])
        let inactive = Profile(name: "Inactive", rules: [Rule(name: "other", mappings: [duplicateCaps])])
        let kept = [ordinaryKey, chordInput, chordOutput, unknownKey, tapAlone, sequence]
        let global = Rule(name: "global", mappings: [capsToEscape, ctrlToCmd, keyToModifier, duplicateCaps] + kept)
        let active = Profile(name: "Active", rules: [scoped, focus, disabled, global])
        let config = Config(selectedProfile: "Active", profiles: [inactive, active])

        let plan = ModifierRemapper.plan(for: config)
        XCTAssertEqual(plan.remaps.map(\.source), [0x07_0000_0039, 0x07_0000_00E0, 0x07_0000_0049])
        XCTAssertEqual(plan.remaps.map(\.destination), [0x07_0000_0029, 0x07_0000_00E3, 0x07_0000_00E6])
        XCTAssertEqual(plan.eventTapConfig.profiles.first, inactive)
        let rules = try XCTUnwrap(plan.eventTapConfig.activeProfile).rules
        XCTAssertEqual(Array(rules.prefix(3)), [scoped, focus, disabled])
        XCTAssertEqual(rules.last?.mappings, kept)
    }

    private func mapping(_ input: String, _ output: String, tapAlone: Bool = false) throws -> Mapping {
        Mapping(trigger: try XCTUnwrap(Trigger(parsing: input)),
                action: .keys([try XCTUnwrap(KeyCombo(parsing: output))]), isTapAlone: tapAlone)
    }
}
