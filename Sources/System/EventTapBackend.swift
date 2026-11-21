import CoreGraphics
import Foundation
import KeyshiftCore

public final class EventTapBackend {
    public enum StartError: LocalizedError {
        case eventSourceUnavailable
        case tapUnavailable
        case runLoopSourceUnavailable

        public var errorDescription: String? {
            switch self {
            case .eventSourceUnavailable: return "Could not create a Quartz event source."
            case .tapUnavailable: return "Could not create the event tap. Check Accessibility and Input Monitoring."
            case .runLoopSourceUnavailable: return "Could not create the event tap’s run-loop source."
            }
        }
    }

    private let engine: RemapEngine
    private let context: ContextProvider
    private let executor: ActionExecutor
    private let viewer = Viewer()
    private let controls = NSLock()
    private var session: Session?
    private var config: Config?
    private var layout = KeyLayoutMap.identity
    private var appliesLayout = true
    private var paused = false

    public init(engine: RemapEngine, context: ContextProvider, executor: ActionExecutor) {
        self.engine = engine
        self.context = context
        self.executor = executor
    }

    deinit { stop() }

    /// Receives decoded input and its decision on the main queue, including passes while paused.
    public var onEvent: ((InputEvent, Decision) -> Void)? {
        get { viewer.lock.withLock { viewer.callback } }
        set { viewer.lock.withLock { viewer.callback = newValue } }
    }

    public var isRunning: Bool { controls.withLock { session?.isRunning == true } }

    public func start() throws {
        try controls.withLock {
            guard session?.isRunning != true else { return }
            let session = Session(engine: engine, context: context, executor: executor, viewer: viewer,
                                  initialConfig: config.map(effectiveConfig), paused: paused)
            try session.start()
            self.session = session
        }
    }

    public func stop() {
        controls.withLock {
            session?.stop()
            session = nil
        }
    }

    public func setPaused(_ paused: Bool) {
        controls.withLock {
            guard self.paused != paused else { return }
            self.paused = paused
            session?.perform { session in
                session.paused = paused
                if paused { session.engine.reset() }
            }
        }
    }

    /// Applies a configuration update between events. Before start, keeps the latest config for the new tap.
    /// Keys are translated to the active keyboard layout unless `applyingLayout` is false (raw key codes).
    public func reload(_ config: Config, applyingLayout: Bool = true) {
        controls.withLock {
            self.config = config
            appliesLayout = applyingLayout
            let effective = effectiveConfig(config)
            session?.perform { $0.engine.load(config: effective) }
        }
    }

    /// Re-installs the current config for another keyboard layout (input source change).
    public func setKeyLayout(_ layout: KeyLayoutMap) {
        controls.withLock {
            guard self.layout != layout else { return }
            self.layout = layout
            guard let config else { return }
            let effective = effectiveConfig(config)
            session?.perform { $0.engine.load(config: effective) }
        }
    }

    /// Called with `controls` held.
    private func effectiveConfig(_ config: Config) -> Config { appliesLayout ? layout.apply(to: config) : config }

    func beginProbe(_ probe: SuiteEventProbe) -> Bool {
        controls.withLock {
            guard !paused, let session, let config else { return false }
            let effective = effectiveConfig(config)
            var started = false
            session.perform { started = $0.beginProbe(probe, config: effective) }
            return started
        }
    }

    func prepareProbe(context: ContextProvider.TestOverride, config: Config?) -> Bool {
        controls.withLock {
            var ready = false
            session?.perform { ready = $0.prepareProbe(context: context, config: config) }
            return ready
        }
    }

    func endProbe() {
        controls.withLock { session?.perform { $0.endProbe() } }
    }

    private final class Viewer {
        let lock = NSLock()
        var callback: ((InputEvent, Decision) -> Void)?

        func deliver(_ event: InputEvent, _ decision: Decision) {
            if let callback = lock.withLock({ self.callback }) {
                DispatchQueue.main.async { callback(event, decision) }
            }
        }
    }

    /// The callback and every engine call run on the session thread.
    private final class Session {
        let engine: RemapEngine
        private let context: ContextProvider
        private let executor: ActionExecutor
        private let viewer: Viewer
        private let initialConfig: Config?
        var paused: Bool

        private let started = DispatchSemaphore(value: 0)
        private let completion = NSCondition()
        private var finished = false
        // Published once by the session thread before 'started' signals.
        private var startup: Result<CFRunLoop, StartError>!

        private var tap: CFMachPort?
        private var eventSource: CGEventSource?
        private struct Probe {
            let capture: SuiteEventProbe
            let engine: Engine
            var context: ContextProvider.TestOverride? = nil
        }

        private var probe: Probe?

        init(engine: RemapEngine, context: ContextProvider, executor: ActionExecutor, viewer: Viewer,
             initialConfig: Config?, paused: Bool) {
            self.engine = engine
            self.context = context
            self.executor = executor
            self.viewer = viewer
            self.initialConfig = initialConfig
            self.paused = paused
        }

