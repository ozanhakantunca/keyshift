import ApplicationServices
import Foundation
import KeyshiftCore

public enum SelfTest {
    public struct Result: Sendable, Equatable {
        public enum Outcome: String, Sendable {
            case passed
            case backendNotRunning
            case accessibilityRequired
            case invalidProbe
            case observerUnavailable
            case eventCreationFailed
            case timedOut
            case mismatch
        }

        public let outcome: Outcome
        public let input: KeyCombo
        public let expected: KeyCombo
        public let observed: [InputEvent]

        public var passed: Bool { outcome == .passed }
    }

    /// Posts an ordinary key pair through the HID entry point and inspects it after the
    /// backend's session tap. The backend must already be configured for the chosen remap.
    /// The observer swallows the marked probe so it never reaches the frontmost app.
    public static func run(
        backend: EventTapBackend, input: KeyCombo = KeyCombo(KeyCode(8), .control),
        expected: KeyCombo = KeyCombo(KeyCode(8), .command), timeout: TimeInterval = 0.75
    ) -> Result {
        let capture = Capture(input: input, expected: expected)
        func result(_ outcome: Result.Outcome) -> Result {
            Result(outcome: outcome, input: input, expected: expected, observed: capture.observed)
        }

        guard backend.isRunning else { return result(.backendNotRunning) }
        guard AXIsProcessTrusted() else { return result(.accessibilityRequired) }
        guard !input.key.isModifier, !expected.key.isModifier, input != expected,
              timeout.isFinite, timeout > 0 else { return result(.invalidProbe) }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, data in
                guard let data else { return Unmanaged.passUnretained(event) }
                return Unmanaged<Capture>.fromOpaque(data).takeUnretainedValue().observe(event, type: type)
            },
            userInfo: Unmanaged.passUnretained(capture).toOpaque()
        ) else { return result(.observerUnavailable) }
        // An active tap that nobody services would stall all key events; enable it only while running.
        CGEvent.tapEnable(tap: tap, enable: false)
        capture.tap = tap
        defer {
            capture.tap = nil
            CFMachPortInvalidate(tap)
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return result(.observerUnavailable) }
        let runLoop = CFRunLoopGetCurrent()
        let mode = CFRunLoopMode("Keyshift self-test" as CFString)
        CFRunLoopAddSource(runLoop, source, mode)
        defer {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, mode)
            CFRunLoopSourceInvalidate(source)
        }

        guard let probeSource = CGEventSource(stateID: .privateState),
              let down = EventCodec.makeEvent(.keyDown(input.key, input.modifiers, isRepeat: false), source: probeSource),
              let up = EventCodec.makeEvent(.keyUp(input.key, input.modifiers), source: probeSource)
        else { return result(.eventCreationFailed) }
        // An in-place rewrite by the backend keeps this field.
        down.setIntegerValueField(.eventSourceUserData, value: capture.marker)
        up.setIntegerValueField(.eventSourceUserData, value: capture.marker)

        CGEvent.tapEnable(tap: tap, enable: true)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        CFRunLoopRunInMode(mode, timeout, false)

        if capture.matched { return result(.passed) }
        return result(capture.observed.isEmpty ? .timedOut : .mismatch)
    }

    private final class Capture {
        let marker = Int64.random(in: 1..<EventCodec.syntheticTag)
        var tap: CFMachPort?
        private let inputKey: KeyCode
        private let expected: KeyCombo
        private let processID = Int64(getpid())
        private var sawExpectedDown = false
        private var differs = false
        private(set) var observed: [InputEvent] = []
        private(set) var matched = false

        init(input: KeyCombo, expected: KeyCombo) {
            inputKey = input.key
            self.expected = KeyCombo(expected.key, EventCodec.modifiers(from: EventCodec.flags(
                for: expected.modifiers, key: expected.key
            )))
        }

        func observe(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            record(event, type: type)
            return event.getIntegerValueField(.eventSourceUserData) == marker ? nil : Unmanaged.passUnretained(event)
        }

        private func record(_ event: CGEvent, type: CGEventType) {
            guard type == .keyDown || type == .keyUp,
                  event.getIntegerValueField(.eventSourceUnixProcessID) == processID,
                  let decoded = EventCodec.decode(event, type: type),
                  decoded.key == inputKey || decoded.key == expected.key else { return }
            observed.append(decoded)

            let combo = KeyCombo(decoded.key, decoded.modifiers)
            if combo != expected { differs = true }
            if decoded.kind == .keyDown && combo == expected { sawExpectedDown = true }
            if decoded.kind == .keyUp && !differs && sawExpectedDown {
                matched = true
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
        }
    }
}
