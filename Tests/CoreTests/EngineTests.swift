import XCTest
@testable import KeyshiftCore

final class EngineTests: XCTestCase {
    // MARK: Helpers

    private func k(_ name: String) -> KeyCode { KeyCode.named(name)! }
    private func combo(_ s: String) -> KeyCombo { KeyCombo(parsing: s)! }
    private func map(_ trigger: String, _ action: Action, tap: Bool = false) -> Mapping {
        Mapping(trigger: Trigger(parsing: trigger)!, action: action, isTapAlone: tap)
    }
    private func keys(_ s: String...) -> Action { .keys(s.map { KeyCombo(parsing: $0)! }) }

    private func config(_ rules: [Rule], groups: [String: [String]] = [:], tapMs: Int = 500) -> Config {
        var c = Config(appGroups: groups, profiles: [Profile(name: "P", rules: rules)])
        c.settings.tapTimeoutMs = tapMs
        return c
    }

    private func engine(_ rules: Rule..., groups: [String: [String]] = [:], tapMs: Int = 500) -> Engine {
        Engine(config: config(rules, groups: groups, tapMs: tapMs))
    }

    private let ctx = EngineContext(frontmostBundleID: "com.example.app")

    private func down(_ e: Engine, _ s: String, repeat r: Bool = false, extra: Modifiers = [],
                      _ c: EngineContext? = nil) -> Decision {
        let cb = combo(s)
        return e.handle(InputEvent(kind: .keyDown, key: cb.key, modifiers: cb.modifiers.union(extra), isRepeat: r),
                        context: c ?? ctx)
    }

    private func up(_ e: Engine, _ s: String, mods: Modifiers? = nil, _ c: EngineContext? = nil) -> Decision {
        let cb = combo(s)
        return e.handle(InputEvent(kind: .keyUp, key: cb.key, modifiers: mods ?? cb.modifiers), context: c ?? ctx)
    }

    private func flags(_ e: Engine, _ key: String, _ isDown: Bool, mods: Modifiers, t: TimeInterval) -> Decision {
        e.handle(InputEvent(kind: .flagsChanged(isDown: isDown), key: k(key), modifiers: mods, timestamp: t),
                 context: ctx)
    }

    private func rewriteDown(_ s: String, repeat r: Bool = false) -> Decision.Disposition {
        let c = combo(s)
        return .rewrite(.keyDown(c.key, c.modifiers, isRepeat: r))
    }

    private func rewriteUp(_ s: String) -> Decision.Disposition {
        let c = combo(s)
        return .rewrite(.keyUp(c.key, c.modifiers))
    }

    // MARK: Basic & modifier tiers

    func testUnmappedPasses() {
        let e = engine(Rule(name: "r", mappings: [map("ctrl+c", keys("cmd+c"))]))
        XCTAssertEqual(down(e, "x"), .pass)
        XCTAssertEqual(up(e, "x"), .pass)
        XCTAssertEqual(down(e, "c"), .pass) // trigger needs ctrl
        XCTAssertEqual(down(e, "alt+ctrl+c"), .pass) // alt not in passthrough
    }

    func testSimpleRewriteAndMatched() {
        let m = map("ctrl+c", keys("cmd+c"))
        let r = Rule(name: "r", mappings: [m])
        let e = engine(r)
        let d = down(e, "ctrl+c")
        XCTAssertEqual(d.disposition, rewriteDown("cmd+c"))
        XCTAssertEqual(d.matched?.rule, r.id)
        XCTAssertEqual(d.matched?.mapping, m.id)
        XCTAssertEqual(up(e, "ctrl+c").disposition, rewriteUp("cmd+c"))
    }

    func testShiftPassthrough() {
        let e = engine(Rule(name: "nav", mappings: [map("home", keys("cmd+left"))]))
        XCTAssertEqual(down(e, "home").disposition, rewriteDown("cmd+left"))
        XCTAssertEqual(up(e, "home").disposition, rewriteUp("cmd+left"))
        XCTAssertEqual(down(e, "shift+home").disposition, rewriteDown("cmd+shift+left"))
        XCTAssertEqual(up(e, "shift+home").disposition, rewriteUp("cmd+shift+left"))
    }