        func start() throws {
            let thread = Thread { self.run() }
            thread.name = "Keyshift event tap"
            thread.qualityOfService = .userInteractive
            thread.start()
            started.wait()
            _ = try startup.get()
        }

        var isRunning: Bool { completion.withLock { !finished } }

        func stop() {
            perform { _ in CFRunLoopStop(CFRunLoopGetCurrent()) }
            completion.lock()
            while !finished { completion.wait() }
            completion.unlock()
        }

        func perform(_ operation: @escaping (Session) -> Void) {
            completion.lock()
            defer { completion.unlock() }
            guard !finished, case .success(let loop) = startup else { return }

            var applied = false
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
                guard let self else { return }
                operation(self)
                self.completion.withLock {
                    applied = true
                    self.completion.broadcast()
                }
            }
            CFRunLoopWakeUp(loop)
            while !applied && !finished { completion.wait() }
        }

        private func run() {
            defer {
                completion.withLock {
                    finished = true
                    completion.broadcast()
                }
            }
            let source: CFRunLoopSource
            do {
                source = try installTap()
            } catch {
                startup = .failure(error)
                started.signal()
                return
            }

            let loop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(loop, source, .defaultMode)
            if let initialConfig { engine.load(config: initialConfig) }
            if paused { engine.reset() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            startup = .success(loop)
            started.signal()

            CFRunLoopRun()

            endProbe()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            CFRunLoopRemoveSource(loop, source, .defaultMode)
            CFRunLoopSourceInvalidate(source)
            engine.reset()
        }

        private func installTap() throws(StartError) -> CFRunLoopSource {
            guard let eventSource = EventCodec.makeTaggedSource() else { throw .eventSourceUnavailable }
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: EventCodec.eventMask, callback: { proxy, type, event, data in
                    guard let data else { return Unmanaged.passUnretained(event) }
                    let session = Unmanaged<Session>.fromOpaque(data).takeUnretainedValue()
                    return autoreleasepool { session.handle(proxy: proxy, type: type, event: event) }
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else { throw .tapUnavailable }
            guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                CFMachPortInvalidate(tap)
                throw .runLoopSourceUnavailable
            }
            self.eventSource = eventSource
            self.tap = tap
            return source
        }

        func beginProbe(_ probe: SuiteEventProbe, config: Config) -> Bool {
            guard self.probe == nil, probe.install() else { return false }
            // Share the running configuration and tap without affecting physical held-key state.
            self.probe = Probe(capture: probe, engine: Engine(config: config))
            return true
        }

        func prepareProbe(context: ContextProvider.TestOverride, config: Config?) -> Bool {
            guard let probe, probe.capture.isReady else { return false }
            self.probe?.context = context
            probe.engine.reset()
            if let config { probe.engine.load(config: config) }
            return true
        }

        func endProbe() {
            probe?.capture.uninstall()
            probe = nil
        }

        private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                engine.reset()
                probe?.engine.reset()
                probe?.capture.noteTapDisabled()
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let tag = event.getIntegerValueField(.eventSourceUserData)
            guard tag != EventCodec.syntheticTag else { return Unmanaged.passUnretained(event) }
            let test = probe.flatMap { $0.capture.marker == tag ? $0 : nil }
            // A disabled observer cannot safely capture a probe.
            if let test, !test.capture.isReady || test.context == nil { return nil }
            guard let input = EventCodec.decode(event, type: type) else {
                return test == nil ? Unmanaged.passUnretained(event) : nil
            }

            let activeEngine: RemapEngine = test?.engine ?? engine
            let decision = paused ? .pass : activeEngine.handle(input, context: context.makeContext(override: test?.context))
            emit(decision.emit, proxy: proxy, fallbackLocation: event.location, marker: test?.capture.marker)
            executor.submit(decision.actions, dryRun: test.map { $0.capture.recordAction })
            let result: Unmanaged<CGEvent>?
            switch decision.disposition {
            case .pass:
                result = Unmanaged.passUnretained(event)
            case .rewrite(let output):
                EventCodec.rewrite(event, as: output)
                result = Unmanaged.passUnretained(event)
            case .replace:
                result = nil
            }
            if let test {
                test.capture.recordInput(forwarded: decision.emit.count + (result == nil ? 0 : 1))
            } else {
                viewer.deliver(input, decision)
            }
            return result
        }

        private func emit(_ outputs: [OutputEvent], proxy: CGEventTapProxy, fallbackLocation: CGPoint,
                          marker: Int64?) {
            guard let eventSource else { return }
            var cursor: CGPoint?
            for output in outputs {
                switch output {
                case .mouseDown, .mouseUp:
                    if cursor == nil {
                        cursor = marker == nil ? CGEvent(source: nil)?.location ?? fallbackLocation : fallbackLocation
                    }
                case .keyDown, .keyUp:
                    break
                }
                if let event = EventCodec.makeEvent(output, source: eventSource, location: cursor ?? .zero) {
                    if let marker { event.setIntegerValueField(.eventSourceUserData, value: marker) }
                    // Posting through the proxy starts downstream of this tap.
                    event.tapPostEvent(proxy)
                }
            }
        }
    }
}
