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

    func testRemovingLeftoversDropsOnlyExactEarlierPairs() {
        let caps = ModifierRemapper.Remap(source: 0x07_0000_0039, destination: 0x07_0000_0029)
        let src = "HIDKeyboardModifierMappingSrc", dst = "HIDKeyboardModifierMappingDst"
        let map: [[String: Any]] = [
            [src: NSNumber(value: caps.source), dst: NSNumber(value: caps.destination)],
            [src: NSNumber(value: caps.source), dst: NSNumber(value: 0x07_0000_00E0 as UInt64)],
            [src: NSNumber(value: 0x07_0000_00E0 as UInt64), dst: NSNumber(value: 0x07_0000_00E3 as UInt64)],
            ["Unrelated": "value"],
        ]
        let cleaned = ModifierRemapper.removingLeftovers(map, [caps])
        XCTAssertEqual(cleaned.count, 3)
        XCTAssertEqual((cleaned[0][dst] as? NSNumber)?.uint64Value, 0x07_0000_00E0)
        XCTAssertEqual(ModifierRemapper.removingLeftovers(map, []).count, 4)
    }

    func testLedgerReportsOnlyEarlierProcessesRemaps() throws {
        let suite = "io.github.ozanhakantunca.keyshift.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let caps = ModifierRemapper.Remap(source: 0x07_0000_0039, destination: 0x07_0000_0029)
        let ctrl = ModifierRemapper.Remap(source: 0x07_0000_00E0, destination: 0x07_0000_00E3)

        // A crashed run left both pairs installed.
        let crashed = UserDefaultsRemapLedger(owner: "app", defaults: defaults, session: "old")
        crashed.record([caps, ctrl])
        XCTAssertEqual(crashed.leftovers(), [])

        let app = UserDefaultsRemapLedger(owner: "app", defaults: defaults, session: "new")
        let selfTest = UserDefaultsRemapLedger(owner: "self-test", defaults: defaults, session: "new")
        XCTAssertEqual(Set(app.leftovers()), [caps, ctrl])
        // A pair this process installs itself is never a leftover for another owner.
        app.record([caps])
        XCTAssertEqual(selfTest.leftovers(), [ctrl])

        app.forgetLeftovers()
        XCTAssertEqual(app.leftovers(), [])
        XCTAssertEqual(UserDefaultsRemapLedger(owner: "app", defaults: defaults, session: "next").leftovers(), [caps])
        app.clear()
        XCTAssertNil(defaults.object(forKey: UserDefaultsRemapLedger.key))
    }

    private func mapping(_ input: String, _ output: String, tapAlone: Bool = false) throws -> Mapping {
        Mapping(trigger: try XCTUnwrap(Trigger(parsing: input)),
                action: .keys([try XCTUnwrap(KeyCombo(parsing: output))]), isTapAlone: tapAlone)
    }
}
