import ApplicationServices
import Foundation
import KeyshiftCore

public enum SelfTestSuite {
    public enum Status: String {
        case pass = "PASS", fail = "FAIL", warning = "WARN", skip = "SKIP"
    }

    public struct Row {
        public let scenario: String
        public let status: Status
        public let detail: String

        init(_ scenario: String, _ status: Status, _ detail: String) {
            self.scenario = scenario
            self.status = status
            self.detail = detail
        }
    }

    @MainActor
    public static func run(backend: EventTapBackend, context: ContextProvider) -> [Row] {
        guard backend.isRunning, AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            return [Row("Setup", .fail, "The engine and permission to post events are required.")]
        }
        var rows = eventRows(backend: backend)
        rows.append(HIDSelfTest.run())
        rows += ContextSelfTest.run(context: context)
        return rows
    }

    private static func eventRows(backend: EventTapBackend) -> [Row] {
        let probe = SuiteEventProbe()
        guard let source = CGEventSource(stateID: .privateState), backend.beginProbe(probe) else {
            return [Row("Observer", .fail, "Could not install the active session tap.")]
        }
        defer { backend.endProbe() }

        var rows: [Row] = []
        for scenario in scenarios {
            guard backend.prepareProbe(context: scenario.context, config: scenario.config) else {
                return rows + [Row(scenario.name, .fail, "The observer or engine stopped."),
                               Row("Remaining probes", .skip, "Event delivery was interrupted.")]
            }
            let events = scenario.input.compactMap { output in
                let event = EventCodec.makeEvent(output, source: source,
                                                 location: CGPoint(x: -1_000_000, y: -1_000_000))
                event?.setIntegerValueField(.eventSourceUserData, value: probe.marker)
                return event
            }
            guard events.count == scenario.input.count else {
                rows.append(Row(scenario.name, .fail, "Could not create the input events."))
                continue
            }
            let seen = probe.capture(events)
            let received = describe(events: seen.events, actions: seen.actions)
            guard seen.completed else {
                return rows + [Row(scenario.name, .fail, "Event delivery timed out or a tap was disabled. Saw \(received)."),
                               Row("Remaining probes", .skip, "Event delivery was interrupted.")]
            }
            let expected = scenario.output.map(observation)
            let passed = seen.events == expected && seen.actions == scenario.actions
            rows.append(Row(scenario.name, passed ? .pass : .fail,
                            passed ? received : "Expected \(describe(events: expected, actions: scenario.actions)). Saw \(received)"))
            if scenario.name == "Observer" && !passed { break }
        }
        return rows
    }

    private struct Scenario {
        var name: String
        var context = ContextProvider.TestOverride(bundleID: "com.apple.TextEdit",
                                                   appPath: "/System/Applications/TextEdit.app", isTextInput: true)
        var input: [OutputEvent]
        var output: [OutputEvent]
        var actions: [Action] = []
        var config: Config? = nil
    }

    private static var scenarios: [Scenario] {
        let terminal = ContextProvider.TestOverride(bundleID: "com.apple.Terminal")
        let finder = ContextProvider.TestOverride(bundleID: "com.apple.finder")
        let finderTyping = ContextProvider.TestOverride(bundleID: "com.apple.finder", isTextInput: true)
        let chrome = ContextProvider.TestOverride(bundleID: "com.google.Chrome", isTextInput: true)
        let game = ContextProvider.TestOverride(bundleID: "example.foo",
                                               appPath: "/Users/x/Library/Application Support/Steam/steamapps/common/Foo/Foo.app")
        let cmdDown = keyDown("left_cmd")
        let cmdUp = keyUp("left_cmd")
        let ctrlUp = keyUp("left_ctrl")

        // These expectations come from the bundled Windows YAML. The running profile supplies the rules under test.
        var rows = [
            Scenario(name: "Observer", input: [keyUp("left_shift")], output: [keyUp("left_shift")]),
            Scenario(name: "TextEdit Ctrl+C", input: pair("ctrl+c"), output: pair("cmd+c")),
            Scenario(name: "Terminal Ctrl+C", context: terminal, input: pair("ctrl+c"), output: pair("ctrl+c")),
            Scenario(name: "Home", input: pair("home"), output: pair("cmd+left")),
            Scenario(name: "Shift+Home", input: pair("shift+home"), output: pair("cmd+shift+left")),
            Scenario(name: "Ctrl+Left", input: pair("ctrl+left"), output: pair("alt+left")),
            Scenario(name: "Ctrl+Backspace", input: pair("ctrl+backspace"), output: pair("alt+backspace")),
            Scenario(name: "Finder F2 (file list)", context: finder, input: pair("f2"), output: pair("return")),
            Scenario(name: "Finder F2 (typing)", context: finderTyping, input: pair("f2"), output: pair("f2")),
            Scenario(name: "TextEdit Alt+F4", input: pair("alt+f4"), output: pair("cmd+w")),
            Scenario(name: "Chrome Alt+F4", context: chrome, input: pair("alt+f4"), output: pair("cmd+shift+w")),
            Scenario(name: "Chrome Ctrl+L", context: chrome, input: pair("ctrl+l"), output: pair("cmd+l")),
            Scenario(name: "Cmd+E action", input: pair("cmd+e"), output: [], actions: [.openApp("Finder")]),
            Scenario(name: "Tap left Cmd", input: [cmdDown, cmdUp], output: [cmdDown, cmdUp],
                     actions: [.system(.spotlight)]),
            Scenario(name: "Left Cmd+C cancels tap", input: [cmdDown] + pair("cmd+c") + [cmdUp],
                     output: [cmdDown] + pair("cmd+c") + [cmdUp]),
            Scenario(name: "Ctrl+left click", input: [.mouseDown(.left, .control), .mouseUp(.left, .control)],
                     output: [.mouseDown(.left, .command), .mouseUp(.left, .command)]),
            Scenario(name: "Ctrl+C autorepeat", input: [keyDown("ctrl+c"), keyDown("ctrl+c", repeatKey: true), keyUp("ctrl+c")],
                     output: [keyDown("cmd+c"), keyDown("cmd+c", repeatKey: true), keyUp("cmd+c")]),
            Scenario(name: "Release Ctrl before C", input: [keyDown("left_ctrl"), keyDown("ctrl+c"), ctrlUp, keyUp("c")],
                     output: [keyDown("left_ctrl"), keyDown("cmd+c"), ctrlUp, keyUp("cmd+c")]),
            Scenario(name: "Steam path Ctrl+C", context: game, input: pair("ctrl+c"), output: pair("ctrl+c")),
        ]

        // Windows has no key sequence. Exercise proxy-posted output with a probe-only mapping.
        let sequence = [combo("shift+f18"), combo("f19")]
        let mapping = Mapping(trigger: .key(combo("f17")), action: .keys(sequence))
        let tap = Mapping(trigger: .key(combo("right_alt")), action: .keys([combo("f19")]), isTapAlone: true)
        let profile = Profile(name: "Probe", rules: [Rule(name: "Posted events", mappings: [mapping, tap])])
        rows.append(Scenario(name: "Posted key sequence", input: pair("f17"), output: pair("shift+f18") + pair("f19"),
                             config: Config(profiles: [profile])))
        rows.append(Scenario(name: "Tap emits key pair", input: pair("right_alt"),
                             output: [keyDown("right_alt")] + pair("f19") + [keyUp("right_alt")]))
        return rows
    }

    private static func combo(_ name: String) -> KeyCombo { KeyCombo(parsing: name)! }

    private static func keyDown(_ name: String, repeatKey: Bool = false) -> OutputEvent {
        let key = combo(name)
        return .keyDown(key.key, key.modifiers, isRepeat: repeatKey)
    }

    private static func keyUp(_ name: String) -> OutputEvent {
        let key = combo(name)
        return .keyUp(key.key, key.modifiers)
    }

    private static func pair(_ name: String) -> [OutputEvent] { [keyDown(name), keyUp(name)] }

    private static func observation(_ output: OutputEvent) -> InputEvent {
        switch output {
        case .keyDown(let key, let modifiers, let repeatKey):
            return keyObservation(key, modifiers, down: true, repeatKey: repeatKey)
        case .keyUp(let key, let modifiers):
            return keyObservation(key, modifiers, down: false)
        case .mouseDown(let button, let modifiers):
            return InputEvent(kind: .mouseDown(button), modifiers: modifiers)
        case .mouseUp(let button, let modifiers):
            return InputEvent(kind: .mouseUp(button), modifiers: modifiers)
        }
    }

    private static func keyObservation(_ key: KeyCode, _ modifiers: Modifiers, down: Bool,
                                       repeatKey: Bool = false) -> InputEvent {
        var mods = modifiers
        if key.hasImplicitFn { mods.insert(.function) }
        if down, let modifier = key.modifier { mods.insert(modifier) }
        let kind: InputEvent.Kind = key.isModifier ? .flagsChanged(isDown: down) : down ? .keyDown : .keyUp
        return InputEvent(kind: kind, key: key, modifiers: mods, isRepeat: repeatKey)
    }

    private static func describe(events: [InputEvent], actions: [Action]) -> String {
        let inputs = events.map { event in
            var modifiers = event.modifiers
            if event.key.hasImplicitFn { modifiers.remove(.function) }
            if let modifier = event.key.modifier { modifiers.remove(modifier) }
            let key = KeyCombo(event.key, modifiers).displayString
            switch event.kind {
            case .keyDown: return "\(key) \(event.isRepeat ? "repeat" : "↓")"
            case .keyUp: return "\(key) ↑"
            case .flagsChanged(let down): return "\(key) \(down ? "↓" : "↑")"
            case .mouseDown(let button): return "\(modifiers.symbols)\(button.rawValue) ↓"
            case .mouseUp(let button): return "\(modifiers.symbols)\(button.rawValue) ↑"
            }
        }
        let recorded = actions.map { action in
            switch action {
            case .openApp(let app): return "dry-run open \(app)"
            case .system(let action): return "dry-run \(action.rawValue)"
            default: return "dry-run \(action)"
            }
        }
        let detail = (inputs + recorded).joined(separator: ", ")
        return detail.isEmpty ? "no events or actions" : detail
    }
}
