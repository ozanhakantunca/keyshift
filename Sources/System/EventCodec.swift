import CoreGraphics
import IOKit.hidsystem
import KeyshiftCore

enum EventCodec {
    static let syntheticTag: Int64 = 0x4B45595348494654 // KEYSHIFT

    static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        ]
        return types.reduce(0) { $0 | (1 << $1.rawValue) }
    }()

    private struct Sides {
        let modifier: Modifiers
        let flag: CGEventFlags
        let leftKey: KeyCode
        let rightKey: KeyCode
        let left: CGEventFlags
        let right: CGEventFlags

        init(_ modifier: Modifiers, _ flag: CGEventFlags, _ leftKey: UInt16, _ rightKey: UInt16,
             _ left: Int32, _ right: Int32) {
            self.modifier = modifier
            self.flag = flag
            self.leftKey = KeyCode(leftKey)
            self.rightKey = KeyCode(rightKey)
            self.left = CGEventFlags(rawValue: UInt64(left))
            self.right = CGEventFlags(rawValue: UInt64(right))
        }

        var mask: CGEventFlags { [left, right] }
        func bit(for key: KeyCode) -> CGEventFlags? {
            if key == leftKey { return left }
            if key == rightKey { return right }
            return nil
        }
    }

    private static let sides = [
        Sides(.control, .maskControl, 59, 62, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK),
        Sides(.option, .maskAlternate, 58, 61, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK),
        Sides(.shift, .maskShift, 56, 60, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK),
        Sides(.command, .maskCommand, 55, 54, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK),
    ]

    private static let capsLock = KeyCode(57)

    static func modifiers(from flags: CGEventFlags) -> Modifiers {
        var result: Modifiers = []
        for side in sides where flags.contains(side.flag) || !flags.intersection(side.mask).isEmpty {
            result.insert(side.modifier)
        }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
    }

    /// A held modifier keeps its original side. A newly added modifier defaults to the left.
    static func flags(for modifiers: Modifiers, preserving original: CGEventFlags = [],
                      key: KeyCode? = nil, modifierIsDown: Bool? = nil) -> CGEventFlags {
        var result = original.subtracting(.maskSecondaryFn)
        for side in sides {
            result.subtract([side.flag, side.left, side.right])
            var heldSides = original.intersection(side.mask)
            if let key, let bit = side.bit(for: key), let modifierIsDown {
                if modifierIsDown {
                    heldSides.insert(bit)
                } else {
                    heldSides.remove(bit)
                }
            }
            if modifiers.contains(side.modifier) {
                if heldSides.isEmpty {
                    // On release with the aggregate flag still set, the other side is held.
                    heldSides = modifierIsDown == false && key == side.leftKey ? side.right : side.left
                }
                result.formUnion([side.flag, heldSides])
            }
        }
        if modifiers.contains(.function) || key.map(hasIntrinsicFnFlag) == true {
            result.insert(.maskSecondaryFn)
        }
        return result
    }

    // Quartz marks function and navigation keys with SecondaryFn even on full-size keyboards.
    static func hasIntrinsicFnFlag(_ key: KeyCode) -> Bool {
        switch key.rawValue {
        case 64, 71, 79, 80, 90, 96...107, 109, 111, 113...126: return true
        default: return false
        }
    }

    static func decode(_ event: CGEvent, type: CGEventType) -> InputEvent? {
        var key = KeyCode(0)
        let kind: InputEvent.Kind
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            key = KeyCode(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)))
            switch type {
            case .keyDown: kind = .keyDown
            case .keyUp: kind = .keyUp
            default:
                guard let isDown = modifierIsDown(key, flags: event.flags) else { return nil }
                kind = .flagsChanged(isDown: isDown)
            }
        case .leftMouseDown: kind = .mouseDown(.left)
        case .leftMouseUp: kind = .mouseUp(.left)
        case .rightMouseDown: kind = .mouseDown(.right)
        case .rightMouseUp: kind = .mouseUp(.right)
        case .otherMouseDown, .otherMouseUp:
            let button: MouseButton
            switch event.getIntegerValueField(.mouseEventButtonNumber) {
            case 2: button = .middle
            case 3: button = .button4
            case 4: button = .button5
            default: return nil
            }
            kind = type == .otherMouseDown ? .mouseDown(button) : .mouseUp(button)
        default: return nil
        }
        return InputEvent(
            kind: kind, key: key, modifiers: modifiers(from: event.flags),
            isRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            timestamp: Double(event.timestamp) / 1_000_000_000
        )
    }

    private static func modifierIsDown(_ key: KeyCode, flags: CGEventFlags) -> Bool? {
        if key == capsLock { return flags.contains(.maskAlphaShift) }
        if key.modifier == .function { return flags.contains(.maskSecondaryFn) }
        for side in sides {
            guard let bit = side.bit(for: key) else { continue }
            // When either side is reported, the aggregate bit cannot distinguish a release.
            let held = flags.intersection(side.mask)
            return held.isEmpty ? flags.contains(side.flag) : held.contains(bit)
        }
        return nil
    }

    static func rewrite(_ event: CGEvent, as output: OutputEvent) {
        switch output {
        case .keyDown(let key, let modifiers, let isRepeat):
            writeKey(event, key: key, modifiers: modifiers, isDown: true, isRepeat: isRepeat)
        case .keyUp(let key, let modifiers):
            writeKey(event, key: key, modifiers: modifiers, isDown: false, isRepeat: false)
        case .mouseDown(let button, let modifiers):
            writeMouse(event, button: button, modifiers: modifiers, isDown: true)
        case .mouseUp(let button, let modifiers):
            writeMouse(event, button: button, modifiers: modifiers, isDown: false)
        }
    }

    static func makeEvent(_ output: OutputEvent, source: CGEventSource, location: CGPoint = .zero) -> CGEvent? {
        let event: CGEvent?
        switch output {
        case .keyDown(let key, _, _):
            event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: true)
        case .keyUp(let key, _):
            event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: false)
        case .mouseDown(let button, _):
            event = makeMouseEvent(button, isDown: true, source: source, location: location)
        case .mouseUp(let button, _):
            event = makeMouseEvent(button, isDown: false, source: source, location: location)
        }
        if let event { rewrite(event, as: output) }
        return event
    }

    private static func writeKey(_ event: CGEvent, key: KeyCode, modifiers: Modifiers,
                                 isDown: Bool, isRepeat: Bool) {
        var modifiers = modifiers
        if let modifier = key.modifier, isDown { modifiers.insert(modifier) }
        if key.modifier == .function && !isDown { modifiers.remove(.function) }

        event.type = key.isModifier ? .flagsChanged : (isDown ? .keyDown : .keyUp)
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(key.rawValue))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        event.flags = flags(for: modifiers, preserving: event.flags, key: key,
                            modifierIsDown: key.isModifier ? isDown : nil)
    }

    private static func writeMouse(_ event: CGEvent, button: MouseButton, modifiers: Modifiers, isDown: Bool) {
        let (type, number) = mouseInfo(button, isDown: isDown)
        event.type = type
        event.setIntegerValueField(.mouseEventButtonNumber, value: number)
        event.flags = flags(for: modifiers, preserving: event.flags)
    }

    private static func makeMouseEvent(_ button: MouseButton, isDown: Bool, source: CGEventSource,
                                       location: CGPoint) -> CGEvent? {
        let (type, number) = mouseInfo(button, isDown: isDown)
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: location,
                            mouseButton: CGMouseButton(rawValue: UInt32(number)) ?? .center)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }

    private static func mouseInfo(_ button: MouseButton, isDown: Bool) -> (CGEventType, Int64) {
        switch button {
        case .left: return (isDown ? .leftMouseDown : .leftMouseUp, 0)
        case .right: return (isDown ? .rightMouseDown : .rightMouseUp, 1)
        case .middle: return (isDown ? .otherMouseDown : .otherMouseUp, 2)
        case .button4: return (isDown ? .otherMouseDown : .otherMouseUp, 3)
        case .button5: return (isDown ? .otherMouseDown : .otherMouseUp, 4)
        }
    }

    static func makeTaggedSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = syntheticTag
        return source
    }
}