    func testPassthroughDisabled() {
        let e = engine(Rule(name: "nav", passthrough: [], mappings: [map("home", keys("cmd+left"))]))
        XCTAssertEqual(down(e, "shift+home"), .pass)
    }

    func testExplicitShiftMappingWinsOverPassthroughAcrossRules() {
        let e = engine(
            Rule(name: "nav", mappings: [map("home", keys("cmd+left"))]),
            Rule(name: "explicit", mappings: [map("shift+home", keys("ctrl+a"))])
        )
        XCTAssertEqual(down(e, "shift+home").disposition, rewriteDown("ctrl+a"))
        XCTAssertEqual(up(e, "shift+home").disposition, rewriteUp("ctrl+a"))
        XCTAssertEqual(down(e, "home").disposition, rewriteDown("cmd+left"))
    }

    func testFirstMatchOrdering() {
        let a = map("ctrl+c", keys("cmd+c"))
        let b = map("ctrl+c", keys("cmd+x"))
        let r1 = Rule(name: "1", mappings: [a, b])
        let r2 = Rule(name: "2", mappings: [map("ctrl+c", keys("cmd+v"))])
        let e = engine(r1, r2)
        let d = down(e, "ctrl+c")
        XCTAssertEqual(d.disposition, rewriteDown("cmd+c"))
        XCTAssertEqual(d.matched?.mapping, a.id)

        // Passthrough tier: first passthrough candidate wins too.
        let e2 = engine(Rule(name: "1", mappings: [map("home", keys("cmd+left"))]),
                        Rule(name: "2", mappings: [map("home", keys("cmd+up"))]))
        XCTAssertEqual(down(e2, "shift+home").disposition, rewriteDown("cmd+shift+left"))
    }

    func testDisabledRulesSkipped() {
        let e = engine(Rule(name: "off", enabled: false, mappings: [map("ctrl+c", keys("cmd+x"))]),
                       Rule(name: "on", mappings: [map("ctrl+c", keys("cmd+c"))]))
        XCTAssertEqual(down(e, "ctrl+c").disposition, rewriteDown("cmd+c"))
    }

    func testSelectedProfile() {
        var c = Config(selectedProfile: "B", profiles: [
            Profile(name: "A", rules: [Rule(name: "a", mappings: [map("ctrl+c", keys("cmd+c"))])]),
            Profile(name: "B", rules: [Rule(name: "b", mappings: [map("ctrl+c", keys("cmd+x"))])]),
        ])
        let e = Engine(config: c)
        XCTAssertEqual(down(e, "ctrl+c").disposition, rewriteDown("cmd+x"))
        c.profiles = []
        e.load(config: c)
        XCTAssertEqual(down(e, "ctrl+v"), .pass)
    }

    // MARK: fn stripping

    func testImplicitFnStrippedForNavigationKeys() {
        let e = engine(Rule(name: "nav", mappings: [map("home", keys("cmd+left")), map("left", keys("alt+left"))]))
        XCTAssertEqual(down(e, "home", extra: .function).disposition, rewriteDown("cmd+left"))
        XCTAssertEqual(down(e, "left", extra: .function).disposition, rewriteDown("alt+left"))
        XCTAssertEqual(down(e, "shift+left", extra: .function).disposition, rewriteDown("alt+shift+left"))
    }

    func testFnTriggerStillMatchesFn() {
        let e = engine(Rule(name: "nav", mappings: [map("fn+left", keys("cmd+up")), map("left", keys("alt+left"))]))
        XCTAssertEqual(down(e, "left", extra: .function).disposition, rewriteDown("cmd+up"))
    }

    func testFnNotStrippedForLetters() {
        let e = engine(Rule(name: "r", mappings: [map("c", keys("x"))]))
        XCTAssertEqual(down(e, "fn+c"), .pass)
    }

    // MARK: App scope & focus

