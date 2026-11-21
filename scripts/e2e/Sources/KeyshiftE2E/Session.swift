import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.hidsystem
import Vision

final class TestSession {
    typealias Object = [String: Any]

    private let directory: URL
    private let source = CGEventSource(stateID: .hidSystemState)!
    private var tap: CFMachPort?
    private var events: [Object] = []
    private var posted: [Object] = []
    private var held: Set<Int> = []
    private var handles: [Int: AXUIElement] = [:]
    private var nextHandle = 1
    private var clipboard: [[NSPasteboard.PasteboardType: Data]]?
    private var running = true

    private static let modifiers: [Int: UInt64] = [
        54: CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICERCMDKEYMASK),
        55: CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICELCMDKEYMASK),
        56: CGEventFlags.maskShift.rawValue | UInt64(NX_DEVICELSHIFTKEYMASK),
        58: CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK),
        59: CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICELCTLKEYMASK),
        63: CGEventFlags.maskSecondaryFn.rawValue,
    ]

    init(directory: URL) { self.directory = directory }

    func run() throws {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp]
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: types.reduce(0) { $0 | (1 << $1.rawValue) },
            callback: { _, type, event, info in
                let session = Unmanaged<TestSession>.fromOpaque(info!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    session.events.append(["type": "tap-disabled"])
                    if let tap = session.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    session.events.append(session.describe(event))
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let loopSource = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw Failure("Could not install the annotated-session observer")
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), loopSource, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        defer {
            releaseModifiers()
            restoreClipboard()
            CFMachPortInvalidate(tap)
        }

        try write(["pid": ProcessInfo.processInfo.processIdentifier], to: "ready.json")
        let request = directory.appendingPathComponent("request.json")
        while running && FileManager.default.fileExists(atPath: directory.path) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.012))
            guard let raw = try? Data(contentsOf: request) else { continue }
            try FileManager.default.removeItem(at: request)
            do {
                let input = try JSONSerialization.jsonObject(with: raw) as! Object
                try write(["value": try dispatch(input)], to: "response.json")
            } catch {
                try write(["error": String(describing: error)], to: "response.json")
            }
        }
    }

    private func write(_ value: Object, to file: String) throws {
        try JSONSerialization.data(withJSONObject: value).write(
            to: directory.appendingPathComponent(file), options: .atomic)
    }

    private struct Failure: LocalizedError, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
        var errorDescription: String? { description }
    }

    private func dispatch(_ input: Object) throws -> Any {
        switch input["op"] as? String {
        case "inject":
            let record = input["record"] as? Bool ?? true
            let start = posted.count
            defer { releaseModifiers(record: record) }
            let expectedPID = input["expectedPID"] as? Int32
            for step in input["steps"] as! [Object] {
                if let expectedPID, let key = step["key"] as? Int, step["down"] as? Bool == true,
                   Self.modifiers[key] == nil,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedPID {
                    throw Failure("Fixture lost focus before key \(key)")
                }
                if let delay = step["ms"] as? Double {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: delay / 1000))
                    continue
                }
                if let key = step["key"] as? Int {
                    postKey(key, down: step["down"] as! Bool, repeated: step["repeat"] as? Bool ?? false,
                            record: record, implicitFn: step["implicitFn"] as? Bool ?? true,
                            unicode: step["unicode"] as? String, numpad: step["numpad"] as? Bool,
                            kind: (step["kind"] as? NSNumber)?.int64Value)
                } else if let x = step["x"] as? Double, let y = step["y"] as? Double {
                    postClick(CGPoint(x: x, y: y), count: step["count"] as? Int ?? 1, record: record)
                } else if let value = step["text"] as? String {
                    postText(value)
                }
            }
            return posted.dropFirst(start).count
        case "scroll":
            let location = CGPoint(x: input["x"] as! Double, y: input["y"] as! Double)
            let delta = input["delta"] as! Int32
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: delta,
                                wheel2: 0, wheel3: 0)!
            let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: location,
                               mouseButton: .left)!
            move.flags = []
            post(move, record: false)
            event.location = location
            post(event, record: false)
            return true
        case "mark": return events.count
        case "postMark": return posted.count
        case "log":
            return ["events": Array(events.dropFirst(input["start"] as? Int ?? 0)),
                    "posted": input["includePosted"] as? Bool == true
                        ? Array(posted.dropFirst(input["postStart"] as? Int ?? 0)) : []]
        case "cursor":
            let point = CGEvent(source: nil)?.location ?? .zero
            return [point.x, point.y]
        case "flags":
            return ["hid": CGEventSource.flagsState(.hidSystemState).rawValue,
                    "combined": CGEventSource.flagsState(.combinedSessionState).rawValue]
        case "apps":
            return NSWorkspace.shared.runningApplications.map(app)
        case "front":
            return NSWorkspace.shared.frontmostApplication.map(app) ?? [:]
        case "inputSource":
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
            return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
        case "layoutKeys":
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            guard let source, let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { throw Failure("No active layout data") }
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            let layout = CFDataGetBytePtr(data)!.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
            return (input["keys"] as! [Int]).map { key in
                let values = [0, shiftKey, cmdKey, cmdKey | shiftKey].map { modifiers in
                    var deadKey: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 16)
                    UCKeyTranslate(layout, UInt16(key), UInt16(kUCKeyActionDisplay), UInt32(modifiers >> 8),
                                   UInt32(LMGetKbdType()), 1 << kUCKeyTranslateNoDeadKeysBit,
                                   &deadKey, chars.count, &length, &chars)
                    return String(utf16CodeUnits: chars, count: length)
                }
                return ["key": key, "plain": values[0], "shift": values[1],
                        "cmd": values[2], "cmdShift": values[3]] as Object
            }
        case "activate":
            guard let target = NSRunningApplication(processIdentifier: input["pid"] as! Int32) else {
                throw Failure("Application exited")
            }
            return target.activate(options: [])
        case "frames":
            let fullHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSScreen.screens.map { screen in
                let frame = screen.visibleFrame
                return ["x": frame.minX, "y": fullHeight - frame.maxY, "w": frame.width, "h": frame.height]
            }
        case "windows":
            let mask: CGWindowListOption = (input["all"] as? Bool ?? false)
                ? [.excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
            return CGWindowListCopyWindowInfo(mask, kCGNullWindowID) as? [Object] ?? []
        case "ax":
            let root = try element(input)
            let limit = input["limit"] as? Int ?? 220
            var remaining = limit
            return tree(root, depth: input["depth"] as? Int ?? 0, remaining: &remaining,
                        full: input["full"] as? Bool ?? false)
        case "traits":
            let target = try element(input)
            var range = CFRange(location: 0, length: input["length"] as? Int ?? 1)
            var raw: CFTypeRef?
            try checked(AXUIElementCopyParameterizedAttributeValue(target, "AXAttributedStringForRange" as CFString,
                        AXValueCreate(.cfRange, &range)!, &raw), "AXAttributedStringForRange")
            guard let text = raw as? NSAttributedString, text.length > 0 else { return [:] as Object }
            let attrs = text.attributes(at: 0, effectiveRange: nil)
            let font = (attrs[.font] ?? attrs[NSAttributedString.Key("AXFont")])
            let info = font as? [String: Any]
            let name = (font as? NSFont)?.fontName ?? info?["AXFontName"] as? String ?? String(describing: font)
            let lower = name.lowercased()
            return ["font": name, "attributes": attrs.description, "bold": lower.contains("bold"),
                    "italic": lower.contains("italic") || lower.contains("oblique"),
                    "underline": ((attrs[.underlineStyle] ?? attrs[NSAttributedString.Key("AXUnderline")]) as? NSNumber)?.intValue ?? 0 > 0]
        case "set":
            let target = try element(input)
            let attribute = input["attribute"] as! String
            let value: CFTypeRef
            if let pair = input["value"] as? [Double], pair.count == 2 {
                if attribute == "AXPosition" {
                    var raw = CGPoint(x: pair[0], y: pair[1])
                    value = AXValueCreate(.cgPoint, &raw)!
                } else if attribute == "AXSize" {
                    var raw = CGSize(width: pair[0], height: pair[1])
                    value = AXValueCreate(.cgSize, &raw)!
                } else {
                    var raw = CFRange(location: Int(pair[0]), length: Int(pair[1]))
                    value = AXValueCreate(.cfRange, &raw)!
                }
            } else if let text = input["value"] as? String {
                value = text as CFString
            } else if let number = input["value"] as? NSNumber {
                value = number
            } else {
                throw Failure("Unsupported value for \(attribute)")
            }
            try checked(AXUIElementSetAttributeValue(target, attribute as CFString, value), attribute)
            return true
        case "action":
            let name = input["name"] as? String ?? "AXPress"
            try checked(AXUIElementPerformAction(try element(input), name as CFString), name)
            return true
        case "pasteboard":
            let board = NSPasteboard.general
            if input["save"] as? Bool == true {
                clipboard = board.pasteboardItems?.map { item in
                    Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                        item.data(forType: type).map { (type, $0) }
                    })
                } ?? []
            }
            if let value = input["text"] as? String {
                board.clearContents()
                board.setString(value, forType: .string)
            }
            return board.string(forType: .string) ?? ""
        case "ocr":
            let url = URL(fileURLWithPath: input["path"] as! String)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(url: url).perform([request])
            return request.results?.compactMap { observation -> Object? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox
                return ["text": text, "x": box.midX, "y": 1 - box.midY]
            } ?? []
        case "capture":
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let path = input["path"] as! String
            if let number = input["window"] as? UInt32 {
                task.arguments = ["-x", "-t", "png", "-o", "-l", String(number), path]
            } else {
                task.arguments = ["-x", "-t", "png", "-m", path]
            }
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw Failure("screencapture exited \(task.terminationStatus)") }
            return true
        case "hotkeys":
            // Read-only view of the enabled symbolic hotkeys (the same SkyLight calls Keyshift uses).
            typealias IsEnabled = @convention(c) (Int32) -> Bool
            typealias GetValue = @convention(c) (
                Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt64>) -> Int32
            guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
                  let enabledSymbol = dlsym(library, "SLSIsSymbolicHotKeyEnabled"),
                  let valueSymbol = dlsym(library, "SLSGetSymbolicHotKeyValue") else {
                throw Failure("Symbolic hotkey API unavailable")
            }
            let isEnabled = unsafeBitCast(enabledSymbol, to: IsEnabled.self)
            let getValue = unsafeBitCast(valueSymbol, to: GetValue.self)
            var result: [Object] = []
            for id in 0...500 where isEnabled(Int32(id)) {
                var character: UInt16 = 0
                var key: UInt16 = 0
                var flags: UInt64 = 0
                if getValue(Int32(id), &character, &key, &flags) == 0, key != UInt16.max {
                    result.append(["id": id, "key": Int(key), "flags": flags])
                }
            }
            return result
        case "space":
            // Active Space and the Space list of the main display (SkyLight, read-only).
            typealias Connection = @convention(c) () -> Int32
            typealias ActiveSpace = @convention(c) (Int32) -> UInt64
            typealias ManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
            guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
                  let connectionSymbol = dlsym(library, "SLSMainConnectionID"),
                  let activeSymbol = dlsym(library, "SLSGetActiveSpace"),
                  let managedSymbol = dlsym(library, "SLSCopyManagedDisplaySpaces") else {
                throw Failure("Space API unavailable")
            }
            let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
            let active = unsafeBitCast(activeSymbol, to: ActiveSpace.self)(connection)
            guard let displays = unsafeBitCast(managedSymbol, to: ManagedSpaces.self)(connection)?
                .takeRetainedValue() as? [[String: Any]] else { throw Failure("No managed display spaces") }
            let main = displays.first { $0["Display Identifier"] as? String == "Main" } ?? displays.first
            let spaces = (main?["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.int64Value }
            return ["active": Int64(active), "spaces": spaces] as Object
        case "stop":
            running = false
            return true
        default: throw Failure("Unknown operation")
        }
    }

    private func app(_ item: NSRunningApplication) -> Object {
        ["pid": item.processIdentifier, "id": item.bundleIdentifier ?? "", "name": item.localizedName ?? "",
         "path": item.bundleURL?.path ?? "", "active": item.isActive]
    }

    private func flags(for key: Int? = nil, implicitFn: Bool = true) -> CGEventFlags {
        var raw = held.reduce(UInt64(0)) { $0 | Self.modifiers[$1, default: 0] }
        if implicitFn, let key, [64, 71, 79, 80, 90, 109, 111].contains(key)
            || (96...107).contains(key) || (113...126).contains(key) {
            raw |= CGEventFlags.maskSecondaryFn.rawValue
        }
        return CGEventFlags(rawValue: raw)
    }

    private func postKey(_ key: Int, down: Bool, repeated: Bool = false, record: Bool, implicitFn: Bool = true,
                         unicode: String? = nil, numpad: Bool? = nil, kind: Int64? = nil) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)!
        if Self.modifiers[key] != nil {
            if down { held.insert(key) } else { held.remove(key) }
            event.type = .flagsChanged
        }
        event.flags = flags(for: key, implicitFn: implicitFn)
        if numpad ?? (key == 76 || (65...92).contains(key) && key != 71 && ![66, 68, 70, 77, 74, 72, 73].contains(key)) { event.flags.insert(.maskNumericPad) }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        if let kind { event.setIntegerValueField(.keyboardEventKeyboardType, value: kind) }
        if let unicode {
            let units = Array(unicode.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        post(event, record: record)
    }

    private func releaseModifiers(record: Bool = false) {
        for key in held.sorted().reversed() { postKey(key, down: false, record: record) }
    }

    private func postClick(_ point: CGPoint, count: Int, record: Bool) {
        for click in 1...count {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                    mouseButton: .left)!
                event.flags = flags()
                event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                post(event, record: record)
            }
        }
    }

    private func postText(_ input: String) {
        for character in input {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)!
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(event, record: false)
            }
        }
    }

    private func post(_ event: CGEvent, record: Bool) {
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        if record { posted.append(describe(event)) }
        event.post(tap: .cghidEventTap)
    }

    private func describe(_ event: CGEvent) -> Object {
        let timestamp = event.timestamp
        let now = DispatchTime.now().uptimeNanoseconds
        var result: Object = ["type": event.type.rawValue, "key": event.getIntegerValueField(.keyboardEventKeycode),
                "flags": event.flags.rawValue, "repeat": event.getIntegerValueField(.keyboardEventAutorepeat),
                "tag": event.getIntegerValueField(.eventSourceUserData), "time": timestamp, "seen": now,
                "pid": event.getIntegerValueField(.eventTargetUnixProcessID)]
        if event.type == .keyDown || event.type == .keyUp {
            var chars = [UniChar](repeating: 0, count: 12)
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
            if length > 0 { result["unicode"] = String(utf16CodeUnits: chars, count: length) }
        }
        return result
    }

    private func checked(_ result: AXError, _ operation: String) throws {
        guard result == .success else { throw Failure("\(operation): AXError \(result.rawValue)") }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ input: Object) throws -> AXUIElement {
        let root: AXUIElement
        if let handle = input["handle"] as? Int, let saved = handles[handle] {
            root = saved
        } else if let pid = input["pid"] as? Int32 {
            root = AXUIElementCreateApplication(pid)
        } else {
            root = AXUIElementCreateSystemWide()
        }
        AXUIElementSetMessagingTimeout(root, 0.55)
        if let attributeName = input["target"] as? String,
           let target = attribute(root, attributeName), CFGetTypeID(target) == AXUIElementGetTypeID() {
            return unsafeDowncast(target, to: AXUIElement.self)
        }
        if let attributeName = input["target"] as? String { throw Failure("Unavailable \(attributeName)") }
        return root
    }

    private func handle(_ element: AXUIElement) -> Int {
        if let previous = handles.first(where: { CFEqual($0.value, element) }) { return previous.key }
        let id = nextHandle
        nextHandle += 1
        handles[id] = element
        return id
    }

    private func tree(_ element: AXUIElement, depth: Int, remaining: inout Int, full: Bool) -> Object {
        remaining -= 1
        let role = attribute(element, "AXRole") as? String ?? "unknown"
        var result: Object = ["handle": handle(element), "AXRole": role]
        var names = ["AXTitle", "AXDescription", "AXIdentifier", "AXValue", "AXURL", "AXSelected",
                     "AXFocused", "AXMinimized", "AXSelectedTextRange", "AXFilename", "AXEnabled",
                     "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey"]
        if full || depth == 0 {
            names += ["AXPosition", "AXSize", "AXDocument", "AXSubrole", "AXHelp", "AXSelectedText"]
        }
        for name in names {
            if let value = attribute(element, name), let encoded = encode(value) { result[name] = encoded }
        }
        if full || role == "AXApplication" || ["AXList", "AXOutline", "AXScrollArea", "AXBrowser"].contains(role) {
            for name in ["AXSelectedChildren", "AXSelectedRows", "AXTabs", "AXWindows"] {
                if let items = attribute(element, name) as? [AXUIElement], !items.isEmpty {
                    result[name] = items.prefix(30).map { item -> Object in
                        var entry: Object = ["handle": handle(item)]
                        for field in ["AXRole", "AXTitle", "AXDescription", "AXValue", "AXSelected", "AXURL"] {
                            if let value = attribute(item, field), let encoded = encode(value) {
                                entry[field] = encoded
                            }
                        }
                        return entry
                    }
                }
            }
        }
        if depth > 0, remaining > 0, let children = attribute(element, "AXChildren") as? [AXUIElement] {
            var output: [Object] = []
            for child in children where remaining > 0 {
                output.append(tree(child, depth: depth - 1, remaining: &remaining, full: full))
            }
            if !output.isEmpty { result["children"] = output }
        }
        return result
    }

    private func encode(_ value: CFTypeRef) -> Any? {
        if let size = value as? NSNumber { return size }
        if let string = value as? String { return String(string.prefix(16000)) }
        if let url = value as? URL { return url.absoluteString }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeDowncast(value, to: AXValue.self)
        switch AXValueGetType(ax) {
        case .cfRange:
            var result = CFRange()
            return AXValueGetValue(ax, .cfRange, &result) ? [result.location, result.length] : nil
        case .cgPoint:
            var result = CGPoint.zero
            return AXValueGetValue(ax, .cgPoint, &result) ? [result.x, result.y] : nil
        case .cgSize:
            var result = CGSize.zero
            return AXValueGetValue(ax, .cgSize, &result) ? [result.width, result.height] : nil
        default: return nil
        }
    }

    private func restoreClipboard() {
        guard let clipboard else { return }
        let board = NSPasteboard.general
        board.clearContents()
        if !clipboard.isEmpty {
            board.writeObjects(clipboard.map { fields in
                let item = NSPasteboardItem()
                for (type, data) in fields { item.setData(data, forType: type) }
                return item
            })
        }
    }
}
