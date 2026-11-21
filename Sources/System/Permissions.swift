import AppKit
import ApplicationServices
import IOKit.hidsystem

public enum Permissions {
    public enum Kind: CaseIterable, Sendable {
        case accessibility
        case inputMonitoring
    }

    /// A cancellable observation. Keep it alive for as long as permission changes are needed.
    public final class Observation {
        fileprivate let timer: DispatchSourceTimer

        fileprivate init(_ timer: DispatchSourceTimer) { self.timer = timer }

        public func cancel() { timer.cancel() }

        deinit { cancel() }
    }

    @discardableResult
    public static func accessibility(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    @discardableResult
    public static func inputMonitoring(prompt: Bool = false) -> Bool {
        if prompt { return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @MainActor
    public static func openSettings(for kind: Kind) {
        let anchor: String
        switch kind {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reports each requested permission once on the main queue, including any already granted.
    public static func observeGrants(
        for kinds: Set<Kind> = Set(Kind.allCases), interval: TimeInterval = 0.5,
        onGrant: @escaping (Kind) -> Void
    ) -> Observation {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let observation = Observation(timer)
        var remaining = kinds
        let seconds = interval.isFinite ? max(0.1, interval) : 0.5
        timer.schedule(deadline: .now(), repeating: seconds, leeway: .milliseconds(50))
        timer.setEventHandler { [weak observation] in
            guard let observation, !observation.timer.isCancelled else { return }
            for kind in Kind.allCases where remaining.contains(kind) {
                let granted: Bool
                switch kind {
                case .accessibility: granted = accessibility()
                case .inputMonitoring: granted = inputMonitoring()
                }
                if granted {
                    remaining.remove(kind)
                    onGrant(kind)
                    if observation.timer.isCancelled { return }
                }
            }
            if remaining.isEmpty { observation.cancel() }
        }
        timer.resume()
        return observation
    }
}