    func testAppScopeOnlyExceptWithGroups() {
        let groups = ["terminals": ["com.mitchellh.ghostty", "com.apple.Terminal"]]
        let e = engine(
            Rule(name: "win", scope: AppScope(.except, ["terminals"]), mappings: [map("ctrl+c", keys("cmd+c"))]),
            Rule(name: "finder", scope: AppScope(.only, ["com.apple.Finder"]), mappings: [map("f2", keys("return"))]),
            groups: groups
        )
        let term = EngineContext(frontmostBundleID: "com.apple.terminal")
        let ghostty = EngineContext(frontmostBundleID: "com.mitchellh.ghostty")
        let finder = EngineContext(frontmostBundleID: "com.apple.finder")
        let none = EngineContext(frontmostBundleID: nil)

        XCTAssertEqual(down(e, "ctrl+c", term), .pass)
        XCTAssertEqual(down(e, "ctrl+c", ghostty), .pass)
        XCTAssertEqual(down(e, "ctrl+c", finder).disposition, rewriteDown("cmd+c"))
        XCTAssertEqual(down(e, "ctrl+c", none).disposition, rewriteDown("cmd+c"))

        XCTAssertEqual(down(e, "f2", finder).disposition, rewriteDown("return"))
        XCTAssertEqual(down(e, "f2", term), .pass)
        XCTAssertEqual(down(e, "f2", none), .pass)
    }

    func testPathFragmentScopes() {
        let groups = ["games": ["/steamapps/common/", "/League of Legends.app/", "com.riotgames.leagueoflegends"]]
        let e = engine(
            Rule(name: "win", scope: AppScope(.except, ["games", "com.apple.Terminal"]),
                 mappings: [map("ctrl+c", keys("cmd+c"))]),
            Rule(name: "steam", scope: AppScope(.only, ["/SteamApps/Common/"]), mappings: [map("f2", keys("return"))]),
            groups: groups
        )
        func ctx(_ id: String?, _ path: String?) -> EngineContext {
            EngineContext(frontmostBundleID: id, frontmostAppPath: path)
        }
        let game = ctx("com.valve.game", "/Users/me/Library/Application Support/Steam/steamapps/common/Game/Game.app")
        let lol = ctx("com.riotgames.x", "/Applications/League of Legends.app/Contents/MacOS/LeagueClient")
        let riot = ctx("com.riotgames.leagueoflegends", nil)
        let terminal = ctx("com.apple.Terminal", "/System/Applications/Utilities/Terminal.app")
        let notes = ctx("com.apple.Notes", "/System/Applications/Notes.app")
        let noPath = ctx("com.apple.Notes", nil)

        XCTAssertEqual(down(e, "ctrl+c", game), .pass)           // path fragment, case-insensitive
        XCTAssertEqual(down(e, "ctrl+c", lol), .pass)
        XCTAssertEqual(down(e, "ctrl+c", riot), .pass)           // bundle id entry in the same group
        XCTAssertEqual(down(e, "ctrl+c", terminal), .pass)       // plain bundle id still exact
        XCTAssertEqual(down(e, "ctrl+c", notes).disposition, rewriteDown("cmd+c"))
        XCTAssertEqual(down(e, "ctrl+c", noPath).disposition, rewriteDown("cmd+c"))
        XCTAssertEqual(down(e, "f2", game).disposition, rewriteDown("return"))
        XCTAssertEqual(down(e, "f2", notes), .pass)
        XCTAssertEqual(down(e, "f2", noPath), .pass)

        // Path changes are picked up (memo invalidated), also back and forth.
        XCTAssertEqual(down(e, "f2", game).disposition, rewriteDown("return"))
        XCTAssertEqual(down(e, "f2", notes), .pass)
        XCTAssertEqual(down(e, "f2", game).disposition, rewriteDown("return"))

        // A bundle-id entry is never matched as a substring of the path.
        let tricky = ctx("com.example", "/Applications/com.apple.Terminal/App.app")
        XCTAssertEqual(down(e, "ctrl+c", tricky).disposition, rewriteDown("cmd+c"))

        // Reload resets the memo.
        e.load(config: config([Rule(name: "steam", scope: AppScope(.only, ["/foo/"]),
                                    mappings: [map("f2", keys("return"))])]))
        XCTAssertEqual(down(e, "f2", game), .pass)
        XCTAssertEqual(down(e, "f2", ctx(nil, "/x/FOO/y")).disposition, rewriteDown("return"))
    }

