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

    /// Assigning a callback starts watching. Changes are delivered on the main queue.
    public var onChange: ((Config, [Diagnostic]) -> Void)? {
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
                } else {
                    refreshWatches()
                    observed = read()
                    // Recheck once in case the directory appeared while watching was starting.
                    scheduleReload()
                }
            }
        }
    }

    private enum Snapshot: Equatable {
        case missing
        case contents(Data)
        case failed(String)

        func decode() -> (Config, [Diagnostic])? {
            switch self {
            case .missing:
                return nil
            case .contents(let bytes):
                guard let yaml = String(data: bytes, encoding: .utf8) else {
                    return (Config(), [Diagnostic(message: "Config must be UTF-8 encoded.")])
                }
                return ConfigCodec.decode(yaml)
            case .failed(let message):
                return (Config(), [Diagnostic(message: message)])
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
    private var changeHandler: ((Config, [Diagnostic]) -> Void)?
    private var fileWatch: Watch?
    private var directoryWatch: Watch?
    private var debounce: DispatchWorkItem?
    private var observed: Snapshot = .missing
    private var revision: UInt64 = 0

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url.standardizedFileURL
    }

    deinit {
        debounce?.cancel()
    }

    /// A missing configuration returns nil. Read and parse failures return diagnostics.
    public func load() -> (Config, [Diagnostic])? {
        queue.sync { read() }.decode()
    }

    public func save(_ config: Config) throws {
        let bytes = Data(ConfigCodec.encode(config).utf8)
        try queue.sync {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let previous: Data?
            do {
                previous = try Data(contentsOf: url)
            } catch where Self.isMissing(error) {
                previous = nil
            }
            if let previous {
                try previous.write(to: url.appendingPathExtension("bak"), options: .atomic)
            }
            try bytes.write(to: url, options: .atomic)
            if changeHandler != nil {
                observed = .contents(bytes)
                revision &+= 1
                refreshWatches()
                scheduleReload()
            }
        }
    }

    public func startWatching(onChange: @escaping (Config, [Diagnostic]) -> Void) {
        self.onChange = onChange
    }

    public func stopWatching() {
        onChange = nil
    }

    private func read() -> Snapshot {
        do {
            return .contents(try Data(contentsOf: url))
        } catch where Self.isMissing(error) {
            return .missing
        } catch {
            return .failed("Cannot read config at \(url.path). \(error.localizedDescription)")
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    }

    private func refreshWatches() {
        fileWatch = watch(url, replacing: fileWatch)
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
        let (config, diagnostics) = snapshot.decode() ?? (Config(), [])
        let revision = self.revision
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let handler = queue.sync { self.revision == revision ? self.changeHandler : nil }
            handler?(config, diagnostics)
        }
    }
}
