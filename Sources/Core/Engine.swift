import Foundation

/// The remapping engine: compiles the active profile into per-trigger lookup tables and turns raw
/// input events into `Decision`s. Pure logic, single-threaded (event tap thread), no locks.
///
/// Guarantees:
/// - Exact modifier matches beat passthrough matches across the whole profile; within a tier the
///   first mapping in rule/mapping order wins.
/// - Every remapped key/button press gets a consistent release (same output key/button and
///   modifiers as emitted on press), even across `load(config:)`, app switches, or modifiers being
///   released first. Autorepeats reuse the stored press result instead of re-matching.
/// - `flagsChanged` events always pass; tap-alone mappings add their action on release.
public final class Engine: RemapEngine {
    // MARK: - Compiled config

    private struct CompiledRule {
        let id: UUID
        let scopeKind: AppScope.Kind
        /// Lowercased bundle ids (groups resolved).
        let apps: Set<String>
        /// Lowercased path fragments (groups resolved), matched as substrings of the app path.
        let paths: [String]
        let focus: FocusCondition
        let passthrough: Modifiers
    }

    private struct Entry {
        /// Index into `rules`.
        let rule: Int
        let mappingID: UUID
        let modifiers: Modifiers
        let action: Action
    }

    private var rules: [CompiledRule] = []
    private var keyIndex: [KeyCode: [Entry]] = [:]
    private var mouseIndex: [MouseButton: [Entry]] = [:]
    private var tapIndex: [KeyCode: [Entry]] = [:]
    /// Tap-alone max press duration, seconds.
    public private(set) var tapTimeout: TimeInterval = 0.5

    // MARK: - Runtime state

    private enum HeldOutput {
        /// Release must become keyUp(key, mods).
        case key(KeyCode, Modifiers)
        /// Release must become mouseUp(button, mods).
        case mouse(MouseButton, Modifiers)
        /// Release (and autorepeats) are swallowed.
        case swallow
    }

    private struct Held {
        let output: HeldOutput
        let rule: UUID
        let mapping: UUID

        var release: OutputEvent? {
            switch output {
            case .key(let k, let m): return .keyUp(k, m)
            case .mouse(let b, let m): return .mouseUp(b, m)
            case .swallow: return nil
            }
        }

        var swallowed: Held { Held(output: .swallow, rule: rule, mapping: mapping) }
    }

    private struct PendingTap {
        let key: KeyCode
        let time: TimeInterval
        let action: Action
        let rule: UUID
        let mapping: UUID
    }

    private var heldKeys: [KeyCode: Held] = [:]
    private var heldButtons: [MouseButton: Held] = [:]
    private var pendingTap: PendingTap?

    /// Cache for the lowercased frontmost bundle id (avoids lowercasing on every event).
    private var lastFrontRaw: String?
    private var lastFrontLower: String?
    /// Same for the frontmost app path, plus a per-rule memo of "does this path match" valid for it.
    private var lastPathRaw: String?
    private var lastPathLower: String?
    private var pathMatchCache: [Bool?] = []

    public init() {}

    public convenience init(config: Config) {
        self.init()
        load(config: config)
    }

    // MARK: - RemapEngine

    public func load(config: Config) {
        var newRules: [CompiledRule] = []
        var keys: [KeyCode: [Entry]] = [:]
        var mice: [MouseButton: [Entry]] = [:]
        var taps: [KeyCode: [Entry]] = [:]

        for rule in config.activeProfile?.rules ?? [] where rule.enabled {
            let index = newRules.count
            let entries = config.resolveApps(rule.scope.apps)
            newRules.append(CompiledRule(
                id: rule.id,
                scopeKind: rule.scope.kind,
                apps: Set(entries.filter { !AppScope.isPathFragment($0) }),
                paths: entries.filter(AppScope.isPathFragment),
                focus: rule.focus,
                passthrough: rule.passthrough
            ))
            for m in rule.mappings {
                let entry = Entry(rule: index, mappingID: m.id, modifiers: m.trigger.modifiers, action: m.action)
                switch m.trigger {
                case .key(let combo):
                    if m.isTapAlone, let own = combo.key.modifier {
                        // Tap-alone only makes sense for a bare modifier key; anything else can never fire.
                        if combo.modifiers.subtracting(own).isEmpty { taps[combo.key, default: []].append(entry) }
                    } else {
                        keys[combo.key, default: []].append(entry)
                    }
                case .mouse(let button, _):
                    mice[button, default: []].append(entry)
                }
            }
        }

        rules = newRules
        lastPathRaw = nil
        lastPathLower = nil
        pathMatchCache = Array(repeating: nil, count: newRules.count)
        keyIndex = keys
        mouseIndex = mice
        tapIndex = taps
        tapTimeout = Double(max(0, config.settings.tapTimeoutMs)) / 1000
        // Held keys keep their recorded release; a half-done tap refers to the old config.
        pendingTap = nil
    }

