import Foundation
import KeyshiftConfig
import KeyshiftCore
import XCTest

final class ConfigStoreTests: XCTestCase {
    func testMissingConfigAndAtomicBackup() throws {
        let url = try temporaryDirectory().appendingPathComponent("nested/config.yaml")
        let store = ConfigStore(url: url)
        XCTAssertNil(store.load())
        try store.save(Config(profiles: [Profile(name: "First")]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        let original = try Data(contentsOf: url)
        try store.save(Config(profiles: [Profile(name: "Second")]))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("bak")), original)
        XCTAssertEqual(store.load()?.0.activeProfile?.name, "Second")
    }

    func testKeepsRotatingBackupsAndNeverBacksUpAnInvalidFileOverAGoodOne() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.yaml")
        let store = ConfigStore(url: url)
        for index in 0...ConfigStore.backupCount + 1 {
            try store.save(Config(profiles: [Profile(name: "P\(index)")]))
        }
        // Newest backup first; the oldest versions rotated out.
        let names = (0..<ConfigStore.backupCount).map { store.backupURL($0) }.map {
            ConfigStore(url: $0).load()?.0.activeProfile?.name
        }
        XCTAssertEqual(names, (1...ConfigStore.backupCount).reversed().map { "P\($0)" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL(ConfigStore.backupCount).path))

