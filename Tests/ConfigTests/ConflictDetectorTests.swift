import KeyshiftConfig
import KeyshiftCore
import XCTest

final class ConflictDetectorTests: XCTestCase {
    func testDuplicatesRespectEnabledRulesGroupScopesAndFocus() {
        let rules = [
            rule("Terminal", "ctrl+y", scope: .init(.only, ["@terminals"]), focus: .textInput),
            rule("Finder", "ctrl+y", scope: .init(.only, ["com.apple.finder"])),
            rule("Except Terminal", "ctrl+y", scope: .init(.except, ["terminals"]), focus: .textInput),
            rule("Non-text Terminal", "ctrl+y", scope: .init(.only, ["terminals"]), focus: .notTextInput),
            rule("Disabled", "ctrl+y", enabled: false),
            rule("Terminal Copy", "ctrl+y", scope: .init(.only, ["COM.APPLE.TERMINAL"]), focus: .textInput),
            rule("Empty scope", "ctrl+y", scope: .init(.only, ["@missing"])),
        ]
        let profile = Profile(name: "Test", rules: rules)
        let config = Config(appGroups: ["terminals": ["com.apple.Terminal"]], profiles: [profile])
        let conflicts = ConflictDetector.find(in: profile, config: config)
        XCTAssertEqual(conflicts.map(\.kind), [.duplicate, .duplicate])
        XCTAssertEqual(conflicts.map(\.ruleID), [rules[2].id, rules[5].id])
        XCTAssertEqual(conflicts.map(\.otherRuleID), [rules[1].id, rules[0].id])
        XCTAssertEqual(conflicts.map(\.mappingID), [rules[2].mappings[0].id, rules[5].mappings[0].id])
    }

    func testPassthroughShadowingHonorsExactMatchesAcrossProfile() {
        let first = rule("First", "ctrl+button4", passthrough: [.option, .shift])
        let later = rule("Later", "alt+button4", passthrough: [.control, .shift])
        let exact = rule("Exact", "ctrl+alt+button4", passthrough: [])
        let exactWithShift = rule("Exact with Shift", "ctrl+alt+shift+button4")
        let shadowed = find([first, later, exact])
        XCTAssertEqual(shadowed.map(\.kind), [.shadowed])
        XCTAssertEqual(shadowed.first?.trigger, Trigger(parsing: "ctrl+alt+shift+button4"))
        XCTAssertEqual(shadowed.first?.otherMappingID, first.mappings.first?.id)
        XCTAssertTrue(find([first, later, exact, exactWithShift]).isEmpty)

        let bare = rule("Bare", "home")
        let shifted = rule("Shifted", "shift+home")
        XCTAssertTrue(find([bare, shifted]).isEmpty)
    }

    func testReportsEarlierPassthroughMatchThatCanWin() {
        let first = rule("First", "a", passthrough: [.control, .option])
        let second = rule("Second", "ctrl+a", passthrough: [.option])
        let third = rule("Third", "alt+a", passthrough: [.control])
        let conflicts = find([first, second, third])
        XCTAssertEqual(conflicts.map(\.kind), [.shadowed, .shadowed])
        XCTAssertEqual(conflicts.map(\.otherRuleID), [first.id, first.id])
        XCTAssertEqual(conflicts.map(\.ruleID), [second.id, third.id])
    }

    func testOnlyPartiallyCoveredExactMatchLeavesPassthroughOverlap() {
        let first = rule("First", "ctrl+a", passthrough: [.option])
        let second = rule("Second", "alt+a", passthrough: [.control])
        let exactInText = rule("Exact", "ctrl+alt+a", focus: .textInput)
        let exactOutsideText = rule("Exact outside text", "ctrl+alt+a", focus: .notTextInput)
        XCTAssertEqual(find([first, second, exactInText]).map(\.kind), [.shadowed])
        XCTAssertTrue(find([first, second, exactInText, exactOutsideText]).isEmpty)
    }

    func testSystemShortcutsIncludePassthrough() {
        let mapping = rule("Shortcut", "cmd+l")
        let key = KeyCombo(parsing: "cmd+l")!
        let shifted = KeyCombo(parsing: "cmd+shift+l")!
        let excluded = KeyCombo(parsing: "ctrl+cmd+l")!
        let profile = Profile(name: "Test", rules: [mapping])
        let conflicts = ConflictDetector.find(in: profile, config: Config(), systemShortcuts: [
            key: "Lock", shifted: "Shifted Lock", excluded: "Other",
        ])
        XCTAssertEqual(conflicts.map(\.kind), [.systemShortcut, .systemShortcut])
        XCTAssertEqual(Set(conflicts.map(\.trigger)), [.key(key), .key(shifted)])
        XCTAssertTrue(conflicts.allSatisfy { $0.otherMappingID == nil && $0.ruleID == mapping.id })
    }

    func testPathFragmentsAreNotProvablyDisjoint() {
        let games = ["/steamapps/common/", "/Epic Games/"]
        let config = Config(appGroups: ["games": games], profiles: [])
        func conflicts(_ a: AppScope, _ b: AppScope) -> [Conflict] {
            let profile = Profile(name: "Test", rules: [rule("A", "ctrl+y", scope: a), rule("B", "ctrl+y", scope: b)])
            return ConflictDetector.find(in: profile, config: config)
        }
        // Path vs bundle id, path vs different path: could be the same app.
        XCTAssertEqual(conflicts(.init(.only, ["@games"]), .init(.only, ["com.apple.finder"])).map(\.kind), [.duplicate])
        XCTAssertEqual(conflicts(.init(.only, ["/a/"]), .init(.only, ["/b/"])).map(\.kind), [.duplicate])
        // Bundle ids are still provably disjoint.
        XCTAssertTrue(conflicts(.init(.only, ["com.a"]), .init(.only, ["com.b"])).isEmpty)
        // Excluding the same fragment, or one contained in it, removes it; an unrelated one doesn't.
        XCTAssertTrue(conflicts(.init(.only, ["@games"]), .init(.except, ["@games"])).isEmpty)
        XCTAssertTrue(conflicts(.init(.only, ["/steamapps/common/foo/"]), .init(.except, ["/steamapps/common/"])).isEmpty)
        XCTAssertEqual(conflicts(.init(.only, ["/steamapps/common/"]), .init(.except, ["/steamapps/common/foo/"])).map(\.kind),
                       [.duplicate])
        XCTAssertEqual(conflicts(.init(.only, ["/steamapps/common/"]), .init(.except, ["com.apple.finder"])).map(\.kind),
                       [.duplicate])
    }

    private func rule(_ name: String, _ trigger: String, enabled: Bool = true, scope: AppScope = .everywhere,
                      focus: FocusCondition = .any, passthrough: Modifiers = [.shift]) -> Rule {
        Rule(name: name, enabled: enabled, scope: scope, focus: focus, passthrough: passthrough,
             mappings: [Mapping(trigger: Trigger(parsing: trigger)!, action: .none)])
    }

    private func find(_ rules: [Rule]) -> [Conflict] {
        ConflictDetector.find(in: Profile(name: "Test", rules: rules), config: Config())
    }
}
