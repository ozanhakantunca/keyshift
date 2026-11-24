import KeyshiftConfig
import KeyshiftCore
import XCTest

final class PresetsTests: XCTestCase {
    func testBundledPresetsAreListedWithMetadata() throws {
        let presets = Presets.all()
        XCTAssertEqual(presets.map(\.id), ["linux", "terminal", "windows"])
        XCTAssertEqual(presets.map(\.name), ["Linux", "Terminal", "Windows"])
        for info in presets { XCTAssertFalse(info.description?.isEmpty ?? true, "\(info.id) has no description") }
        XCTAssertNil(Presets.load("../windows"))
        XCTAssertNil(Presets.decode("missing"))
    }

    func testLoadReturnsFreshProfilesWithGroups() throws {
        let (profile, groups) = try XCTUnwrap(Presets.load("windows"))
        XCTAssertEqual(profile.name, "Windows")
        XCTAssertNotNil(groups["terminals"])
        let (second, _) = try XCTUnwrap(Presets.load("windows"))
        XCTAssertNotEqual(second.id, profile.id)
        XCTAssertEqual(withoutIDs(Config(profiles: [second])), withoutIDs(Config(profiles: [profile])))
    }

    func testEveryBundledPresetDecodesCleanlyWithoutDuplicates() throws {
        for info in Presets.all() {
            let (config, diagnostics) = try XCTUnwrap(Presets.decode(info.id), info.id)
            XCTAssertTrue(diagnostics.isEmpty, "\(info.id): \(diagnostics)")
            let profile = try XCTUnwrap(config.activeProfile, info.id)
            XCTAssertFalse(profile.rules.isEmpty, info.id)
            XCTAssertTrue(profile.rules.allSatisfy { !$0.mappings.isEmpty }, "\(info.id) has an empty rule")
            let duplicates = ConflictDetector.find(in: profile, config: config).filter { $0.kind == .duplicate }
            XCTAssertTrue(duplicates.isEmpty, "\(info.id): \(duplicates.map(\.message))")
        }
    }

    func testNoBundledPresetHasModifierMappingsThatCannotFire() throws {
        for info in Presets.all() {
            let (config, _) = try XCTUnwrap(Presets.decode(info.id), info.id)
            for profile in config.profiles {
                let diagnostics = ModifierKeyCheck.diagnostics(in: profile)
                XCTAssertTrue(diagnostics.isEmpty, "\(info.id): \(diagnostics.map(\.message))")
            }
        }
    }

    /// ⌘J is "Jump to Selection" in Chrome-family browsers on macOS; Downloads is ⇧⌘J (Firefox: ⇧⌘Y).
    func testCtrlJOpensDownloadsWithEachBrowsersOwnShortcut() throws {
        let (config, _) = try XCTUnwrap(Presets.decode("windows"))
        let rules = try XCTUnwrap(config.activeProfile).rules
        func output(for app: String) -> KeyCombo? {
            for rule in rules where rule.scope.kind == .only && config.resolveApps(rule.scope.apps).contains(app) {
                for mapping in rule.mappings where mapping.trigger == .key(KeyCombo(parsing: "ctrl+j")!) {
                    if case .keys(let combos) = mapping.action { return combos.first }
                }
            }
            return nil
        }
        XCTAssertEqual(output(for: "com.google.chrome"), KeyCombo(parsing: "shift+cmd+j"))
        XCTAssertEqual(output(for: "com.microsoft.edgemac"), KeyCombo(parsing: "shift+cmd+j"))
        XCTAssertEqual(output(for: "com.brave.browser"), KeyCombo(parsing: "shift+cmd+j"))
        XCTAssertEqual(output(for: "org.mozilla.firefox"), KeyCombo(parsing: "shift+cmd+y"))
        XCTAssertEqual(output(for: "com.apple.safari"), KeyCombo(parsing: "cmd+alt+l"))
    }

    func testGamesGroupCoversGameLaunchersInWindowsAndLinux() throws {
        for id in ["windows", "linux"] {
            let (config, _) = try XCTUnwrap(Presets.decode(id))
            let games = try XCTUnwrap(config.appGroups["games"], id)
            XCTAssertTrue(games.contains("/steamapps/common/") && games.contains("/Epic Games/")
                          && games.contains("/League of Legends.app/"), id)
            let scoped = try XCTUnwrap(config.activeProfile).rules.filter { $0.scope.apps.contains("games") }
            XCTAssertTrue(scoped.contains { $0.name == "Ctrl shortcuts" }, id)
            XCTAssertTrue(scoped.allSatisfy { $0.scope.kind == .except }, id)
        }
    }

    /// Win+←/→ tile through Accessibility (synthetic ⌃fn+arrows never trigger macOS tiling);
    /// Win+Ctrl+←/→ switch Spaces with ⌃←/⌃→.
    func testWindowsKeyTilesWindowsAndSwitchesSpaces() throws {
        let (config, diagnostics) = try XCTUnwrap(Presets.decode("windows"))
        XCTAssertTrue(diagnostics.isEmpty, "\(diagnostics)")
        let rule = try XCTUnwrap(config.activeProfile?.rules.first { $0.name == "Windows key" })
        func action(_ trigger: String) -> Action? {
            let key = Trigger.key(KeyCombo(parsing: trigger)!)
            return rule.mappings.first { $0.trigger == key }?.action
        }
        XCTAssertEqual(action("cmd+left"), .system(.tileLeft))
        XCTAssertEqual(action("cmd+right"), .system(.tileRight))
        XCTAssertEqual(action("cmd+up"), .keys([KeyCombo(parsing: "ctrl+fn+f")!]))
        XCTAssertEqual(action("ctrl+cmd+left"), .keys([KeyCombo(parsing: "ctrl+left")!]))
        XCTAssertEqual(action("ctrl+cmd+right"), .keys([KeyCombo(parsing: "ctrl+right")!]))
    }
}
