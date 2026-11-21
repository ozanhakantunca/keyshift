import ApplicationServices
import Foundation
import KeyshiftCore

/// Installed and called on the backend's tap thread. The suite waits for both taps
/// to account for each input before posting the next, including inputs consumed by the engine.
final class SuiteEventProbe {
    let marker = Int64.random(in: 1..<EventCodec.syntheticTag)
    private let condition = NSCondition()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var interrupted = false
    private var inputs = 0
    private var forwarded = 0
    private var observed: [InputEvent] = []
    private var actions: [Action] = []

    var isReady: Bool {
        guard let tap, CGEvent.tapIsEnabled(tap: tap) else { return false }
        return condition.withLock { !interrupted }
    }

    func install() -> Bool {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: EventCodec.eventMask, callback: { _, type, event, data in
                guard let data else { return Unmanaged.passUnretained(event) }
                let probe = Unmanaged<SuiteEventProbe>.fromOpaque(data).takeUnretainedValue()
                return probe.observe(event, type: type)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        if isReady { return true }
        uninstall()
        return false
    }

    func uninstall() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopSourceInvalidate(source) }
        tap = nil
        source = nil
    }

    func noteTapDisabled() {
        condition.withLock {
            interrupted = true
            condition.broadcast()
        }
    }

    private func observe(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            noteTapDisabled()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) == marker else {
            return Unmanaged.passUnretained(event)
        }
        if var input = EventCodec.decode(event, type: type) {
            input.timestamp = 0
            condition.withLock {
                observed.append(input)
                condition.broadcast()
            }
        }
        return nil
    }

    func recordInput(forwarded count: Int) {
        condition.withLock {
            inputs += 1
            forwarded += count
            condition.broadcast()
        }
    }

    func recordAction(_ action: Action) {
        condition.withLock { actions.append(action) }
    }

    func capture(_ events: [CGEvent]) -> (events: [InputEvent], actions: [Action], completed: Bool) {
        condition.lock()
        defer { condition.unlock() }
        inputs = 0
        forwarded = 0
        observed.removeAll()
        actions.removeAll()

        for (index, event) in events.enumerated() {
            if interrupted { break }
            // Don't hold the condition across Quartz calls. Both callbacks use it.
            condition.unlock()
            event.post(tap: .cgSessionEventTap)
            condition.lock()

            let deadline = Date().addingTimeInterval(0.75)
            while !interrupted && (inputs <= index || observed.count < forwarded) {
                if !condition.wait(until: deadline) { break }
            }
            if inputs != index + 1 || observed.count != forwarded || interrupted {
                return (observed, actions, false)
            }
        }
        return (observed, actions, !interrupted)
    }
}
