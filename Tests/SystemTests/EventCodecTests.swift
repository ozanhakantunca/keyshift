import CoreGraphics
import IOKit.hidsystem
import KeyshiftCore
@testable import KeyshiftSystem
import XCTest

final class EventCodecTests: XCTestCase {
    func testModifierFlagsRoundTripAndPreserveNonModifierBits() {
        let unrelated: CGEventFlags = [.maskAlphaShift, .maskNumericPad, .maskNonCoalesced]
        for raw: UInt8 in 0..<32 {
            let modifiers = Modifiers(rawValue: raw)
            let flags = EventCodec.flags(for: modifiers, preserving: unrelated)
            XCTAssertEqual(EventCodec.modifiers(from: flags), modifiers)
            XCTAssertTrue(flags.isSuperset(of: unrelated))
        }

        let rightCommand = CGEventFlags(rawValue: UInt64(NX_DEVICERCMDKEYMASK))
        let leftCommand = CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))
        let leftControl = CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK))
        let flags = EventCodec.flags(for: [.command, .control], preserving: [.maskCommand, rightCommand])
        XCTAssertEqual(flags, [.maskCommand, rightCommand, .maskControl, leftControl])
        XCTAssertFalse(flags.contains(leftCommand))
        XCTAssertEqual(EventCodec.flags(for: [], preserving: flags), [])
    }

    func testFlagsChangedDistinguishesSameModifierOnBothSides() throws {
        let sides: [(UInt16, UInt16, Int32, Int32, CGEventFlags, Modifiers)] = [
            (55, 54, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK, .maskCommand, .command),
            (59, 62, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK, .maskControl, .control),
            (58, 61, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK, .maskAlternate, .option),
            (56, 60, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK, .maskShift, .shift),
        ]
        for (leftKey, rightKey, leftRaw, rightRaw, flag, modifier) in sides {
            let left = CGEventFlags(rawValue: UInt64(leftRaw))
            let right = CGEventFlags(rawValue: UInt64(rightRaw))

            let both = try flagsChanged(rightKey, flags: [flag, left, right])
            XCTAssertEqual(both.kind, .flagsChanged(isDown: true))
            XCTAssertEqual(both.modifiers, modifier)

            let releasedLeft = try flagsChanged(leftKey, flags: [flag, right])
            XCTAssertEqual(releasedLeft.kind, .flagsChanged(isDown: false))
            XCTAssertEqual(releasedLeft.modifiers, modifier)
            XCTAssertEqual(try flagsChanged(rightKey, flags: [flag, left]).kind, .flagsChanged(isDown: false))

            XCTAssertEqual(try flagsChanged(rightKey, flags: flag).kind, .flagsChanged(isDown: true))
            let sideOnly = try flagsChanged(rightKey, flags: right)
            XCTAssertEqual(sideOnly.kind, .flagsChanged(isDown: true))
            XCTAssertEqual(sideOnly.modifiers, modifier)
            XCTAssertEqual(try flagsChanged(rightKey, flags: []).kind, .flagsChanged(isDown: false))
        }
    }

    func testCapsLockAndFunctionTransitions() throws {
        let capsLock = try flagsChanged(57, flags: .maskAlphaShift)
        XCTAssertEqual(capsLock.kind, .flagsChanged(isDown: true))
        XCTAssertEqual(capsLock.modifiers, [])
        XCTAssertEqual(try flagsChanged(57, flags: []).kind, .flagsChanged(isDown: false))

        let fn = try flagsChanged(63, flags: .maskSecondaryFn)
        XCTAssertEqual(fn.kind, .flagsChanged(isDown: true))
        XCTAssertEqual(fn.modifiers, .function)
        XCTAssertEqual(try flagsChanged(63, flags: []).kind, .flagsChanged(isDown: false))
    }

    func testKeyboardDecodeAndInPlaceRewriteKeepMetadata() throws {
        let event = try keyEvent(8)
        let rightControl = CGEventFlags(rawValue: UInt64(NX_DEVICERCTLKEYMASK))
        event.flags = [.maskControl, rightControl, .maskAlphaShift, .maskNonCoalesced]
        event.timestamp = 1_250_000_000
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: 42)

        let input = try XCTUnwrap(EventCodec.decode(event, type: event.type))
        XCTAssertEqual(input, InputEvent(kind: .keyDown, key: KeyCode(8), modifiers: .control,
                                         isRepeat: true, timestamp: 1.25))

        EventCodec.rewrite(event, as: .keyDown(KeyCode(9), [.control, .command, .function], isRepeat: true))
        let rewritten = try XCTUnwrap(EventCodec.decode(event, type: event.type))
        XCTAssertEqual(rewritten, InputEvent(kind: .keyDown, key: KeyCode(9), modifiers: [.control, .command, .function],
                                             isRepeat: true, timestamp: 1.25))
        let leftCommand = CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))
        XCTAssertTrue(event.flags.isSuperset(of: [rightControl, leftCommand, .maskAlphaShift, .maskNonCoalesced]))
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 42)

        EventCodec.rewrite(event, as: .keyUp(KeyCode(9), .command))
        XCTAssertEqual(EventCodec.decode(event, type: event.type),
                       InputEvent(kind: .keyUp, key: KeyCode(9), modifiers: .command, timestamp: 1.25))
        XCTAssertFalse(event.flags.contains(rightControl))
    }

    func testSyntheticMouseAndRightModifierEvents() throws {
        let source = try XCTUnwrap(EventCodec.makeTaggedSource())
        let cursor = CGPoint(x: 49, y: 85)
        let click = try XCTUnwrap(EventCodec.makeEvent(.mouseDown(.button5, .option), source: source, location: cursor))
        XCTAssertEqual(click.getIntegerValueField(.eventSourceUserData), EventCodec.syntheticTag)
        XCTAssertEqual(click.location, cursor)
        XCTAssertEqual(click.getIntegerValueField(.mouseEventClickState), 1)
        XCTAssertEqual(EventCodec.decode(click, type: click.type)?.kind, .mouseDown(.button5))
        XCTAssertEqual(EventCodec.decode(click, type: click.type)?.modifiers, .option)

        EventCodec.rewrite(click, as: .mouseUp(.button4, .control))
        XCTAssertEqual(click.location, cursor)
        XCTAssertEqual(EventCodec.decode(click, type: click.type)?.kind, .mouseUp(.button4))
        XCTAssertEqual(EventCodec.decode(click, type: click.type)?.modifiers, .control)

        let rightCommand = CGEventFlags(rawValue: UInt64(NX_DEVICERCMDKEYMASK))
        let leftCommand = CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))
        let down = try XCTUnwrap(EventCodec.makeEvent(.keyDown(KeyCode(54), [], isRepeat: false), source: source))
        XCTAssertTrue(down.flags.contains(rightCommand))
        XCTAssertFalse(down.flags.contains(leftCommand))
        XCTAssertEqual(EventCodec.decode(down, type: down.type)?.kind, .flagsChanged(isDown: true))

        let up = try XCTUnwrap(EventCodec.makeEvent(.keyUp(KeyCode(54), .command), source: source))
        XCTAssertTrue(up.flags.contains(leftCommand))
        XCTAssertFalse(up.flags.contains(rightCommand))
        XCTAssertEqual(EventCodec.decode(up, type: up.type)?.kind, .flagsChanged(isDown: false))
    }

    private func keyEvent(_ key: UInt16) throws -> CGEvent {
        try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
    }

    private func flagsChanged(_ key: UInt16, flags: CGEventFlags) throws -> InputEvent {
        let event = try keyEvent(key)
        event.type = .flagsChanged
        event.flags = flags
        return try XCTUnwrap(EventCodec.decode(event, type: event.type))
    }
}