    func testAtPrefixedGroup() {
        let e = engine(Rule(name: "r", scope: AppScope(.only, ["@browsers"]), mappings: [map("ctrl+t", keys("cmd+t"))]),
                       groups: ["browsers": ["com.apple.Safari"]])
        XCTAssertEqual(down(e, "ctrl+t", EngineContext(frontmostBundleID: "com.apple.Safari")).disposition,
                       rewriteDown("cmd+t"))
    }

    func testFocusConditionAndLaziness() {
        var calls = 0
        var isText = false
        let c = EngineContext(frontmostBundleID: "com.apple.finder", isTextInput: { calls += 1; return isText })
        let e = engine(
            Rule(name: "plain", mappings: [map("ctrl+c", keys("cmd+c"))]),
            Rule(name: "finder", scope: AppScope(.only, ["com.apple.finder"]), focus: .notTextInput,
                 mappings: [map("return", keys("cmd+o")), map("f2", keys("return"))]),
            Rule(name: "text", focus: .textInput, mappings: [map("return", keys("shift+return"))])
        )
        // No focus-conditioned candidate → no AX call.
        _ = down(e, "ctrl+c", c)
        _ = down(e, "x", c)
        XCTAssertEqual(calls, 0)

        // Two focus-conditioned candidates → still at most one call.
        XCTAssertEqual(down(e, "return", c).disposition, rewriteDown("cmd+o"))
        XCTAssertEqual(calls, 1)
        isText = true
        XCTAssertEqual(down(e, "return", c).disposition, rewriteDown("shift+return"))
        XCTAssertEqual(calls, 2)

        // Scope fails first → no AX call.
        let other = EngineContext(frontmostBundleID: "com.other", isTextInput: { calls += 1; return false })
        XCTAssertEqual(down(e, "f2", other), .pass)
        XCTAssertEqual(calls, 2)

        // Modifiers don't fit → no AX call.
        XCTAssertEqual(down(e, "ctrl+return", c), .pass)
        XCTAssertEqual(calls, 2)
    }

    func testExactMatchDoesNotConsultFocusOfPassthroughCandidates() {
        var calls = 0
        let c = EngineContext(frontmostBundleID: nil, isTextInput: { calls += 1; return true })
        let e = engine(
            Rule(name: "focus", focus: .textInput, mappings: [map("home", keys("cmd+left"))]),
            Rule(name: "explicit", mappings: [map("shift+home", keys("ctrl+a"))])
        )
        XCTAssertEqual(down(e, "shift+home", c).disposition, rewriteDown("ctrl+a"))
        XCTAssertEqual(calls, 0)
    }

    // MARK: Key-up consistency

    func testKeyUpConsistentAcrossReload() {
        let e = engine(Rule(name: "r", mappings: [map("ctrl+c", keys("cmd+c"))]))
        XCTAssertEqual(down(e, "ctrl+c").disposition, rewriteDown("cmd+c"))
        e.load(config: config([Rule(name: "r2", mappings: [map("ctrl+c", keys("cmd+x"))])]))
        XCTAssertEqual(up(e, "ctrl+c").disposition, rewriteUp("cmd+c"))
        XCTAssertEqual(down(e, "ctrl+c").disposition, rewriteDown("cmd+x"))
        e.load(config: config([]))
        XCTAssertEqual(up(e, "ctrl+c").disposition, rewriteUp("cmd+x"))
    }

    func testPassedDownStaysPassedAfterReload() {
        let e = engine()
        XCTAssertEqual(down(e, "ctrl+c"), .pass)
        e.load(config: config([Rule(name: "r", mappings: [map("ctrl+c", keys("cmd+c"))])]))
        XCTAssertEqual(up(e, "ctrl+c"), .pass)
    }

    func testKeyUpAfterModifierReleasedFirstAndAppSwitch() {
        let e = engine(Rule(name: "r", scope: AppScope(.except, ["com.apple.terminal"]),
                            mappings: [map("ctrl+c", keys("cmd+c"))]))
        XCTAssertEqual(down(e, "ctrl+c").disposition, rewriteDown("cmd+c"))
        // ctrl released first (passes), app switched, then c released with no modifiers.
        XCTAssertEqual(flags(e, "left_ctrl", false, mods: [], t: 1), .pass)
        XCTAssertEqual(up(e, "c", mods: [], EngineContext(frontmostBundleID: "com.apple.Terminal")).disposition,
                       rewriteUp("cmd+c"))
        XCTAssertEqual(up(e, "c"), .pass) // already consumed
    }

