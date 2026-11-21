import KeyshiftConfig
import KeyshiftCore
import XCTest

final class ConfigCodecTests: XCTestCase {
    func testEverySystemActionNameDecodesAndRoundTrips() throws {
        let names = ["tile_left", "tile_right", "tile_top", "tile_bottom", "maximize", "center"]
        XCTAssertTrue(names.allSatisfy { SystemAction(rawValue: $0) != nil })
        let map = SystemAction.allCases.map(\.rawValue).enumerated()
            .map { "          f\($0.offset + 1): { system: \($0.element) }" }.joined(separator: "\n")
        let yaml = "version: 1\nprofile: p\nprofiles:\n  - name: p\n    rules:\n      - name: r\n        map:\n" + map + "\n"
        let (config, diagnostics) = ConfigCodec.decode(yaml)
        XCTAssertEqual(diagnostics, [])
        let mappings = try XCTUnwrap(config.activeProfile?.rules.first?.mappings)
        XCTAssertEqual(mappings.map(\.action), SystemAction.allCases.map { .system($0) })
        XCTAssertEqual(SystemAction.allCases.map(\.rawValue).suffix(6), names[...])
        let (again, second) = ConfigCodec.decode(ConfigCodec.encode(config))
        XCTAssertEqual(second, [])
        XCTAssertEqual(again.activeProfile?.rules.first?.mappings.map(\.action), mappings.map(\.action))
    }

