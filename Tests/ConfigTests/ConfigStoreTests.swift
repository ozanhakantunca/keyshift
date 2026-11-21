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

    func testWatchesNewDirectoryThenReplacementAndInPlaceEdit() throws {
        let url = try temporaryDirectory().appendingPathComponent("nested/config.yaml")
        let store = ConfigStore(url: url)
        let created = expectation(description: "New directory and file observed")
        let replaced = expectation(description: "Atomic replacement observed")
        let edited = expectation(description: "In-place edit observed")
        let removed = expectation(description: "Deletion observed")
        store.startWatching { config, diagnostics in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(diagnostics, [])
            switch config.activeProfile?.name {
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
        store.onChange = { config, _ in
            if config.activeProfile?.name == "Final" {
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
        let (_, diagnostics) = try XCTUnwrap(ConfigStore(url: url).load())
        XCTAssertEqual(diagnostics.map(\.severity), [.error])
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
