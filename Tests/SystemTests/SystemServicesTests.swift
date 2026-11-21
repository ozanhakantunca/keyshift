import CoreGraphics
import KeyshiftCore
@testable import KeyshiftSystem
import XCTest

final class SystemServicesTests: XCTestCase {
    func testApplicationResolutionByPathIdentifierAndDisplayName() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        let path = first.appendingPathComponent("Nested/InternalName.app", isDirectory: true)
        let other = second.appendingPathComponent("Other.app", isDirectory: true)
        try createApp(at: path, bundleID: "io.keyshift.fixture", displayName: "Friendly Name")
        try createApp(at: other, bundleID: "io.keyshift.other", displayName: "Friendly Name")

        let lookup: (String) -> URL? = { $0 == "io.keyshift.fixture" ? path : nil }
        let roots = [first, second]
        XCTAssertEqual(ApplicationResolver.resolve(path.path, roots: [], bundleURL: lookup)?.standardizedFileURL.path, path.standardizedFileURL.path)
        XCTAssertEqual(ApplicationResolver.resolve("io.keyshift.fixture", roots: [], bundleURL: lookup), path)
        XCTAssertEqual(ApplicationResolver.resolve("  friendly name  ", roots: roots, bundleURL: lookup)?.standardizedFileURL.path, path.standardizedFileURL.path)
        XCTAssertEqual(ApplicationResolver.resolve("internalname.app", roots: roots, bundleURL: lookup)?.standardizedFileURL.path, path.standardizedFileURL.path)
        XCTAssertNil(ApplicationResolver.resolve("Internal", roots: roots, bundleURL: lookup))
        XCTAssertNil(ApplicationResolver.resolve(root.path, roots: roots, bundleURL: lookup))
    }

    func testFinderResolvesByNameFromSystemApplicationRoots() {
        let finder = ApplicationResolver.resolve("Finder", roots: ApplicationResolver.standardRoots, bundleURL: { _ in nil })
        XCTAssertEqual(finder?.path, "/System/Library/CoreServices/Finder.app")
    }

    func testSymbolicHotKeysParseEnabledKeyboardBindingsOnly() throws {
        let command = Int(CGEventFlags.maskCommand.rawValue)
        let control = Int(CGEventFlags.maskControl.rawValue)
        let fn = Int(CGEventFlags.maskSecondaryFn.rawValue)
        let fixture: [String: Any] = [
            "64": hotkey([32, 49, command]),
            "28": hotkey([65_535, 103, command | Int(CGEventFlags.maskShift.rawValue) | fn]),
            "33": hotkey([65_535, 125, control | fn]),
            "163": hotkey([110, 45, fn]),
            "800": hotkey([0, 0, command]),
            "54": hotkey([65_535, 120, fn]),
            "79": hotkey([65_535, 123, 0x800000 | 0x80000 | 0x20000 | 0x100000 | 0x40000]),
            "30": hotkey([65_535, 21, command], enabled: false),
            "160": hotkey([65_535, 65_535, 0]),
            "910": hotkey([65_535, -1, 0]),
            "911": hotkey([1, 2]),
            "912": hotkey([1, 2, 3], type: "modifier"),
            "not-an-id": hotkey([1, 2, 3]),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        let properties = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(SystemShortcuts.parse(properties), [
            KeyCombo(KeyCode(49), .command): "Spotlight",
            KeyCombo(KeyCode(103), [.command, .shift]): "Save Screenshot",
            KeyCombo(KeyCode(125), .control): "Application Windows",
            KeyCombo(KeyCode(45), .function): "Notification Center",
            KeyCombo(KeyCode(123), [.shift, .control, .option, .command]): "Move Left a Space",
        ])
    }

    func testKarabinerProcessMatchingUsesExactExecutableNames() {
        let executables = [
            "karabiner_grabber", "Karabiner-Core-Service",
            "karabiner_console_user_server", "Karabiner-Console-User-Server",
        ]
        for name in executables {
            XCTAssertTrue(KarabinerDetector.matchesProcess(name))
            XCTAssertTrue(KarabinerDetector.matchesProcess("   /Library/Application Support/org.pqrs/bin/\(name)  "))
        }
        XCTAssertFalse(KarabinerDetector.matchesProcess("Karabiner-Elements"))
        XCTAssertFalse(KarabinerDetector.matchesProcess("/opt/tools/fake-karabiner_grabber"))
        XCTAssertFalse(KarabinerDetector.matchesProcess("karabiner_grabber --test"))
    }

    private func createApp(at url: URL, bundleID: String, displayName: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func hotkey(_ parameters: [Int], enabled: Bool = true, type: String = "standard") -> [String: Any] {
        ["enabled": enabled, "value": ["type": type, "parameters": parameters]]
    }
}