    public func reset() {
        heldKeys.removeAll()
        heldButtons.removeAll()
        pendingTap = nil
    }

    public func resetReleasingHeld() -> [OutputEvent] {
        var releases: [OutputEvent] = []
        for held in heldKeys.values { held.release.map { releases.append($0) } }
        for held in heldButtons.values { held.release.map { releases.append($0) } }
        heldKeys = heldKeys.mapValues(\.swallowed)
        heldButtons = heldButtons.mapValues(\.swallowed)
        pendingTap = nil
        return releases
    }

    public var hasTapAloneMappings: Bool { !tapIndex.isEmpty }

    public func cancelPendingTap() { pendingTap = nil }

    public func handle(_ event: InputEvent, context: EngineContext) -> Decision {
        switch event.kind {
        case .keyDown:
            pendingTap = nil
            return keyDown(event, context)
        case .keyUp:
            guard let held = heldKeys.removeValue(forKey: event.key) else { return .pass }
            return release(held, keyUp: event.key, button: nil)
        case .mouseDown(let button):
            pendingTap = nil
            return mouseDown(button, event, context)
        case .mouseUp(let button):
            guard let held = heldButtons.removeValue(forKey: button) else { return .pass }
            return release(held, keyUp: nil, button: button)
        case .flagsChanged(let isDown):
            return flagsChanged(event, isDown: isDown, context)
        }
    }

    // MARK: - Key events

    private func keyDown(_ event: InputEvent, _ context: EngineContext) -> Decision {
        if event.isRepeat {
            // Never re-match an autorepeat: follow whatever the initial press became.
            guard let held = heldKeys[event.key] else { return .pass }
            let matched = (rule: held.rule, mapping: held.mapping)
            if case .key(let k, let m) = held.output {
                return Decision(.rewrite(.keyDown(k, m, isRepeat: true)), matched: matched)
            }
            return Decision(.replace, matched: matched)
        }

        // A fresh press supersedes any stale record (e.g. a lost keyUp).
        if !heldKeys.isEmpty { heldKeys.removeValue(forKey: event.key) }

        guard let entries = keyIndex[event.key] else { return .pass }
        var lazy = LazyContext(context)
        let implicitFn = event.key.hasImplicitFn
        guard let (entry, extras) = match(entries, event.modifiers, implicitFn: implicitFn, &lazy) else { return .pass }

        let rule = rules[entry.rule]
        let matched = (rule: rule.id, mapping: entry.mappingID)
        let decision: Decision
        let output: HeldOutput
        switch entry.action {
        case .keys(let combos) where combos.count == 1:
            let mods = combos[0].modifiers.union(extras)
            output = .key(combos[0].key, mods)
            decision = Decision(.rewrite(.keyDown(combos[0].key, mods, isRepeat: false)), matched: matched)
        case .keys(let combos):
            output = .swallow
            decision = Decision(.replace, emit: Self.pairs(combos, extras), matched: matched)
        case .mouse(let button, let m):
            let mods = m.union(extras)
            output = .mouse(button, mods)
            decision = Decision(.replace, emit: [.mouseDown(button, mods)], matched: matched)
        case .none:
            output = .swallow
            decision = Decision(.replace, matched: matched)
        case .openApp, .openURL, .shell, .system:
            output = .swallow
            decision = Decision(.replace, actions: [entry.action], matched: matched)
        }
        heldKeys[event.key] = Held(output: output, rule: rule.id, mapping: entry.mappingID)
        return decision
    }