        let good = try Data(contentsOf: store.backupURL())
        let broken = Data("profiles: [\n".utf8)
        try broken.write(to: url)
        try store.save(Config(profiles: [Profile(name: "Replaced")]))
        XCTAssertEqual(try Data(contentsOf: store.backupURL()), good)
        XCTAssertEqual(try Data(contentsOf: store.invalidBackupURL), broken)
    }

    func testSaveRefusesWhenTheFileChangedSinceItWasRead() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.yaml")
        let store = ConfigStore(url: url)
        XCTAssertThrowsError(try store.save(Config(), condition: .unchangedSince(Data("x".utf8))))
        let saved = try store.save(Config(profiles: [Profile(name: "Mine")]), condition: .unchangedSince(nil))
        try yaml("External").write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.save(Config(), condition: .unchangedSince(saved.contents))) { error in
            XCTAssertEqual(error as? ConfigStoreError, .changedOnDisk(store.url))
        }
        XCTAssertEqual(store.load()?.0.activeProfile?.name, "External")
        let current = try XCTUnwrap(store.loadDetailed()?.contents)
        XCTAssertNoThrow(try store.save(Config(profiles: [Profile(name: "Next")]), condition: .unchangedSince(current)))
    }

    func testSavesThroughASymlinkAndWatchesItsTarget() throws {
        let directory = try temporaryDirectory()
        let dotfiles = directory.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("keyshift.yaml")
        try yaml("Linked").write(to: target)
        let link = directory.appendingPathComponent("config.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let store = ConfigStore(url: link)
        XCTAssertEqual(store.load()?.0.activeProfile?.name, "Linked")
        let edited = expectation(description: "Edit of the link target observed")
        store.startWatching { loaded in
            if loaded?.config.activeProfile?.name == "Edited in dotfiles" { edited.fulfill() }
        }
        defer { store.stopWatching() }
        try store.save(Config(profiles: [Profile(name: "Saved")]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(ConfigStore(url: target).load()?.0.activeProfile?.name, "Saved")

        try yaml("Edited in dotfiles").write(to: target, options: .atomic)
        wait(for: [edited], timeout: 3)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testWatchesNewDirectoryThenReplacementAndInPlaceEdit() throws {
        let url = try temporaryDirectory().appendingPathComponent("nested/config.yaml")
        let store = ConfigStore(url: url)
        let created = expectation(description: "New directory and file observed")
        let replaced = expectation(description: "Atomic replacement observed")
        let edited = expectation(description: "In-place edit observed")
        let removed = expectation(description: "Deletion observed")
        store.startWatching { loaded in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(loaded?.diagnostics ?? [], [])
            switch loaded?.config.activeProfile?.name {
            case "Created": created.fulfill()
            case "Replaced": replaced.fulfill()
            case "Edited": edited.fulfill()
            case nil: removed.fulfill()
            default: XCTFail("Unexpected config")
            }
        }
        defer { store.stopWatching() }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml("Created").write(to: url, options: .atomic)
        wait(for: [created], timeout: 3)
        try yaml("Replaced").write(to: url, options: .atomic)
        wait(for: [replaced], timeout: 3)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 0)
        try file.write(contentsOf: yaml("Edited"))
        try file.close()
        wait(for: [edited], timeout: 3)
        try FileManager.default.removeItem(at: url)
        wait(for: [removed], timeout: 3)
        XCTAssertNil(store.load())
    }

    func testDebouncesExternalEditsAndIgnoresOwnSaves() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.yaml")
        let store = ConfigStore(url: url)
        let extra = expectation(description: "No callback for own save or intermediate edit")
        extra.isInverted = true
        let changed = expectation(description: "Final external edit observed")
        store.onChange = { loaded in
            if loaded?.config.activeProfile?.name == "Final" {
                changed.fulfill()
            } else {
                extra.fulfill()
                XCTFail("Unexpected callback for own save or intermediate edit")
            }
        }
        defer { store.stopWatching() }
        try store.save(Config(profiles: [Profile(name: "Saved")]))
        try store.save(Config(profiles: [Profile(name: "Saved again")]))
        wait(for: [extra], timeout: 0.4)

        try yaml("Intermediate").write(to: url, options: .atomic)
        try yaml("Final").write(to: url, options: .atomic)
        wait(for: [changed], timeout: 3)
    }

    func testUnreadableConfigReturnsDiagnostic() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.yaml")
        try Data([0xFF]).write(to: url)
        let loaded = try XCTUnwrap(ConfigStore(url: url).loadDetailed())
        XCTAssertEqual(loaded.diagnostics.map(\.severity), [.error])
        XCTAssertFalse(loaded.hasUsableRoot)
    }

    func testSyntaxErrorHasNoUsableRootButBadRuleDoes() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.yaml")
        try Data("profiles: [\n".utf8).write(to: url)
        XCTAssertEqual(ConfigStore(url: url).loadDetailed()?.hasUsableRoot, false)
        try Data("profiles:\n  - name: P\n    rules:\n      - name: R\n".utf8).write(to: url)
        let partial = try XCTUnwrap(ConfigStore(url: url).loadDetailed())
        XCTAssertTrue(partial.hasUsableRoot)
        XCTAssertTrue(partial.hasErrors)
        XCTAssertEqual(partial.config.activeProfile?.name, "P")
    }

    func testRefusesFilesLargerThanTheLimit() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.yaml")
        var text = "profiles: [{name: Big}]\n"
        text += String(repeating: "# padding\n", count: ConfigStore.maximumFileSize / 10 + 1)
        try Data(text.utf8).write(to: url)
        let loaded = try XCTUnwrap(ConfigStore(url: url).loadDetailed())
        XCTAssertFalse(loaded.hasUsableRoot)
        XCTAssertEqual(loaded.config, Config())
        XCTAssertTrue(loaded.diagnostics.first?.message.contains("larger than") == true)
    }

    func testShellActionsAreDisabledForFilesOthersCanWrite() throws {
        let directory = try temporaryDirectory().appendingPathComponent("keyshift")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.yaml")
        let shell = """
        profiles:
          - name: P
            rules:
              - name: R
                map:
                  f13: {shell: say hi}
                  f14: escape
        """
        try Data(shell.utf8).write(to: url)
        try setMode(0o644, url)
        try setMode(0o755, directory)
        let safe = try XCTUnwrap(ConfigStore(url: url).loadDetailed())
        XCTAssertNil(safe.unsafePath)
        XCTAssertEqual(safe.diagnostics, [])
        XCTAssertEqual(safe.engineConfig, safe.config)

        try setMode(0o666, url)
        let file = try XCTUnwrap(ConfigStore(url: url).loadDetailed())
        XCTAssertEqual(file.unsafePath, UnsafePath(path: url.standardizedFileURL.path, problem: .writableByOthers))
        XCTAssertEqual(file.diagnostics.map(\.severity), [.warning])
        XCTAssertTrue(file.diagnostics[0].message.contains("chmod go-w"))
        XCTAssertTrue(file.diagnostics[0].message.contains(url.standardizedFileURL.path))
        XCTAssertEqual(file.config.activeProfile?.rules.first?.mappings.count, 2)
        XCTAssertEqual(file.engineConfig.activeProfile?.rules.first?.mappings.map(\.trigger.description), ["f14"])
        XCTAssertFalse(file.hasErrors)

        try setMode(0o644, url)
        try setMode(0o775, directory)
        let folder = try XCTUnwrap(ConfigStore(url: url).loadDetailed())
        XCTAssertEqual(folder.unsafePath?.path, directory.standardizedFileURL.path)
        XCTAssertFalse(folder.engineConfig.containsShellActions)

        // Without shell actions there is nothing to protect and nothing to report.
        try yaml("Plain").write(to: url)
        XCTAssertEqual(ConfigStore(url: url).loadDetailed()?.diagnostics, [])
        try setMode(0o755, directory)
    }

    private func setMode(_ mode: mode_t, _ url: URL) throws {
        XCTAssertEqual(chmod(url.path, mode), 0)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func yaml(_ name: String) -> Data {
        Data("profiles: [{name: \(name)}]\n".utf8)
    }
}