    func testResetClearsHeld() {
        let e = engine(Rule(name: "r", mappings: [map("ctrl+c", keys("cmd+c"))]))
        _ = down(e, "ctrl+c")
        e.reset()
        XCTAssertEqual(up(e, "ctrl+c"), .pass)
    }

    // MARK: Autorepeat

    func testAutorepeatReusesStoredMapping() {
        let e = engine(Rule(name: "r", mappings: [map("home", keys("cmd+left"))]))
        XCTAssertEqual(down(e, "shift+home").disposition, rewriteDown("cmd+shift+left"))
        // Shift released during autorepeat: repeat keeps the original output.
        XCTAssertEqual(down(e, "home", repeat: true).disposition, rewriteDown("cmd+shift+left", repeat: true))
        e.load(config: config([]))
        XCTAssertEqual(down(e, "home", repeat: true).disposition, rewriteDown("cmd+shift+left", repeat: true))
        XCTAssertEqual(up(e, "home").disposition, rewriteUp("cmd+shift+left"))
    }

    func testAutorepeatOfPassedKeyPasses() {
        let e = engine()
        XCTAssertEqual(down(e, "ctrl+c"), .pass)
        e.load(config: config([Rule(name: "r", mappings: [map("ctrl+c", keys("cmd+c"))])]))
        XCTAssertEqual(down(e, "ctrl+c", repeat: true), .pass)
    }

    // MARK: Sequences, actions, none

    func testSequence() {
        let e = engine(Rule(name: "r", mappings: [map("f5", keys("cmd+r", "a"))]))
        let d = down(e, "f5")
        XCTAssertEqual(d.disposition, .replace)
        XCTAssertEqual(d.emit, [.keyDown(k("r"), .command, isRepeat: false), .keyUp(k("r"), .command),
                                .keyDown(k("a"), [], isRepeat: false), .keyUp(k("a"), [])])
        let rep = down(e, "f5", repeat: true)
        XCTAssertEqual(rep.disposition, .replace)
        XCTAssertTrue(rep.emit.isEmpty)
        let u = up(e, "f5")
        XCTAssertEqual(u.disposition, .replace)
        XCTAssertTrue(u.emit.isEmpty)
    }

    func testSequenceWithPassthrough() {
        let e = engine(Rule(name: "r", mappings: [map("f5", keys("a", "b"))]))
        let d = down(e, "shift+f5")
        XCTAssertEqual(d.emit, [.keyDown(k("a"), .shift, isRepeat: false), .keyUp(k("a"), .shift),
                                .keyDown(k("b"), .shift, isRepeat: false), .keyUp(k("b"), .shift)])
    }

    func testActionsFireOnceAndSwallow() {
        let m = map("ctrl+alt+t", .openApp("Ghostty"))
        let r = Rule(name: "r", mappings: [m, map("cmd+l", .system(.lockScreen))])
        let e = engine(r)
        let d = down(e, "ctrl+alt+t")
        XCTAssertEqual(d, Decision(.replace, actions: [.openApp("Ghostty")], matched: (r.id, m.id)))
        let rep = down(e, "ctrl+alt+t", repeat: true)
        XCTAssertEqual(rep.disposition, .replace)
        XCTAssertTrue(rep.actions.isEmpty)
        let u = up(e, "t", mods: [])
        XCTAssertEqual(u.disposition, .replace)
        XCTAssertTrue(u.actions.isEmpty && u.emit.isEmpty)

        XCTAssertEqual(down(e, "cmd+l").actions, [.system(.lockScreen)])
        XCTAssertEqual(up(e, "cmd+l").disposition, .replace)
    }

