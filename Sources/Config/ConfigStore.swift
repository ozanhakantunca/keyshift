import Darwin
import Dispatch
import Foundation
import KeyshiftCore

public final class ConfigStore {
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["KEYSHIFT_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/keyshift/config.yaml")
    }

    public let url: URL

    /// Files larger than this are not read (a real config is a few KB).
    public static let maximumFileSize = 2 * 1024 * 1024
    /// How many previous versions are kept: config.yaml.bak (newest), then config.yaml.bak.1 … .bak.4.
    public static let backupCount = 5

    /// Assigning a callback starts watching. Changes are delivered on the main queue; nil means the file is missing.
    public var onChange: ((LoadedConfig?) -> Void)? {
        get { queue.sync { changeHandler } }
        set {
            queue.sync {
                revision &+= 1
                changeHandler = newValue
                if newValue == nil {
                    debounce?.cancel()
                    debounce = nil
                    fileWatch = nil
                    directoryWatch = nil
                    targetDirectoryWatch = nil
                } else {
                    refreshWatches()
                    observed = read()
                    // Recheck once in case the directory appeared while watching was starting.
                    scheduleReload()
                }
            }
        }
    }

    /// When `save` may replace the file.
    public enum SaveCondition: Sendable {
        case always
        /// Only while the file still holds these bytes (nil: while it is missing).
        case unchangedSince(Data?)
    }

    private enum Snapshot: Equatable {
        case missing
        case contents(Data, unsafePath: UnsafePath?)
        case failed(String)

        func decode() -> LoadedConfig? {
            switch self {
            case .missing:
                return nil
            case .contents(let bytes, let unsafe):
                guard let yaml = String(data: bytes, encoding: .utf8) else {
                    return LoadedConfig(config: Config(), diagnostics: [Diagnostic(message: "Config must be UTF-8 encoded.")],
                                        hasUsableRoot: false, contents: bytes, unsafePath: unsafe)
                }
                let decoded = ConfigCodec.decodeDocument(yaml)
                return LoadedConfig(config: decoded.config, diagnostics: decoded.diagnostics,
                                    hasUsableRoot: decoded.hasUsableRoot, contents: bytes, unsafePath: unsafe)
            case .failed(let message):
                return LoadedConfig(config: Config(), diagnostics: [Diagnostic(message: message)],
                                    hasUsableRoot: false, contents: nil, unsafePath: nil)
            }
        }
    }

    private final class Watch {
        let device: dev_t
        let inode: ino_t
        let source: DispatchSourceFileSystemObject

        init(device: dev_t, inode: ino_t, source: DispatchSourceFileSystemObject) {
            self.device = device
            self.inode = inode
            self.source = source
        }

        deinit { source.cancel() }
    }

    private let queue = DispatchQueue(label: "keyshift.config.store")
    private var changeHandler: ((LoadedConfig?) -> Void)?
    private var fileWatch: Watch?
    private var directoryWatch: Watch?
    /// The directory of a symlinked config's target, so a target that is replaced or recreated is noticed.
    private var targetDirectoryWatch: Watch?
    private var debounce: DispatchWorkItem?
    private var observed: Snapshot = .missing
    private var revision: UInt64 = 0
    private var lastWritten: Data?

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url.standardizedFileURL
    }

    deinit {
        debounce?.cancel()
    }

    /// A missing configuration returns nil. Read and parse failures return diagnostics.
    public func load() -> (Config, [Diagnostic])? {
        loadDetailed().map { ($0.config, $0.diagnostics) }
    }

    /// Like `load`, plus the bytes read, whether anything could be parsed, and the shell action policy.
    public func loadDetailed() -> LoadedConfig? {
        queue.sync { read() }.decode()
    }

    /// Writes the config (through a symlink, to its target) after keeping a backup of the previous
    /// contents. Returns what was written, with its diagnostics and permission check.
    @discardableResult
    public func save(_ config: Config, condition: SaveCondition = .always) throws -> LoadedConfig {
        let text = ConfigCodec.encode(config)
        let bytes = Data(text.utf8)
        let decoded = ConfigCodec.decodeDocument(text)
        return try queue.sync {
            let target = writeTarget()
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let previous: Data?
            do {
                previous = try Data(contentsOf: target)
            } catch where Self.isMissing(error) {
                previous = nil
            }
            if case .unchangedSince(let expected) = condition, previous != expected {
                throw ConfigStoreError.changedOnDisk(url)
            }
            if previous != bytes {
                if let previous { try keepBackup(of: previous) }
                try bytes.write(to: target, options: .atomic)
            }
            lastWritten = bytes
            let unsafe = Self.unsafePermissions(for: url)
            if changeHandler != nil {
                observed = .contents(bytes, unsafePath: unsafe)
                revision &+= 1
                refreshWatches()
                scheduleReload()
            }
            return LoadedConfig(config: config, diagnostics: decoded.diagnostics, hasUsableRoot: decoded.hasUsableRoot,
                                contents: bytes, unsafePath: unsafe)
        }
    }

    public func startWatching(onChange: @escaping (LoadedConfig?) -> Void) {
        self.onChange = onChange
    }

    public func stopWatching() {
        onChange = nil
    }

    /// Backup `index` (0 is the newest): config.yaml.bak, config.yaml.bak.1, …
    public func backupURL(_ index: Int = 0) -> URL {
        let base = url.appendingPathExtension("bak")
        return index == 0 ? base : base.appendingPathExtension(String(index))
    }

    /// Where a previous file that did not parse is kept, so it never replaces a good backup.
    public var invalidBackupURL: URL { url.appendingPathExtension("invalid.bak") }

    /// The file a symlinked config points to; the config path itself otherwise.
    private func writeTarget() -> URL {
        var info = stat()
        let isLink = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK } ?? false
        }
        return isLink ? url.resolvingSymlinksInPath() : url
    }

    private func keepBackup(of previous: Data) throws {
        // Bytes this store wrote are encoded from a Config and need no second look.
        let parses = previous == lastWritten || String(data: previous, encoding: .utf8).map { yaml in
            !ConfigCodec.decodeDocument(yaml).diagnostics.contains { $0.severity == .error }
        } ?? false
        guard parses else {
            try previous.write(to: invalidBackupURL, options: .atomic)
            return
        }
        let manager = FileManager.default
        if (try? Data(contentsOf: backupURL())) == previous { return }
        try? manager.removeItem(at: backupURL(Self.backupCount - 1))
        for index in stride(from: Self.backupCount - 2, through: 0, by: -1)
        where manager.fileExists(atPath: backupURL(index).path) {
            try manager.moveItem(at: backupURL(index), to: backupURL(index + 1))
        }
        try previous.write(to: backupURL(), options: .atomic)
    }

    private func read() -> Snapshot {
        let target = writeTarget()
        var info = stat()
        let status = target.withUnsafeFileSystemRepresentation { path in path.map { stat($0, &info) } ?? -1 }
        if status != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            return .failed("Cannot read config at \(url.path). \(String(cString: strerror(code))).")
        }
        if info.st_size > Self.maximumFileSize {
            return .failed("Config at \(url.path) is larger than \(Self.maximumFileSize / 1024 / 1024) MB and was not read.")
        }
        do {
            return .contents(try Data(contentsOf: target), unsafePath: Self.unsafePermissions(for: url))
        } catch where Self.isMissing(error) {
            return .missing
        } catch {
            return .failed("Cannot read config at \(url.path). \(error.localizedDescription)")
        }
    }

    /// A path whose owner or mode lets another user change the config: the file (and a symlink's
    /// target) or the directory holding it. Root-owned paths count as safe.
    public static func unsafePermissions(for url: URL) -> UnsafePath? {
        let url = url.standardizedFileURL
        var paths = [url, url.deletingLastPathComponent()]
        let target = url.resolvingSymlinksInPath()
        if target != url { paths += [target, target.deletingLastPathComponent()] }
        let uid = getuid()
        for path in paths {
            var info = stat()
            guard stat(path.path, &info) == 0 else { continue }
            if info.st_uid != uid && info.st_uid != 0 {
                return UnsafePath(path: path.path, problem: .owner)
            }
            if info.st_mode & (S_IWGRP | S_IWOTH) != 0 {
                return UnsafePath(path: path.path, problem: .writableByOthers)
            }
        }
        return nil
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    }

    private func refreshWatches() {
        fileWatch = watch(url, replacing: fileWatch)
        let target = writeTarget()
        targetDirectoryWatch = target == url ? nil : watch(target.deletingLastPathComponent(), replacing: targetDirectoryWatch)
        var directory = url.deletingLastPathComponent()
        while true {
            if let watch = watch(directory, replacing: directoryWatch) {
                directoryWatch = watch
                return
            }
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { break }
            directory = parent
        }
        directoryWatch = nil
    }

    private func watch(_ url: URL, replacing current: Watch?) -> Watch? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_EVTONLY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            return nil
        }
        if let current, current.device == info.st_dev, current.inode == info.st_ino {
            close(descriptor)
            return current
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke, .attrib, .extend, .link],
            queue: queue
        )
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.resume()
        return Watch(device: info.st_dev, inode: info.st_ino, source: source)
    }

    private func scheduleReload() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reload() }
        debounce = item
        queue.asyncAfter(deadline: .now() + .milliseconds(150), execute: item)
    }

    private func reload() {
        guard changeHandler != nil else { return }
        debounce = nil
        refreshWatches()
        let snapshot = read()
        guard snapshot != observed else { return }
        observed = snapshot
        let loaded = snapshot.decode()
        let revision = self.revision
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let handler = queue.sync { self.revision == revision ? self.changeHandler : nil }
            handler?(loaded)
        }
    }
}

