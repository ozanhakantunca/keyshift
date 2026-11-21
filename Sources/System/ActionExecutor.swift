import AppKit
import CoreGraphics
import Darwin
import KeyshiftCore

public final class ActionExecutor {
    private let source = EventCodec.makeTaggedSource()

    public init() {}

    /// Probe actions are recorded on the tap thread, so they cannot escape after a timeout.
    func submit(_ actions: [Action], dryRun: ((Action) -> Void)? = nil) {
        guard !actions.isEmpty else { return }
        if let dryRun {
            actions.forEach(dryRun)
        } else {
            DispatchQueue.main.async {
                actions.forEach(self.execute)
            }
        }
    }

    /// Executes non-input actions. The backend invokes this on the main queue.
    @MainActor
    public func execute(_ action: Action) {
        switch action {
        case .openApp(let app): openApp(app)
        case .openURL(let url):
            if let url = URL(string: url), url.scheme != nil { NSWorkspace.shared.open(url) }
        case .shell(let command): launch("/bin/sh", ["-c", command])
        case .system(let action): executeSystemAction(action)
        case .keys, .mouse, .none: break
        }
    }

    @MainActor
    private func openApp(_ name: String) {
        let workspace = NSWorkspace.shared
        guard let url = ApplicationResolver.resolve(name, roots: ApplicationResolver.standardRoots,
                                                     bundleURL: workspace.urlForApplication(withBundleIdentifier:))
        else { return }

        // Launch Services can bring an existing app forward even when Keyshift is in the background.
        workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor
    private func executeSystemAction(_ action: SystemAction) {
        switch action {
        case .launchpad:
            let apps = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
            if let path = apps.first(where: FileManager.default.fileExists(atPath:)) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else {
                post(SystemShortcuts.currentCombo(for: 160) ?? KeyCombo(KeyCode(0), [.function, .shift]))
            }
        case .missionControl:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case .appWindows:
            if let combo = SystemShortcuts.currentCombo(for: 33) { post(combo) }
            else { missionControlMode("2") }
        case .showDesktop:
            if let combo = SystemShortcuts.currentCombo(for: 36) { post(combo) }
            else { missionControlMode("1") }
        case .notificationCenter:
            post(SystemShortcuts.currentCombo(for: 163) ?? KeyCombo(KeyCode(45), .function))
        case .spotlight:
            post(KeyCombo(KeyCode(49), .command))
        case .lockScreen:
            if let lock = Self.lockScreen { lock() }
            else { post(KeyCombo(KeyCode(12), [.control, .command])) }
        case .sleepDisplay:
            launch("/usr/bin/pmset", ["displaysleepnow"])
        case .logout:
            launch("/usr/bin/osascript", ["-e", "tell application \"System Events\" to log out"])
        case .screenshot:
            post(SystemShortcuts.currentCombo(for: 28) ?? KeyCombo(KeyCode(20), [.command, .shift]))
        case .screenshotArea:
            post(SystemShortcuts.currentCombo(for: 30) ?? KeyCombo(KeyCode(21), [.command, .shift]))
        case .screenshotWindow:
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            let path = desktop.appendingPathComponent("Screenshot \(UUID().uuidString).png").path
            launch("/usr/sbin/screencapture", ["-i", "-W", path])
        case .forceQuit:
            post(KeyCombo(KeyCode(53), [.command, .option]))
        case .tileLeft, .tileRight, .tileTop, .tileBottom, .maximize, .center:
            WindowTiler.perform(action)
        }
    }

    private func missionControlMode(_ mode: String) {
        launch("/System/Applications/Mission Control.app/Contents/MacOS/Mission Control", [mode])
    }

    private func post(_ combo: KeyCombo) {
        guard let source,
              let down = EventCodec.makeEvent(.keyDown(combo.key, combo.modifiers, isRepeat: false), source: source),
              let up = EventCodec.makeEvent(.keyUp(combo.key, combo.modifiers), source: source)
        else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func launch(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private typealias LockScreen = @convention(c) () -> Void

    private static let lockScreen: LockScreen? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY | RTLD_LOCAL),
              let function = dlsym(library, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(function, to: LockScreen.self)
    }()
}

enum ApplicationResolver {
    static var standardRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    static func resolve(_ target: String, roots: [URL], bundleURL: (String) -> URL?) -> URL? {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        if target.contains("/") {
            let url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            return isApplication(url) ? url.standardizedFileURL : nil
        }
        if let url = bundleURL(target) { return url }

        let name = appName(target)
        let fileManager = FileManager.default
        for root in roots {
            let direct = root.appendingPathComponent(name + ".app")
            if isApplication(direct) { return direct }
            guard let files = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            var matches: [URL] = []
            for case let url as URL in files where isApplication(url) {
                files.skipDescendants()
                let bundle = Bundle(url: url)
                let names = [url.lastPathComponent, fileManager.displayName(atPath: url.path),
                             bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                             bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String]
                if names.compactMap({ $0 }).contains(where: { appName($0).caseInsensitiveCompare(name) == .orderedSame }) {
                    matches.append(url)
                }
            }
            if let match = matches.min(by: { $0.path < $1.path }) { return match }
        }
        return nil
    }

    private static func isApplication(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return url.pathExtension.lowercased() == "app"
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func appName(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
