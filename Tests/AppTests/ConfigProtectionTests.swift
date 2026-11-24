@testable import Keyshift
import KeyshiftConfig
import KeyshiftCore
import XCTest

/// AppModel is used without `start()`, so no event tap or HID mapping is touched.
@MainActor
final class ConfigProtectionTests: XCTestCase {
    private let valid = """
    profile: Main
    profiles:
      - name: Main
        rules:
          - name: Copy
            map:
              ctrl+c: cmd+c
      - name: Other
        rules: []
    """

    func testEditsAreRefusedWhileTheFileHasErrors() throws {
        let (url, store) = try temporaryStore()
        let broken = valid.replacingOccurrences(of: "  - name: Other", with: "  - name: Broken\n    rules: 5\n  - name: Other")
        try Data(broken.utf8).write(to: url)
        let model = AppModel(store: store)
        model.reloadFromDisk()
        XCTAssertTrue(model.configHasErrors)
        XCTAssertFalse(model.usingPreviousConfig)
        XCTAssertEqual(model.activeProfile?.name, "Main")

        model.selectProfile("Other")
        XCTAssertEqual(model.operationError, ConfigEditError.fileHasErrors.localizedDescription)
        model.update { $0.settings.tapTimeoutMs = 100 }
        XCTAssertThrowsError(try model.saveUpdate { _ in })
        XCTAssertThrowsError(try model.importKarabiner(from: url))
        XCTAssertThrowsError(try model.prepareCLIEdit())
        model.applyPreset("windows")
        XCTAssertEqual(try Data(contentsOf: url), Data(broken.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL().path))

        // Only an explicit choice (onboarding) replaces it, and the broken file is kept aside.
        model.applyPreset("windows", overridingErrors: true)
        XCTAssertFalse(model.configHasErrors)
        XCTAssertNil(model.operationError)
        XCTAssertEqual(model.activeProfile?.name, "Windows")
        XCTAssertEqual(try Data(contentsOf: store.invalidBackupURL), Data(broken.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL().path))
    }

    func testWarningsOnlyFilesStayEditable() throws {
        let (url, store) = try temporaryStore()
        try Data(("colour: blue\n" + valid).utf8).write(to: url)
        let model = AppModel(store: store)
        model.reloadFromDisk()
        XCTAssertFalse(model.configHasErrors)
        XCTAssertEqual(model.diagnostics.map(\.severity), [.warning])
        model.selectProfile("Other")
        XCTAssertNil(model.operationError)
        XCTAssertEqual(store.load()?.0.selectedProfile, "Other")
    }

    func testUnparseableFileKeepsThePreviousConfigActive() throws {
        let (url, store) = try temporaryStore()
        try Data(valid.utf8).write(to: url)
        let model = AppModel(store: store)
        model.reloadFromDisk()
        let ids = model.config.profiles.map(\.id)

        try Data("profiles: [\n  - name: Ma".utf8).write(to: url)
        model.reloadFromDisk()
        XCTAssertTrue(model.usingPreviousConfig)
        XCTAssertTrue(model.configHasErrors)
        XCTAssertTrue(model.hasConfigFile)
        XCTAssertEqual(model.config.profiles.map(\.id), ids)
        XCTAssertEqual(model.activeProfile?.rules.first?.mappings.count, 1)
        XCTAssertTrue(model.diagnostics.contains { $0.severity == .error })

        try Data(valid.utf8).write(to: url)
        model.reloadFromDisk()
        XCTAssertFalse(model.usingPreviousConfig)
        XCTAssertFalse(model.configHasErrors)
        XCTAssertEqual(model.config.profiles.map(\.id), ids, "unchanged profiles keep their ids")

        // At launch there is no previous config: nothing is active.
        try Data("profiles: [\n".utf8).write(to: url)
        let fresh = AppModel(store: store)
        fresh.reloadFromDisk()
        XCTAssertFalse(fresh.usingPreviousConfig)
        XCTAssertTrue(fresh.configHasErrors)
        XCTAssertTrue(fresh.config.profiles.isEmpty)
    }

    func testSaveAfterAnUnseenExternalEditReloadsInsteadOfOverwriting() throws {
        let (url, store) = try temporaryStore()
        try Data(valid.utf8).write(to: url)
        let model = AppModel(store: store)
        model.reloadFromDisk()
        let external = valid.replacingOccurrences(of: "ctrl+c: cmd+c", with: "ctrl+v: cmd+v")
        try Data(external.utf8).write(to: url, options: .atomic)

        model.selectProfile("Other")
        XCTAssertEqual(model.operationError, ConfigEditError.changedOnDisk.localizedDescription)
        XCTAssertEqual(try Data(contentsOf: url), Data(external.utf8))
        XCTAssertEqual(model.activeProfile?.rules.first?.mappings.first?.trigger.description, "ctrl+v")
        model.selectProfile("Other")
        XCTAssertNil(model.operationError)
        XCTAssertEqual(store.load()?.0.selectedProfile, "Other")
    }

