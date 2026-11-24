import AppKit
import CoreGraphics
import Darwin
import KeyshiftCore

public final class ActionExecutor {
    private let source = EventCodec.makeTaggedSource()
    /// Main queue only.
    private var applications = ApplicationCache()

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
        // Disclaimed, so the command does not run with Keyshift's Accessibility/Input Monitoring grants.
        case .shell(let command): launch("/bin/sh", ["-c", command], disclaimingResponsibility: true)
        case .system(let action): executeSystemAction(action)
        case .keys, .mouse, .none: break
        }
    }

    @MainActor
    private func openApp(_ name: String) {
        let workspace = NSWorkspace.shared
        guard let url = applications.url(for: name, resolve: {
            ApplicationResolver.resolve($0, roots: ApplicationResolver.standardRoots,
                                        bundleURL: workspace.urlForApplication(withBundleIdentifier:))
        }) else { return }

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

    private func launch(_ path: String, _ arguments: [String], disclaimingResponsibility: Bool = false) {
        _ = Self.spawn(path, arguments, disclaimingResponsibility: disclaimingResponsibility)
    }

    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    // Private libsystem SPI (used by terminal emulators); RTLD_DEFAULT is ((void *)-2).
    static let setDisclaim: SetDisclaim? = {
        guard let function = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        else { return nil }
        return unsafeBitCast(function, to: SetDisclaim.self)
    }()

    /// Spawns with stdio on /dev/null, the current environment, default signal handling (Keyshift
    /// ignores SIGTERM/SIGINT/SIGHUP) and no other inherited descriptors. A detached thread reaps
    /// the child and passes its raw wait status to `onExit`. Returns nil if the spawn failed.
    @discardableResult
    static func spawn(_ path: String, _ arguments: [String], disclaimingResponsibility: Bool,
                      onExit: (@Sendable (Int32) -> Void)? = nil) -> pid_t? {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        var mask = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0 else { return nil }
        if disclaimingResponsibility, let setDisclaim { _ = setDisclaim(&attributes, 1) }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid = pid_t()
        guard posix_spawn(&pid, path, &actions, &attributes, argv, environ) == 0 else { return nil }

        let reaper = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            onExit?(status)
        }
        reaper.name = "Keyshift child reaper"
        reaper.stackSize = 64 * 1024
        reaper.start()
        return pid
    }

    private typealias LockScreen = @convention(c) () -> Void

    private static let lockScreen: LockScreen? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY | RTLD_LOCAL),
              let function = dlsym(library, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(function, to: LockScreen.self)
    }()
}

/// Remembers resolved applications; a cached bundle that no longer exists is resolved again.
struct ApplicationCache {
    private var urls: [String: URL] = [:]

    mutating func url(for target: String, resolve: (String) -> URL?) -> URL? {
        if let url = urls[target], FileManager.default.fileExists(atPath: url.path) { return url }
        let url = resolve(target)
        urls[target] = url
        return url
    }
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
        // Direct paths in every root before any (slow) enumeration.
        for root in roots {
            let direct = root.appendingPathComponent(name + ".app")
            if isApplication(direct) { return direct }
        }
        for root in roots {
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
