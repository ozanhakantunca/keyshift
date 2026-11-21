import AppKit
import ApplicationServices
import CoreGraphics
import KeyshiftCore

/// Pure frame math for window tiling. Every rect here is in Accessibility coordinates: a
/// top-left origin on the primary display, y growing downward.
enum WindowTiling {
    struct Screen: Equatable {
        /// Full display frame in Accessibility coordinates.
        var frame: CGRect
        /// Display frame minus menu bar and Dock, in Accessibility coordinates.
        var visibleFrame: CGRect
    }

    /// Converts a Cocoa rect (bottom-left origin on the primary display) to Accessibility
    /// coordinates. `primaryHeight` is the height of the primary display (`NSScreen.screens[0]`).
    static func accessibilityRect(fromCocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The screen showing most of `window`; when the window is on none of them, the one whose
    /// center is nearest to the window's center.
    static func screen(for window: CGRect, in screens: [Screen]) -> Screen? {
        var best: (screen: Screen, area: CGFloat)?
        for screen in screens {
            let overlap = screen.frame.intersection(window)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (screen, area) }
        }
        if let best { return best.screen }
        let center = CGPoint(x: window.midX, y: window.midY)
        return screens.min { distance(from: center, to: $0.frame) < distance(from: center, to: $1.frame) }
    }

    /// Target frame for `action` inside `visible`. `current` is the window's present frame (only
    /// `center` uses it, to keep the size). Returns nil for non-window actions.
    static func targetFrame(for action: SystemAction, visible: CGRect, current: CGRect) -> CGRect? {
        let halfWidth = (visible.width / 2).rounded(.down)
        let halfHeight = (visible.height / 2).rounded(.down)
        switch action {
        case .tileLeft:
            return CGRect(x: visible.minX, y: visible.minY, width: halfWidth, height: visible.height)
        case .tileRight:
            return CGRect(x: visible.minX + halfWidth, y: visible.minY, width: visible.width - halfWidth, height: visible.height)
        case .tileTop:
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: halfHeight)
        case .tileBottom:
            return CGRect(x: visible.minX, y: visible.minY + halfHeight, width: visible.width, height: visible.height - halfHeight)
        case .maximize:
            return visible
        case .center:
            let width = min(current.width, visible.width)
            let height = min(current.height, visible.height)
            return CGRect(x: visible.minX + ((visible.width - width) / 2).rounded(.down),
                          y: visible.minY + ((visible.height - height) / 2).rounded(.down),
                          width: width, height: height)
        default:
            return nil
        }
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Moves and resizes the focused window of the frontmost app through Accessibility.
enum WindowTiler {
    private static let messagingTimeout: Float = 0.5

    @MainActor
    @discardableResult
    static func perform(_ action: SystemAction) -> Bool {
        guard WindowTiling.targetFrame(for: action, visible: .zero, current: .zero) != nil,
              let app = NSWorkspace.shared.frontmostApplication,
              let window = focusedWindow(of: app.processIdentifier) else { return false }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)

        if bool(kAXFullscreenAttribute, of: window) == true { return false }
        guard isSettable(kAXPositionAttribute, of: window),
              let position = point(kAXPositionAttribute, of: window),
              let size = size(kAXSizeAttribute, of: window) else { return false }
        let resizable = isSettable(kAXSizeAttribute, of: window)
        if !resizable && action != .center { return false }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map {
            WindowTiling.Screen(
                frame: WindowTiling.accessibilityRect(fromCocoa: $0.frame, primaryHeight: primaryHeight),
                visibleFrame: WindowTiling.accessibilityRect(fromCocoa: $0.visibleFrame, primaryHeight: primaryHeight))
        }
        let current = CGRect(origin: position, size: size)
        guard let screen = WindowTiling.screen(for: current, in: screens),
              let target = WindowTiling.targetFrame(for: action, visible: screen.visibleFrame, current: current)
        else { return false }

        // Position first so the window is on the right screen, then size, then position again:
        // some apps clamp the size (or shift the origin) while resizing.
        set(kAXPositionAttribute, point: target.origin, on: window)
        if resizable { set(kAXSizeAttribute, size: target.size, on: window) }
        set(kAXPositionAttribute, point: target.origin, on: window)
        return true
    }

    private static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static let kAXFullscreenAttribute = "AXFullScreen"

    private static func bool(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func isSettable(_ name: String, of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func point(_ name: String, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        var result = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgPoint, &result) else { return nil }
        return result
    }

    private static func size(_ name: String, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        var result = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgSize, &result) else { return nil }
        return result
    }

    private static func set(_ name: String, point: CGPoint, on element: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }

    private static func set(_ name: String, size: CGSize, on element: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }
}