    func testReloadCarriesOverIDsOfUnchangedItems() throws {
        let original = """
        profile: Main
        profiles:
          - name: Main
            rules:
              - name: Copy
                map:
                  ctrl+c: cmd+c
              - name: Second
                map:
                  f1: f2
                  f3: f4
          - name: Other
            rules: []
        """
        let (old, oldDiagnostics) = ConfigCodec.decode(original)
        XCTAssertEqual(oldDiagnostics, [])
        // An external edit inserts a rule at the top and changes one mapping of "Second".
        let edited = """
        profile: Main
        profiles:
          - name: Main
            rules:
              - name: Inserted
                map:
                  f9: f10
              - name: Copy
                map:
                  ctrl+c: cmd+c
              - name: Second
                map:
                  f1: f2
                  f3: f5
          - name: Other
            rules: []
        """
        let (new, newDiagnostics) = ConfigCodec.decode(edited)
        XCTAssertEqual(newDiagnostics, [])
        guard old.profiles.count == 2, new.profiles.count == 2 else { return XCTFail("Fixtures did not decode") }
        let carried = ConfigEdits.carryingIDs(from: old, to: new)
        let oldMain = old.profiles[0], main = carried.profiles[0]
        XCTAssertEqual(main.id, oldMain.id)
        XCTAssertEqual(carried.profiles[1].id, old.profiles[1].id)
        XCTAssertEqual(main.rules[0].id, new.profiles[0].rules[0].id, "a new rule keeps its fresh id")
        XCTAssertEqual(main.rules[1].id, oldMain.rules[0].id)
        XCTAssertEqual(main.rules[1].mappings[0].id, oldMain.rules[0].mappings[0].id)
        XCTAssertEqual(main.rules[2].id, oldMain.rules[1].id)
        XCTAssertEqual(main.rules[2].mappings[0].id, oldMain.rules[1].mappings[0].id)
        XCTAssertNotEqual(main.rules[2].mappings[1].id, oldMain.rules[1].mappings[1].id, "a changed mapping is new")
        XCTAssertEqual(withoutIDs(carried), withoutIDs(new))
    }

    func testIndexFallbackOnlyHitsTheItemTheSheetWasOpenedFor() throws {
        let a = Rule(name: "A", mappings: [Mapping(trigger: Trigger(parsing: "f1")!, action: .none)])
        let b = Rule(name: "B")
        var reloaded = a
        reloaded.id = UUID()
        let profile = Profile(name: "P", rules: [reloaded, b])

        XCTAssertEqual(try profile.ruleIndex(id: b.id, fallback: 0, snapshot: b), 1)
        XCTAssertEqual(try profile.ruleIndex(id: a.id, fallback: 0, snapshot: a), 0)
        XCTAssertThrowsError(try profile.ruleIndex(id: a.id, fallback: 1, snapshot: a)) { error in
            XCTAssertEqual(error.localizedDescription, ConfigEditError.changedOnDisk.localizedDescription)
        }
        XCTAssertThrowsError(try profile.ruleIndex(id: UUID(), fallback: 5, snapshot: a))
        XCTAssertNil(try profile.ruleIndex(id: UUID(), fallback: 0, snapshot: nil))

        let mapping = a.mappings[0]
        XCTAssertEqual(try reloaded.mappingIndex(id: UUID(), fallback: 0, snapshot: mapping), 0)
        let other = Mapping(trigger: Trigger(parsing: "f2")!, action: .none)
        XCTAssertThrowsError(try reloaded.mappingIndex(id: other.id, fallback: 0, snapshot: other))
    }

    func testSelfTestRefusesWhileDisabled() {
        let model = AppModel(store: ConfigStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("config.yaml")))
        model.isEnabled = false
        XCTAssertThrowsError(try model.runSelfTest()) { error in
            XCTAssertTrue(error.localizedDescription.contains("disabled"))
        }
        XCTAssertThrowsError(try model.runSelfTestSuite())
    }

    func testModifierWarningsArePublishedForTheActiveProfile() throws {
        let (url, store) = try temporaryStore()
        let yaml = "profiles:\n  - name: P\n    rules:\n      - name: Hyper\n        map:\n          caps_lock: ctrl+alt+cmd+shift\n"
        try Data(yaml.utf8).write(to: url)
        let model = AppModel(store: store)
        model.reloadFromDisk()
        XCTAssertEqual(model.diagnostics.count, 1)
        XCTAssertEqual(model.diagnostics.first?.severity, .warning)
        XCTAssertFalse(model.configHasErrors)
    }

    func testCLIImportOutputIsCappedAndStatusShowsSecureInput() throws {
        let manipulators = Array(repeating: #"{"type":"mouse_motion_to_scroll"}"#, count: 250).joined(separator: ",")
        let json = #"{"profiles":[{"name":"P","complex_modifications":{"rules":[{"manipulators":["# + manipulators + "]}]}}]}"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(json.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (_, report) = try KarabinerImporter.importFile(at: file)
        XCTAssertEqual(report.warnings.count, 250)
        let lines = CLI.importLines(report)
        XCTAssertEqual(lines.filter { $0.hasPrefix("warning: ") }.count, CLI.maximumImportWarnings)
        XCTAssertEqual(lines.last, "…and 50 more warning(s).")

        let status = CLI.statusLines(appRunning: true, engineRunning: true, enabled: true, hasConfig: true,
                                     profile: "P", permissions: PermissionState(), karabinerRunning: false,
                                     secureInput: true, diagnostics: 0, conflicts: 0, startError: nil)
        XCTAssertTrue(status.contains("Secure Input: active (macOS pauses most remapping)"))
    }

    private func temporaryStore() throws -> (URL, ConfigStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.yaml")
        return (url, ConfigStore(url: url))
    }
}

private func withoutIDs(_ config: Config) -> Config {
    let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    var config = config
    for p in config.profiles.indices {
        config.profiles[p].id = id
        for r in config.profiles[p].rules.indices {
            config.profiles[p].rules[r].id = id
            for m in config.profiles[p].rules[r].mappings.indices { config.profiles[p].rules[r].mappings[m].id = id }
        }
    }
    return config
}
