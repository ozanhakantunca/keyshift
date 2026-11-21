import AppKit
import ApplicationServices
import Foundation

struct Permissions: Encodable {
    struct Check: Encodable {
        let api: String
        let pane: String
        let granted: Bool
    }

    let app: String
    let bundleID: String
    let checks: [Check]
    let requested: String?
}

@MainActor
func preflight(output: URL) throws {
    _ = NSApplication.shared
    let accessibility = AXIsProcessTrusted()
    let posting = CGPreflightPostEventAccess()
    let listening = CGPreflightListenEventAccess()
    let screenshots = CGPreflightScreenCaptureAccess()
    // Request every missing grant at once so all panes list the app in one visit.
    var asked: [String] = []
    if !accessibility {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        asked.append("AXIsProcessTrustedWithOptions")
    }
    if !posting { _ = CGRequestPostEventAccess(); asked.append("CGRequestPostEventAccess") }
    if !listening { _ = CGRequestListenEventAccess(); asked.append("CGRequestListenEventAccess") }
    if !screenshots { _ = CGRequestScreenCaptureAccess(); asked.append("CGRequestScreenCaptureAccess") }
    let requested: String? = asked.isEmpty ? nil : asked.joined(separator: ", ")
    let permissions = Permissions(
        app: Bundle.main.bundlePath,
        bundleID: Bundle.main.bundleIdentifier ?? "",
        checks: [
            .init(api: "AXIsProcessTrusted", pane: "Accessibility", granted: accessibility),
            .init(api: "CGPreflightPostEventAccess", pane: "Accessibility", granted: posting),
            .init(api: "CGPreflightListenEventAccess", pane: "Input Monitoring", granted: listening),
            .init(api: "CGPreflightScreenCaptureAccess", pane: "Screen & System Audio Recording", granted: screenshots),
        ],
        requested: requested
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(permissions).write(to: output, options: .atomic)
}

@main
struct KeyshiftE2E {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { exit(64) }
        let url = URL(fileURLWithPath: arguments[2])
        switch arguments[1] {
        case "--preflight": try preflight(output: url)
        case "--serve":
            NSApplication.shared.setActivationPolicy(.accessory)
            try TestSession(directory: url).run()
        case "--game": runGame(log: url)
        default: exit(64)
        }
    }

    @MainActor
    private static func runGame(log: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 550, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Keyshift E2E FakeGame"
        let label = NSTextField(wrappingLabelWithString: "FakeGame waits for delivered keyboard events")
        label.frame = NSRect(x: 36, y: 95, width: 475, height: 100)
        label.font = .systemFont(ofSize: 24)
        window.contentView?.addSubview(label)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let line = "\(event.type.rawValue) \(event.keyCode) \(event.modifierFlags.rawValue)\n"
            if let file = try? FileHandle(forWritingTo: log) {
                _ = try? file.seekToEnd()
                try? file.write(contentsOf: Data(line.utf8))
                try? file.close()
            }
            label.stringValue += "\n" + line.trimmingCharacters(in: .newlines)
            return nil
        }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime((window, monitor)) { app.run() }
    }
}
