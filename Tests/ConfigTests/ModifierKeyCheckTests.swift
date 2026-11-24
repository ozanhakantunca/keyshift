import KeyshiftConfig
import KeyshiftCore
import XCTest

final class ModifierKeyCheckTests: XCTestCase {
    func testFlagsMappingsThatNeitherTheHIDPathNorTheTapPathCanRun() throws {
        let yaml = """
        profiles:
          - name: P
            rules:
              - name: Global
                map:
                  caps_lock: ctrl+alt+cmd+shift
                  right_cmd: {open: Ghostty}
                  left_alt: left_cmd
                  right_alt: escape
                  left_cmd: {tap: launchpad}
                  cmd+right_alt: f13
                  f13: escape
              - name: Scoped
                only: [com.apple.Terminal]
                map:
                  caps_lock: escape
              - name: Text
                focus: text_input
                map:
                  right_shift: escape
              - name: Off
                enabled: false
                map:
                  caps_lock: {open: Safari}
        """
        let (config, diagnostics) = ConfigCodec.decode(yaml)
        XCTAssertEqual(diagnostics, [])
        let profile = try XCTUnwrap(config.activeProfile)
        let found = ModifierKeyCheck.ineffectiveMappings(in: profile)
        XCTAssertEqual(found.map { "\($0.rule.name): \($0.mapping.trigger)" }, [
            "Global: caps_lock", "Global: right_cmd", "Global: cmd+right_alt", "Scoped: caps_lock", "Text: right_shift",
        ])
        let messages = ModifierKeyCheck.diagnostics(in: profile)
        XCTAssertEqual(messages.count, 5)
        XCTAssertTrue(messages.allSatisfy { $0.severity == .warning && $0.message.contains(ModifierKeyCheck.explanation) })
        XCTAssertTrue(messages[0].message.contains("'caps_lock' in rule 'Global'"))
    }

    func testKeysWithoutHIDUsageCannotBeRemapped() throws {
        let rule = Rule(name: "R", mappings: [
            Mapping(trigger: .key(KeyCombo(parsing: "caps_lock")!), action: .keys([KeyCombo(parsing: "escape")!])),
        ])
        let profile = Profile(name: "P", rules: [rule])
        XCTAssertTrue(ModifierKeyCheck.ineffectiveMappings(in: profile).isEmpty)
        let escape = try XCTUnwrap(KeyCode.named("escape"))
        XCTAssertEqual(ModifierKeyCheck.ineffectiveMappings(in: profile) { $0 != escape }.count, 1)
    }
}
