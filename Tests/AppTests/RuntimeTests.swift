@testable import Keyshift
import KeyshiftConfig
import KeyshiftCore
import XCTest

final class RuntimeTests: XCTestCase {
    func testCLIDispatchAndArguments() throws {
        XCTAssertNil(try CLI.parse(["/tmp/Keyshift"]))
        XCTAssertEqual(try CLI.parse(["/usr/local/bin/keyshift"]), .help)
        XCTAssertEqual(try CLI.parse(["Keyshift", "--help"]), .help)
        XCTAssertEqual(try CLI.parse(["Keyshift", "--version"]), .version)
        XCTAssertEqual(try CLI.parse(["Keyshift", "check", "Presets/windows.yaml"]), .check("Presets/windows.yaml"))
        XCTAssertEqual(try CLI.parse(["keyshift", "selftest"]), .request(CLIRequest(command: .selftest)))
        XCTAssertEqual(try CLI.parse(["keyshift", "selftest", "--suite"]),
                       .request(CLIRequest(command: .selftest, argument: "--suite")))
        XCTAssertThrowsError(try CLI.parse(["keyshift", "selftest", "--suite", "extra"]))
        XCTAssertEqual(try CLI.parse(["keyshift", "profile"]), .request(CLIRequest(command: .profile)))
        XCTAssertEqual(try CLI.parse(["keyshift", "profile", "Windows (2)"]),
                       .request(CLIRequest(command: .profile, argument: "Windows (2)")))
        XCTAssertEqual(try CLI.parse(["keyshift", "open", "events"]),
                       .request(CLIRequest(command: .open, argument: "events")))
        XCTAssertEqual(try CLI.parse(["keyshift", "import-karabiner", "--dry-run"]), .importDryRun(nil))
        XCTAssertEqual(try CLI.parse(["keyshift", "import-karabiner", "profile.json", "--dry-run"]),
                       .importDryRun("profile.json"))
        let absolute = URL(fileURLWithPath: "profile.json").standardizedFileURL.path
        XCTAssertEqual(try CLI.parse(["keyshift", "import-karabiner", "profile.json"]),
                       .request(CLIRequest(command: .importKarabiner, argument: absolute)))
        for args in [
            ["status", "extra"], ["open", "unknown"], ["check", "--dry-run"], ["enable", "disable"],
            ["import-karabiner", "--dry-run", "--dry-run"], ["profile", "one", "two"], ["nonsense"],
        ] {
            XCTAssertThrowsError(try CLI.parse(["keyshift"] + args), args.joined(separator: " "))
        }
    }

    func testMergingProfilesAndGroupsKeepsExistingSelection() throws {
        var config = Config(selectedProfile: "Windows", appGroups: ["terminals": ["com.apple.Terminal"]],
                            profiles: [Profile(name: "Windows"), Profile(name: "Windows (2)")])
        let incoming = Config(selectedProfile: "windows", appGroups: [
            "terminals": ["com.apple.terminal", "com.mitchellh.ghostty"], "browsers": ["com.apple.Safari"],
        ], profiles: [Profile(name: "Python"), Profile(name: "windows")])

        ConfigEdits.append(incoming, to: &config)

        XCTAssertEqual(config.profiles.map(\.name), ["Windows", "Windows (2)", "Python", "windows (3)"])
        XCTAssertEqual(config.activeProfile?.name, "Windows")
        var fresh = Config()
        ConfigEdits.append(incoming, to: &fresh)
        XCTAssertEqual(fresh.selectedProfile, "windows")
        XCTAssertEqual(config.appGroups["terminals"], ["com.apple.Terminal", "com.mitchellh.ghostty"])
        XCTAssertEqual(config.appGroups["browsers"], ["com.apple.Safari"])
        try ConfigEdits.select("Python", in: &config)
        XCTAssertEqual(ConfigCodec.decode(ConfigCodec.encode(config)).0.selectedProfile, "Python")
        XCTAssertThrowsError(try ConfigEdits.select("missing", in: &config))
        XCTAssertEqual(config.selectedProfile, "Python")
    }

    @MainActor
    func testFirstLaunchLeavesFileAbsentAndPresetPersistsSelectedProfile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.yaml")
        let store = ConfigStore(url: url)
        let model = AppModel(store: store)

        model.start()
        XCTAssertFalse(model.hasConfigFile)
        XCTAssertFalse(model.engineRunning)
        XCTAssertNil(store.load())
        model.stop()

        model.applyPreset("windows")
        model.applyPreset("windows")
        XCTAssertTrue(model.hasConfigFile)
        XCTAssertEqual(model.activeProfile?.name, "Windows (2)")
        XCTAssertEqual(store.load()?.0.selectedProfile, "Windows (2)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        model.selectProfile("Windows")
        XCTAssertEqual(store.load()?.0.selectedProfile, "Windows")
    }

    func testEventViewerFormatsInputAndDecision() {
        let key = KeyCode(8)
        let input = InputEvent(kind: .keyDown, key: key, modifiers: .control)
        XCTAssertEqual(EventDescription.input(input), "⌃C down")
        XCTAssertEqual(EventDescription.decision(.pass), "passed")
        XCTAssertEqual(EventDescription.decision(Decision(.rewrite(.keyUp(key, .command)))), "⌘C")
        XCTAssertEqual(EventDescription.decision(Decision(.replace, actions: [.openApp("Ghostty")])), "open Ghostty")
        XCTAssertEqual(EventDescription.decision(Decision(.replace)), "blocked")
    }
}
