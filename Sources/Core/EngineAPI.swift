import Foundation

/// A raw input event as seen by the backend (already decoded from CGEvent).
public struct InputEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case keyDown, keyUp
        /// A modifier key changed state; `key` is the modifier key, `isDown` its new state.
        case flagsChanged(isDown: Bool)
        case mouseDown(MouseButton), mouseUp(MouseButton)
    }

    public var kind: Kind
    /// Key code for key/flags events; ignored for mouse events.
    public var key: KeyCode
    /// Modifiers held at the time of the event (for keyDown: including any held modifier keys).
    public var modifiers: Modifiers
    public var isRepeat: Bool
    /// Monotonic seconds.
    public var timestamp: TimeInterval

    public init(kind: Kind, key: KeyCode = KeyCode(0), modifiers: Modifiers = [], isRepeat: Bool = false,
                timestamp: TimeInterval = 0) {
        self.kind = kind
        self.key = key
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.timestamp = timestamp
    }
}

/// Environment the engine matches rules against. `isTextInput` is lazy because it needs an AX
/// query; the engine calls it only when a candidate rule has a focus condition.
public struct EngineContext {
    public var frontmostBundleID: String?
    /// Bundle path of the frontmost app (e.g. "/Applications/Foo.app"), or the executable path for
    /// apps without a bundle. Matched by scope entries that contain "/" (case-insensitive substring).
    public var frontmostAppPath: String?
    public var isTextInput: () -> Bool

    public init(frontmostBundleID: String?, frontmostAppPath: String? = nil,
                isTextInput: @escaping () -> Bool = { false }) {
        self.frontmostBundleID = frontmostBundleID
        self.frontmostAppPath = frontmostAppPath
        self.isTextInput = isTextInput
    }
}

/// A synthetic event the backend should post.
public enum OutputEvent: Sendable, Hashable {
    case keyDown(KeyCode, Modifiers, isRepeat: Bool)
    case keyUp(KeyCode, Modifiers)
    case mouseDown(MouseButton, Modifiers)
    case mouseUp(MouseButton, Modifiers)
}

/// The engine's answer for one input event.
public struct Decision: Sendable, Hashable {
    public enum Disposition: Sendable, Hashable {
        /// Let the original event through untouched.
        case pass
        /// Let the original event through but rewrite it in place (cheapest, keeps event metadata).
        /// Only used when the output is exactly one event of the same kind as the input.
        case rewrite(OutputEvent)
        /// Drop the original event; post `emit` instead (may be empty).
        case replace
    }

    public var disposition: Disposition
    /// Extra events to post (for `.replace`), in order.
    public var emit: [OutputEvent]
    /// Non-key actions to perform (open app, shell…), after emitting.
    public var actions: [Action]
    /// For diagnostics / event viewer: which rule & mapping fired.
    public var matched: (rule: UUID, mapping: UUID)?

    public init(_ disposition: Disposition = .pass, emit: [OutputEvent] = [], actions: [Action] = [],
                matched: (rule: UUID, mapping: UUID)? = nil) {
        self.disposition = disposition
        self.emit = emit
        self.actions = actions
        self.matched = matched
    }

    public static let pass = Decision()

    public static func == (a: Decision, b: Decision) -> Bool {
        a.disposition == b.disposition && a.emit == b.emit && a.actions == b.actions
            && a.matched?.rule == b.matched?.rule && a.matched?.mapping == b.matched?.mapping
    }

    public func hash(into h: inout Hasher) {
        h.combine(disposition); h.combine(emit); h.combine(actions)
    }
}

/// Remapping engine contract. Implementations are single-threaded (called on the event tap thread)
/// and must be fast (no I/O; no AX calls except via `context.isTextInput`).
public protocol RemapEngine: AnyObject {
    /// Replace the active rule set (called on config reload / profile switch). Must reset
    /// in-flight state safely (keys currently held keep their remapped key-up).
    func load(config: Config)
    func handle(_ event: InputEvent, context: EngineContext) -> Decision
    /// Called when the backend is disabled/paused so held state can be released.
    func reset()
}