    func testNoneSwallows() {
        let e = engine(Rule(name: "r", mappings: [map("caps_lock", .none), map("insert", keys())]))
        let d = down(e, "caps_lock")
        XCTAssertEqual(d.disposition, .replace)
        XCTAssertTrue(d.emit.isEmpty && d.actions.isEmpty)
        XCTAssertNotNil(d.matched)
        XCTAssertEqual(down(e, "caps_lock", repeat: true).disposition, .replace)
        XCTAssertEqual(up(e, "caps_lock").disposition, .replace)
        XCTAssertEqual(down(e, "insert").disposition, .replace)
        XCTAssertEqual(up(e, "insert").disposition, .replace)
    }

    func testKeyToMouse() {
        let e = engine(Rule(name: "r", mappings: [map("f13", .mouse(.left, .command))]))
        XCTAssertEqual(down(e, "f13").emit, [.mouseDown(.left, .command)])
        XCTAssertEqual(down(e, "f13", repeat: true).disposition, .replace)
        let u = up(e, "f13")
        XCTAssertEqual(u.disposition, .replace)
        XCTAssertEqual(u.emit, [.mouseUp(.left, .command)])
    }

    // MARK: Mouse

    private func mouse(_ e: Engine, _ b: MouseButton, down isDown: Bool, _ mods: Modifiers,
                       _ c: EngineContext? = nil) -> Decision {
        e.handle(InputEvent(kind: isDown ? .mouseDown(b) : .mouseUp(b), modifiers: mods), context: c ?? ctx)
    }

    func testMouseCtrlClickToCmdClick() {
        let e = engine(Rule(name: "r", mappings: [map("ctrl+left_click", .mouse(.left, .command))]))
        XCTAssertEqual(mouse(e, .left, down: true, .control).disposition, .rewrite(.mouseDown(.left, .command)))
        // ctrl released before button, config reloaded.
        e.load(config: config([]))
        XCTAssertEqual(mouse(e, .left, down: false, []).disposition, .rewrite(.mouseUp(.left, .command)))
        XCTAssertEqual(mouse(e, .left, down: true, []), .pass)
        XCTAssertEqual(mouse(e, .left, down: false, []), .pass)
    }

    func testMouseShiftPassthroughAndOtherButton() {
        let e = engine(Rule(name: "r", mappings: [map("ctrl+left_click", .mouse(.left, .command)),
                                                   map("button4", .mouse(.right, []))]))
        XCTAssertEqual(mouse(e, .left, down: true, [.control, .shift]).disposition,
                       .rewrite(.mouseDown(.left, [.command, .shift])))
        XCTAssertEqual(mouse(e, .left, down: false, []).disposition, .rewrite(.mouseUp(.left, [.command, .shift])))
        XCTAssertEqual(mouse(e, .left, down: true, []), .pass)
        let d = mouse(e, .button4, down: true, [])
        XCTAssertEqual(d.disposition, .replace)
        XCTAssertEqual(d.emit, [.mouseDown(.right, [])])
        let u = mouse(e, .button4, down: false, [])
        XCTAssertEqual(u.disposition, .replace)
        XCTAssertEqual(u.emit, [.mouseUp(.right, [])])
    }

    func testMouseToKeys() {
        let e = engine(Rule(name: "r", mappings: [map("button4", keys("cmd+left_bracket")),
                                                   map("button5", .openURL("https://x"))]))
        XCTAssertEqual(mouse(e, .button4, down: true, []).emit, [.keyDown(k("["), .command, isRepeat: false)])
        XCTAssertEqual(mouse(e, .button4, down: false, []).emit, [.keyUp(k("["), .command)])
        XCTAssertEqual(mouse(e, .button5, down: true, []).actions, [.openURL("https://x")])
        XCTAssertEqual(mouse(e, .button5, down: false, []).disposition, .replace)
    }

    // MARK: Tap-alone

    private func tapEngine(_ action: Action = .system(.launchpad), ms: Int = 500) -> (Engine, Rule) {
        let r = Rule(name: "t", mappings: [map("left_cmd", action, tap: true), map("ctrl+c", keys("cmd+c"))])
        return (engine(r, tapMs: ms), r)
    }

    func testTapAloneFires() {
        let (e, r) = tapEngine()
        XCTAssertEqual(flags(e, "left_cmd", true, mods: .command, t: 10), .pass)
        let d = flags(e, "left_cmd", false, mods: [], t: 10.2)
        XCTAssertEqual(d.disposition, .pass)
        XCTAssertEqual(d.actions, [.system(.launchpad)])
        XCTAssertEqual(d.matched?.rule, r.id)
        // Fires once.
        XCTAssertEqual(flags(e, "left_cmd", false, mods: [], t: 10.3), .pass)
    }