    func testDecodesGrammarAndRoundTrips() throws {
        let yaml = #"""
        version: 1
        description: Ignored by the config decoder
        profile: on
        settings:
          tap_timeout_ms: 320
          menu_bar_icon: false
          launch_at_login: true
        app_groups:
          no: [com.apple.Terminal, on]
        profiles:
          - name: on
            rules:
              - name: Key and action forms
                only: [no, com.apple.finder]
                focus: text_input
                map:
                  Ctrl+[c, v x]: Cmd+$1
                  [y n]: $1
                  1: 2
                  ctrl+y: [cmd+z, shift+n]
                  left_cmd: { tap: launchpad }
                  right_cmd: { tap: { open: on } }
                  left_ctrl: { tap: y }
                  ctrl+button4: cmd+left_click
                  caps_lock: none
                  right_click: f20
                  f1: { open: no }
                  f2: { url: "https://example.org/?t=a#fragment" }
                  f3: { shell: "printf 'α: %s'\nnext line # kept" }
                  f4: { system: lock_screen }
                  code:110: equal
              - name: Disabled
                enabled: false
                except: [no]
                passthrough: [ctrl, option, fn]
                focus: not_text_input
                map:
                  ctrl+left_click: { shell: "echo $1" }
              - name: Empty
                passthrough: []
                map: {}
        """#
        let (config, diagnostics) = ConfigCodec.decode(yaml)
        XCTAssertEqual(diagnostics, [])
        XCTAssertEqual(config.selectedProfile, "on")
        XCTAssertEqual(config.settings.tapTimeoutMs, 320)
        XCTAssertFalse(config.settings.showMenuBarIcon)
        XCTAssertTrue(config.settings.launchAtLogin)
        XCTAssertEqual(config.appGroups, ["no": ["com.apple.Terminal", "on"]])
        let profile = try XCTUnwrap(config.activeProfile)
        XCTAssertEqual(profile.rules.count, 3)
        let rule = try XCTUnwrap(profile.rules.first)
        XCTAssertEqual(rule.scope, AppScope(.only, ["no", "com.apple.finder"]))
        XCTAssertEqual(rule.focus, .textInput)
        XCTAssertEqual(rule.passthrough, [.shift])
        XCTAssertEqual(rule.mappings.map(\.trigger.description), [
            "ctrl+c", "ctrl+v", "ctrl+x", "y", "n", "1", "ctrl+y", "left_cmd", "right_cmd", "left_ctrl",
            "ctrl+button4", "caps_lock", "right_click", "f1", "f2", "f3", "f4", "menu",
        ])
        XCTAssertEqual(rule.mappings[0].action, .keys([try XCTUnwrap(KeyCombo(parsing: "cmd+c"))]))
        XCTAssertEqual(rule.mappings[3].action, .keys([try XCTUnwrap(KeyCombo(parsing: "y"))]))
        XCTAssertEqual(rule.mappings[4].action, .keys([try XCTUnwrap(KeyCombo(parsing: "n"))]))
        XCTAssertEqual(rule.mappings[6].action, .keys([
            try XCTUnwrap(KeyCombo(parsing: "cmd+z")), try XCTUnwrap(KeyCombo(parsing: "shift+n")),
        ]))
        XCTAssertEqual(rule.mappings[7...9].map(\.isTapAlone), [true, true, true])
        XCTAssertEqual(rule.mappings[7].action, .system(.launchpad))
        XCTAssertEqual(rule.mappings[8].action, .openApp("on"))
        XCTAssertEqual(rule.mappings[10].action, .mouse(.left, [.command]))
        XCTAssertEqual(rule.mappings[11].action, .none)
        XCTAssertEqual(rule.mappings[13].action, .openApp("no"))
        XCTAssertEqual(rule.mappings[15].action, .shell("printf 'α: %s'\nnext line # kept"))
        XCTAssertFalse(profile.rules[1].enabled)
        XCTAssertEqual(profile.rules[1].passthrough, [.control, .option, .function])
        XCTAssertEqual(profile.rules[1].mappings.first?.action, .shell("echo $1"))
        XCTAssertTrue(profile.rules[2].passthrough.isEmpty)
        assertRoundTrip(config)
    }

    func testPreservesValidEntriesAndReportsFaultyLocations() throws {
        let yaml = """
        settings:
          tap_timeout_ms: wrong
        profiles:
          - name: Test
            rules:
              - name: Both scopes
                only: []
                except: [example]
                map: {a: b}
              - name: Invalid focus
                focus: desktop
                map: {a: b}
              - name: Mixed map
                map:
                  bad_key: a
                  left_click+: a
                  a: {tap: launchpad}
                  left_cmd: {tap: [a, b]}
                  f1: [a, right_click]
                  f2: {open: something, system: launchpad}
                  f3: {system: unknown}
                  ctrl+[a missing, z]: cmd+$1
                  n: y
        """
        let (config, diagnostics) = ConfigCodec.decode(yaml)
        XCTAssertEqual(diagnostics.map(\.line), [2, 8, 11, 15, 16, 17, 18, 19, 20, 21, 22])
        XCTAssertTrue(diagnostics.allSatisfy { $0.severity == .error })
        XCTAssertEqual(config.settings.tapTimeoutMs, 500)
        let profile = try XCTUnwrap(config.activeProfile)
        XCTAssertEqual(profile.rules.count, 1)
        XCTAssertEqual(profile.rules.first?.mappings.map(\.trigger.description), ["ctrl+a", "ctrl+z", "n"])
    }

    func testReportsYAMLSyntaxAtSourceLine() {
        let (_, diagnostics) = ConfigCodec.decode("profiles: [\n")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertNotNil(diagnostics.first?.line)
    }

    func testEncodesSemanticDuplicateTriggersInOrder() {
        let yaml = """
        profiles:
          - name: Example
            rules:
              - name: Duplicates
                map:
                  ctrl+y: a
                  control+y: b
                  CTRL+Y: c
        """
        let (config, diagnostics) = ConfigCodec.decode(yaml)
        XCTAssertEqual(diagnostics, [])
        XCTAssertEqual(config.activeProfile?.rules.first?.mappings.count, 3)
        assertRoundTrip(config)
    }
}

func withoutIDs(_ config: Config) -> Config {
    let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    var config = config
    for profile in config.profiles.indices {
        config.profiles[profile].id = id
        for rule in config.profiles[profile].rules.indices {
            config.profiles[profile].rules[rule].id = id
            for mapping in config.profiles[profile].rules[rule].mappings.indices {
                config.profiles[profile].rules[rule].mappings[mapping].id = id
            }
        }
    }
    return config
}

func assertRoundTrip(_ config: Config, file: StaticString = #filePath, line: UInt = #line) {
    let yaml = ConfigCodec.encode(config)
    let (decoded, diagnostics) = ConfigCodec.decode(yaml)
    XCTAssertEqual(diagnostics, [], file: file, line: line)
    XCTAssertEqual(withoutIDs(decoded), withoutIDs(config), file: file, line: line)
    XCTAssertEqual(ConfigCodec.encode(decoded), yaml, file: file, line: line)
}
