import AppKit
import ApplicationServices
import KeyshiftCore

public final class ContextProvider {
    struct TestOverride {
        let bundleID: String
        var appPath: String? = nil
        var isTextInput = false
    }

    private struct FocusSample {
        let isTextInput: Bool
        let time: UInt64
    }

    private static let cacheDuration: UInt64 = 150_000_000
    private static let messagingTimeout: Float = 0.05
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXSearchFieldSubrole, kAXComboBoxRole, kAXSecureTextFieldSubrole,
    ]

    private let workspace = NSWorkspace.shared
    private let lock = NSLock()
    private let axQueue = DispatchQueue(label: "Keyshift accessibility focus", qos: .userInitiated)
    private var activationObserver: NSObjectProtocol?
    private var bundleID: String?
    private var appPath: String?
    private var activation: UInt64 = 0
    private var sample: FocusSample?
    private var pending: DispatchGroup?

    public init() {
        // Subscribe before reading the initial frontmost app so an activation cannot be missed.
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.lock.withLock {
                self.bundleID = app?.bundleIdentifier
                self.appPath = app?.bundleURL?.path
                self.activation &+= 1
                self.sample = nil
                self.pending = nil
            }
        }
        let initialApp = workspace.frontmostApplication
        lock.withLock {
            if activation == 0 {
                bundleID = initialApp?.bundleIdentifier
                appPath = initialApp?.bundleURL?.path
            }
        }
    }

    deinit {
        if let activationObserver { workspace.notificationCenter.removeObserver(activationObserver) }
    }

    public var frontmostBundleID: String? { lock.withLock { bundleID } }

    public func makeContext() -> EngineContext { makeContext(override: nil) }

    func makeContext(override: TestOverride?) -> EngineContext {
        if let override {
            return EngineContext(frontmostBundleID: override.bundleID, frontmostAppPath: override.appPath,
                                 isTextInput: { override.isTextInput })
        }
        let (bundleID, appPath) = lock.withLock { (self.bundleID, self.appPath) }
        return EngineContext(frontmostBundleID: bundleID, frontmostAppPath: appPath, isTextInput: { [weak self] in
            self?.isTextInput() ?? false
        })
    }

    /// Use the same AX query without the activation cache while the CLI is on the main run loop.
    func isTextInputForProbe() -> Bool? { Self.queryTextFocus() }

    public func isTextInput() -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(50)
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if let sample, now < sample.time + Self.cacheDuration {
            lock.unlock()
            return sample.isTextInput
        }
        let activation = activation
        let query = pending ?? refreshFocus(for: activation)
        lock.unlock()

        // Several AX messages can be necessary. Bound their total cost to the tap and
        // let the worker finish updating the cache if the frontmost app is slow.
        _ = query.wait(timeout: deadline)
        return lock.withLock { self.activation == activation && (sample?.isTextInput ?? false) }
    }

    /// Called with lock held.
    private func refreshFocus(for activation: UInt64) -> DispatchGroup {
        let query = DispatchGroup()
        query.enter()
        pending = query
        axQueue.async { [self] in
            defer { query.leave() }
            guard lock.withLock({ self.activation == activation }) else { return }
            let result = Self.queryTextFocus()
            lock.withLock {
                guard self.activation == activation else { return }
                sample = FocusSample(isTextInput: result ?? false, time: DispatchTime.now().uptimeNanoseconds)
                pending = nil
            }
        }
        return query
    }

    private static func queryTextFocus() -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        guard let value = attribute(kAXFocusedUIElementAttribute, of: system),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let focused = value as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, "AXEditable"] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(focused, attributes, [], &values) == .success,
              let values = values as? [Any], values.count == 3, let role = values[0] as? String else { return nil }
        if textRoles.contains(role) { return true }
        if let subrole = values[1] as? String, textRoles.contains(subrole) { return true }
        if values[2] as? Bool == true { return true }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