    func testTapAloneKeysEmitsPairs() {
        let (e, _) = tapEngine(keys("cmd+space"))
        _ = flags(e, "left_cmd", true, mods: .command, t: 0)
        let d = flags(e, "left_cmd", false, mods: [], t: 0.1)
        XCTAssertEqual(d.disposition, .pass)
        XCTAssertEqual(d.emit, [.keyDown(k("space"), .command, isRepeat: false), .keyUp(k("space"), .command)])
    }

    func testTapAloneCancelledByKey() {
        let (e, _) = tapEngine()
        _ = flags(e, "left_cmd", true, mods: .command, t: 0)
        XCTAssertEqual(down(e, "cmd+c"), .pass)
        XCTAssertEqual(up(e, "cmd+c"), .pass)
        XCTAssertEqual(flags(e, "left_cmd", false, mods: [], t: 0.1), .pass)
    }

    func testTapAloneCancelledByMouseAndOtherModifier() {
        let (e, _) = tapEngine()
        _ = flags(e, "left_cmd", true, mods: .command, t: 0)
        _ = mouse(e, .left, down: true, .command)
        XCTAssertEqual(flags(e, "left_cmd", false, mods: [], t: 0.1), .pass)

        _ = flags(e, "left_cmd", true, mods: .command, t: 1)
        XCTAssertEqual(flags(e, "left_shift", true, mods: [.command, .shift], t: 1.05), .pass)
        _ = flags(e, "left_shift", false, mods: .command, t: 1.1)
        XCTAssertEqual(flags(e, "left_cmd", false, mods: [], t: 1.15), .pass)

        // Pressed while another modifier already held → not a tap.
        _ = flags(e, "left_shift", true, mods: .shift, t: 2)
        _ = flags(e, "left_cmd", true, mods: [.shift, .command], t: 2.05)
        XCTAssertEqual(flags(e, "left_cmd", false, mods: .shift, t: 2.1), .pass)
    }

    func testTapAloneTimeout() {
        let (e, _) = tapEngine(ms: 300)
        _ = flags(e, "left_cmd", true, mods: .command, t: 5)
        XCTAssertEqual(flags(e, "left_cmd", false, mods: [], t: 5.31), .pass)
        _ = flags(e, "left_cmd", true, mods: .command, t: 6)
        XCTAssertEqual(flags(e, "left_cmd", false, mods: [], t: 6.29).actions, [.system(.launchpad)])
    }

    func testTapAloneOtherSideDoesNotFire() {
        let (e, _) = tapEngine()
        _ = flags(e, "right_cmd", true, mods: .command, t: 0)
        XCTAssertEqual(flags(e, "right_cmd", false, mods: [], t: 0.1), .pass)
    }

    func testTapAloneRespectsScope() {
        let r = Rule(name: "t", scope: AppScope(.only, ["com.apple.finder"]),
                     mappings: [map("left_cmd", .system(.launchpad), tap: true)])
        let e = engine(r)
        _ = flags(e, "left_cmd", true, mods: .command, t: 0)
        XCTAssertEqual(flags(e, "left_cmd", false, mods: [], t: 0.1), .pass)
    }

    func testModifierFlagsPassWithoutTapMappings() {
        let e = engine(Rule(name: "r", mappings: [map("left_cmd", keys("left_ctrl"))]))
        XCTAssertEqual(flags(e, "left_cmd", true, mods: .command, t: 0), .pass)
        XCTAssertEqual(flags(e, "left_cmd", false, mods: [], t: 0.1), .pass)
    }

    func testImplicitFnKeySet() {
        for n in ["left", "right", "up", "down", "home", "end", "page_up", "page_down", "delete", "f1", "f12", "f19"] {
            XCTAssertTrue(Engine.setsImplicitFn(k(n)), n)
        }
        for n in ["a", "return", "backspace", "space", "left_cmd", "escape"] {
            XCTAssertFalse(Engine.setsImplicitFn(k(n)), n)
        }
    }
}