    // MARK: - Mouse events

    private func mouseDown(_ button: MouseButton, _ event: InputEvent, _ context: EngineContext) -> Decision {
        if !heldButtons.isEmpty { heldButtons.removeValue(forKey: button) }

        guard let entries = mouseIndex[button] else { return .pass }
        var lazy = LazyContext(context)
        guard let (entry, extras) = match(entries, event.modifiers, implicitFn: false, &lazy) else { return .pass }

        let rule = rules[entry.rule]
        let matched = (rule: rule.id, mapping: entry.mappingID)
        let decision: Decision
        let output: HeldOutput
        switch entry.action {
        case .mouse(let target, let m):
            let mods = m.union(extras)
            output = .mouse(target, mods)
            // In-place rewrite only when the event kind is unchanged (same button type).
            decision = target == button
                ? Decision(.rewrite(.mouseDown(target, mods)), matched: matched)
                : Decision(.replace, emit: [.mouseDown(target, mods)], matched: matched)
        case .keys(let combos) where combos.count == 1:
            let mods = combos[0].modifiers.union(extras)
            output = .key(combos[0].key, mods)
            decision = Decision(.replace, emit: [.keyDown(combos[0].key, mods, isRepeat: false)], matched: matched)
        case .keys(let combos):
            output = .swallow
            decision = Decision(.replace, emit: Self.pairs(combos, extras), matched: matched)
        case .none:
            output = .swallow
            decision = Decision(.replace, matched: matched)
        case .openApp, .openURL, .shell, .system:
            output = .swallow
            decision = Decision(.replace, actions: [entry.action], matched: matched)
        }
        heldButtons[button] = Held(output: output, rule: rule.id, mapping: entry.mappingID)
        return decision
    }

    // MARK: - Releases

    /// `keyUp` is the physical key for key releases; `button` the physical button for mouse releases.
    private func release(_ held: Held, keyUp: KeyCode?, button: MouseButton?) -> Decision {
        let matched = (rule: held.rule, mapping: held.mapping)
        switch held.output {
        case .key(let k, let m):
            return keyUp != nil
                ? Decision(.rewrite(.keyUp(k, m)), matched: matched)
                : Decision(.replace, emit: [.keyUp(k, m)], matched: matched)
        case .mouse(let b, let m):
            return button == b
                ? Decision(.rewrite(.mouseUp(b, m)), matched: matched)
                : Decision(.replace, emit: [.mouseUp(b, m)], matched: matched)
        case .swallow:
            return Decision(.replace, matched: matched)
        }
    }

    // MARK: - Modifier keys / tap-alone

    private func flagsChanged(_ event: InputEvent, isDown: Bool, _ context: EngineContext) -> Decision {
        if isDown {
            // Any other modifier pressed meanwhile cancels a pending tap; a new candidate may start.
            pendingTap = nil
            guard let entries = tapIndex[event.key], let own = event.key.modifier,
                  event.modifiers.subtracting(own).isEmpty else { return .pass }
            var lazy = LazyContext(context)
            for e in entries where passes(e.rule, &lazy) {
                pendingTap = PendingTap(key: event.key, time: event.timestamp, action: e.action,
                                        rule: rules[e.rule].id, mapping: e.mappingID)
                break
            }
            return .pass
        }

        guard let tap = pendingTap else { return .pass }
        pendingTap = nil
        guard tap.key == event.key, event.timestamp - tap.time <= tapTimeout else { return .pass }

        let matched = (rule: tap.rule, mapping: tap.mapping)
        switch tap.action {
        case .keys(let combos):
            return Decision(.pass, emit: Self.pairs(combos, []), matched: matched)
        case .mouse(let b, let m):
            return Decision(.pass, emit: [.mouseDown(b, m), .mouseUp(b, m)], matched: matched)
        case .none:
            return Decision(.pass, matched: matched)
        case .openApp, .openURL, .shell, .system:
            return Decision(.pass, actions: [tap.action], matched: matched)
        }
    }

