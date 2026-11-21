import AppKit
import ApplicationServices

@MainActor
enum ContextSelfTest {
    private static let workspace = NSWorkspace.shared

    static func run(context: ContextProvider) -> [SelfTestSuite.Row] {
        let frontmost = focusedPID()
        defer {
            if let frontmost, focusedPID() != frontmost {
                let app = AXUIElementCreateApplication(frontmost)
                _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
        }
        return [textEdit(context), finder(context)]
    }

    private static func textEdit(_ context: ContextProvider) -> SelfTestSuite.Row {
        let name = "TextEdit live AX"
        let bundleID = "com.apple.TextEdit"
        let wasRunning = runningApp(bundleID) != nil
        let title = "Keyshift-\(UUID())"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(title + ".txt")
        defer {
            try? FileManager.default.removeItem(at: file)
            if !wasRunning { _ = runningApp(bundleID)?.terminate() }
        }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            return .init(name, .warning, "Could not locate TextEdit.")
        }

        let scripted = mayAutomate(bundleID) && ProbeCommand.run("/usr/bin/open", ["-a", "TextEdit"]) != nil
            && runScript("""
                tell application id "com.apple.TextEdit"
                    make new document with properties {name:"\(title)"}
                    activate
                end tell
                """)
        if !scripted {
            // Opening an empty file through Launch Services avoids an Automation prompt.
            guard (try? Data().write(to: file)) != nil else {
                return .init(name, .warning, "Could not create the blank probe file.")
            }
            let options = NSWorkspace.OpenConfiguration()
            options.promptsUserIfNeeded = false
            options.addsToRecentItems = false
            workspace.open([file], withApplicationAt: appURL, configuration: options, completionHandler: nil)
        }

        return check(name, bundleID: bundleID, expectsText: true, context: context) { window in
            let windowTitle: String? = attribute(kAXTitleAttribute, of: window)
            return windowTitle == title || windowTitle == title + ".txt"
        }
    }

    private static func finder(_ context: ContextProvider) -> SelfTestSuite.Row {
        let name = "Finder live AX"
        let bundleID = "com.apple.finder"
        guard let before = windows(of: bundleID) else {
            return .init(name, .warning, "Could not identify Finder's existing windows.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scripted = mayAutomate(bundleID) && runScript("""
            tell application id "com.apple.finder"
                make new Finder window to home
                activate
            end tell
            """)
        guard scripted || workspace.selectFile(nil, inFileViewerRootedAtPath: home.path) else {
            return .init(name, .warning, "Could not open a Finder window at home.")
        }

        return check(name, bundleID: bundleID, expectsText: false, context: context) { window in
            guard !before.contains(where: { CFEqual($0, window) }) else { return false }
            let document: String? = attribute(kAXDocumentAttribute, of: window)
            if let document, let url = URL(string: document), url.isFileURL {
                return url.standardizedFileURL.path == home.standardizedFileURL.path
            }
            let title: String? = attribute(kAXTitleAttribute, of: window)
            return title == home.lastPathComponent
        }
    }

    private static func check(_ name: String, bundleID: String, expectsText: Bool, context: ContextProvider,
                              matchesWindow: (AXUIElement) -> Bool) -> SelfTestSuite.Row {
        let finderContentRoles: Set<String> = ["AXOutline", "AXList", "AXBrowser", "AXTable", "AXScrollArea", "AXCollection"]
        let deadline = Date().addingTimeInterval(2)
        var detail = "The probe window did not receive focus."
        var status = SelfTestSuite.Status.warning
        var probeWindow: AXUIElement?
        repeat {
            if let running = runningApp(bundleID) {
                let app = accessibility(running)
                if focusedPID() == running.processIdentifier,
                   let window: AXUIElement = attribute(kAXFocusedWindowAttribute, of: app), matchesWindow(window) {
                    probeWindow = window
                    if let element: AXUIElement = attribute(kAXFocusedUIElementAttribute, of: app),
                       let role: String = attribute(kAXRoleAttribute, of: element) {
                        if let text = context.isTextInputForProbe() {
                            detail = "\(role), isTextInput() = \(text)"
                            let correctRole = expectsText ? role == kAXTextAreaRole : finderContentRoles.contains(role)
                            if text == expectsText && correctRole {
                                status = .pass
                                break
                            }
                            detail += " (expected isTextInput() = \(expectsText) with document or file-list focus)"
                        } else {
                            detail = "\(role), isTextInput() could not resolve a focused element"
                        }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline

        if let window = probeWindow ?? windows(of: bundleID)?.first(where: matchesWindow) {
            if !close(window, in: bundleID) {
                status = .warning
                detail += ". Could not close the probe window."
            }
        }
        return .init(name, status, detail)
    }

    private static func close(_ window: AXUIElement, in bundleID: String) -> Bool {
        guard let button: AXUIElement = attribute(kAXCloseButtonAttribute, of: window) else { return false }
        AXUIElementSetMessagingTimeout(button, 0.15)
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return false }
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            if let windows = windows(of: bundleID), !windows.contains(where: { CFEqual($0, window) }) { return true }
            Thread.sleep(forTimeInterval: 0.025)
        } while Date() < deadline
        return false
    }

    private static func focusedPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let app: AXUIElement = attribute(kAXFocusedApplicationAttribute, of: system) else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(app, &pid) == .success ? pid : nil
    }

    private static func mayAutomate(_ bundleID: String) -> Bool {
        let status = bundleID.withCString { id -> OSStatus in
            var target = AEAddressDesc()
            guard AECreateDesc(DescType(typeApplicationBundleID), id, strlen(id), &target) == noErr else {
                return OSStatus(paramErr)
            }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard),
                                                        AEEventID(typeWildCard), false)
        }
        return status == noErr
    }

    private static func runScript(_ source: String) -> Bool {
        let script = NSAppleScript(source: "with timeout of 2 seconds\n" + source + "\nend timeout")
        var error: NSDictionary?
        return script?.executeAndReturnError(&error) != nil && error == nil
    }

    private static func runningApp(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private static func accessibility(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }

    private static func windows(of bundleID: String) -> [AXUIElement]? {
        guard let app = runningApp(bundleID) else { return [] }
        return attribute(kAXWindowsAttribute, of: accessibility(app))
    }

    private static func attribute<T>(_ key: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