public enum ConfigStoreError: LocalizedError, Equatable {
    case changedOnDisk(URL)

    public var errorDescription: String? {
        switch self {
        case .changedOnDisk(let url): return "\(url.path) changed on disk. Reload it and try again."
        }
    }
}

/// A config path that other users could modify.
public struct UnsafePath: Hashable, Sendable {
    public enum Problem: Hashable, Sendable { case owner, writableByOthers }
    public let path: String
    public let problem: Problem

    public init(path: String, problem: Problem) {
        self.path = path
        self.problem = problem
    }

    public var diagnostic: Diagnostic {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch problem {
        case .owner:
            return Diagnostic(message: "Shell actions are disabled because \(path) is not owned by you. "
                + "Fix it with: sudo chown \(NSUserName()) \(quoted)", severity: .warning)
        case .writableByOthers:
            return Diagnostic(message: "Shell actions are disabled because \(path) is writable by other users. "
                + "Fix it with: chmod go-w \(quoted)", severity: .warning)
        }
    }
}

/// A config file as read from (or just written to) disk.
public struct LoadedConfig: Sendable {
    public var config: Config
    /// Parse diagnostics, plus a warning while shell actions are disabled by `unsafePath`.
    public let diagnostics: [Diagnostic]
    /// False when nothing could be read (syntax error, unreadable, too large, not UTF-8).
    public let hasUsableRoot: Bool
    /// The bytes on disk; nil when the file could not be read.
    public let contents: Data?
    /// Set when the config has shell actions and the file or its directory could be changed by another user.
    public let unsafePath: UnsafePath?

    public init(config: Config, diagnostics: [Diagnostic], hasUsableRoot: Bool, contents: Data?,
                unsafePath: UnsafePath?) {
        self.config = config
        self.hasUsableRoot = hasUsableRoot
        self.contents = contents
        let unsafe = config.containsShellActions ? unsafePath : nil
        self.unsafePath = unsafe
        self.diagnostics = diagnostics + [unsafe?.diagnostic].compactMap { $0 }
    }

    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    /// What the engine may run: shell actions are removed while `unsafePath` is set.
    public var engineConfig: Config {
        unsafePath == nil ? config : config.removingShellActions()
    }
}

extension Config {
    public var containsShellActions: Bool {
        profiles.contains { $0.rules.contains { $0.mappings.contains { $0.action.isShell } } }
    }

    /// The same config without the mappings that run shell commands, so those keys pass through.
    public func removingShellActions() -> Config {
        var config = self
        for p in config.profiles.indices {
            for r in config.profiles[p].rules.indices {
                config.profiles[p].rules[r].mappings.removeAll { $0.action.isShell }
            }
        }
        return config
    }
}

private extension Action {
    var isShell: Bool {
        if case .shell = self { return true }
        return false
    }
}