    // MARK: - Matching

    /// Per-event lazy view of the context: frontmost id lowercased once, `isTextInput` called at most once.
    private struct LazyContext {
        let context: EngineContext
        var front: String??
        var pathSynced = false
        var textInput: Bool?
        init(_ context: EngineContext) { self.context = context }
    }

    private func frontLower(_ lazy: inout LazyContext) -> String? {
        if let f = lazy.front { return f }
        let raw = lazy.context.frontmostBundleID
        let lower: String?
        if raw == lastFrontRaw {
            lower = lastFrontLower
        } else {
            lower = raw?.lowercased()
            lastFrontRaw = raw
            lastFrontLower = lower
        }
        lazy.front = .some(lower)
        return lower
    }

    /// Whether any of the rule's path fragments occurs in the frontmost app path. The lowercased path
    /// and each rule's answer are memoized until the path changes, so repeated events cost a lookup.
    private func pathMatches(_ index: Int, _ lazy: inout LazyContext) -> Bool {
        guard !rules[index].paths.isEmpty else { return false }
        if !lazy.pathSynced {
            let raw = lazy.context.frontmostAppPath
            if raw != lastPathRaw {
                lastPathRaw = raw
                lastPathLower = raw?.lowercased()
                pathMatchCache = Array(repeating: nil, count: rules.count)
            }
            lazy.pathSynced = true
        }
        guard let path = lastPathLower else { return false }
        if let cached = pathMatchCache[index] { return cached }
        let result = rules[index].paths.contains { path.contains($0) }
        pathMatchCache[index] = result
        return result
    }

    private func inScopeList(_ index: Int, _ lazy: inout LazyContext) -> Bool {
        if let f = frontLower(&lazy), rules[index].apps.contains(f) { return true }
        return pathMatches(index, &lazy)
    }

    private func passes(_ index: Int, _ lazy: inout LazyContext) -> Bool {
        let rule = rules[index]
        switch rule.scopeKind {
        case .everywhere:
            break
        case .only:
            guard inScopeList(index, &lazy) else { return false }
        case .except:
            if inScopeList(index, &lazy) { return false }
        }
        switch rule.focus {
        case .any:
            return true
        case .textInput, .notTextInput:
            let t: Bool
            if let cached = lazy.textInput {
                t = cached
            } else {
                t = lazy.context.isTextInput()
                lazy.textInput = t
            }
            return rule.focus == .textInput ? t : !t
        }
    }

    /// Two passes: exact matches first (whole profile), then passthrough matches. Conditions are
    /// checked only for entries whose modifiers fit, so `isTextInput` is consulted as late as possible.
    private func match(_ entries: [Entry], _ input: Modifiers, implicitFn: Bool,
                       _ lazy: inout LazyContext) -> (Entry, Modifiers)? {
        for e in entries where Self.effective(input, e, implicitFn) == e.modifiers {
            if passes(e.rule, &lazy) { return (e, []) }
        }
        for e in entries {
            let mods = Self.effective(input, e, implicitFn)
            guard mods != e.modifiers, mods.isSuperset(of: e.modifiers) else { continue }
            let extras = mods.subtracting(e.modifiers)
            guard rules[e.rule].passthrough.isSuperset(of: extras) else { continue }
            if passes(e.rule, &lazy) { return (e, extras) }
        }
        return nil
    }

    @inline(__always)
    private static func effective(_ input: Modifiers, _ e: Entry, _ implicitFn: Bool) -> Modifiers {
        implicitFn && !e.modifiers.contains(.function) ? input.subtracting(.function) : input
    }

    private static func pairs(_ combos: [KeyCombo], _ extras: Modifiers) -> [OutputEvent] {
        var out: [OutputEvent] = []
        out.reserveCapacity(combos.count * 2)
        for c in combos {
            let m = c.modifiers.union(extras)
            out.append(.keyDown(c.key, m, isRepeat: false))
            out.append(.keyUp(c.key, m))
        }
        return out
    }
}
