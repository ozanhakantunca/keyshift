import XCTest
@testable import KeyshiftCore

final class KeyLayoutTests: XCTestCase {
    private func key(_ name: String) -> KeyCode { KeyCode.named(name)! }

    /// Turkish-PC under ⌘: dotless ı at the US I position, i at the US quote position, − at the US equal position.
    private let turkish: KeyLayoutMap = {
        let reference: [KeyCode: String] = [KeyCode(8): "c", KeyCode(34): "i", KeyCode(39): "'", KeyCode(24): "=",
                                            KeyCode(27): "-", KeyCode(29): "0"]
        let current: [KeyCode: String] = [KeyCode(8): "c", KeyCode(34): "ı", KeyCode(39): "i", KeyCode(24): "-",
                                          KeyCode(27): "*", KeyCode(29): "0"]
        return KeyLayoutMap.make(reference: reference, current: current)
    }()

    func testIdenticalLayoutIsIdentity() {
        let same: [KeyCode: String] = [KeyCode(8): "c", KeyCode(34): "i"]
        XCTAssertTrue(KeyLayoutMap.make(reference: same, current: same).isIdentity)
    }

    func testCharactersFollowTheirKeycapAndCollidingPositionsBecomeUnavailable() {
        XCTAssertEqual(turkish.resolve(key("i")), key("quote"))
        XCTAssertEqual(turkish.resolve(key("minus")), key("equal"))
        XCTAssertEqual(turkish.resolve(key("c")), key("c"))
        XCTAssertEqual(turkish.resolve(key("0")), key("0"))
        // "=" and "'" are not typeable unshifted, and their positions now type "-" and "i".
        XCTAssertNil(turkish.resolve(key("equal")))
        XCTAssertNil(turkish.resolve(key("quote")))
        XCTAssertEqual(turkish.resolve(key("left")), key("left"))
    }

    func testApplyTranslatesTriggersAndOutputsKeepingIdsAndDropsUnavailableKeys() {
        let italic = Mapping(trigger: Trigger(parsing: "ctrl+i")!, action: .keys([KeyCombo(parsing: "cmd+i")!]))
        let zoomOut = Mapping(trigger: Trigger(parsing: "ctrl+minus")!, action: .keys([KeyCombo(parsing: "cmd+minus")!]))
        let zoomIn = Mapping(trigger: Trigger(parsing: "ctrl+equal")!, action: .keys([KeyCombo(parsing: "cmd+equal")!]))
        let home = Mapping(trigger: Trigger(parsing: "home")!, action: .keys([KeyCombo(parsing: "cmd+left")!]))
        let click = Mapping(trigger: Trigger(parsing: "ctrl+left_click")!, action: .mouse(.left, .command))
        let rule = Rule(name: "r", mappings: [italic, zoomOut, zoomIn, home, click])
        let config = Config(selectedProfile: "P", profiles: [Profile(name: "P", rules: [rule])])

        let mapped = turkish.apply(to: config).profiles[0].rules[0]
        XCTAssertEqual(mapped.id, rule.id)
        XCTAssertEqual(mapped.mappings.map(\.id), [italic.id, zoomOut.id, home.id, click.id])
        XCTAssertEqual(mapped.mappings[0].trigger, .key(KeyCombo(parsing: "ctrl+quote")!))
        XCTAssertEqual(mapped.mappings[0].action, .keys([KeyCombo(parsing: "cmd+quote")!]))
        XCTAssertEqual(mapped.mappings[1].trigger, .key(KeyCombo(parsing: "ctrl+equal")!))
        XCTAssertEqual(mapped.mappings[1].action, .keys([KeyCombo(parsing: "cmd+equal")!]))
        XCTAssertEqual(mapped.mappings[2], home)
        XCTAssertEqual(mapped.mappings[3], click)
    }

    func testIdentityReturnsTheConfigUnchanged() {
        let config = Config(profiles: [Profile(name: "P", rules: [Rule(name: "r")])])
        XCTAssertEqual(KeyLayoutMap.identity.apply(to: config), config)
    }
}
