import Foundation
import KeyshiftConfig
import KeyshiftCore
import XCTest

final class KarabinerImporterTests: XCTestCase {
    func testConvertsProfilesActionsAndScopedGroups() throws {
        let json = #"""
        {"profiles":[
          {"name":"Other"},
          {"name":"Selected","selected":true,
           "simple_modifications":[{"from":{"key_code":"delete_or_backspace"},"to":[{"key_code":"delete_forward"}]}],
           "complex_modifications":{"rules":[
             {"description":"Conversions","manipulators":[
               {"type":"basic","from":{"key_code":"return_or_enter","modifiers":{"mandatory":["left_control"],"optional":["any"]}},
                "to":[{"key_code":"open_bracket","modifiers":["left_command"]},{"key_code":"close_bracket"}],
                "conditions":[{"type":"frontmost_application_if","bundle_identifiers":["^com\\.apple\\.finder$"]}]},
               {"type":"basic","from":{"key_code":"spacebar","modifiers":{"optional":["caps_lock"]}},
                "to":[{"shell_command":"open -a \"Activity Monitor\""}]},
               {"type":"basic","from":{"key_code":"grave_accent_and_tilde","modifiers":{"mandatory":["control"],"optional":["any"]}},
                "to":[{"shell_command":"open 'https://example.org/?a=b&c=d'"}],
                "conditions":[{"type":"frontmost_application_if","bundle_identifiers":["^com\\.apple\\.finder$"]}]},
               {"type":"basic","from":{"key_code":"left_command"},"to":[{"key_code":"left_command","lazy":true}],
                "to_if_alone":[{"key_code":"launchpad"}]},
               {"type":"basic","from":{"pointing_button":"button4","modifiers":{"optional":["shift"]}},
                "to":[{"pointing_button":"button1","modifiers":["command"]}],
                "conditions":[{"type":"frontmost_application_unless","bundle_identifiers":["^com\\.example.*$"]}]},
               {"type":"basic","from":{"key_code":"f1"},"to":[{"shell_command":"open -a Finder && echo hello"}]}
             ]}
           ]}
          }
        ]}
        """#
        let (config, report) = try importJSON(json)
        XCTAssertEqual(config.profiles.map(\.name), ["Other", "Selected"])
        XCTAssertEqual(config.selectedProfile, "Selected")
        XCTAssertEqual(report.importedCount, 7)
        XCTAssertEqual(report.skippedCount, 0)
        XCTAssertEqual(report.warnings.count, 2)
        XCTAssertTrue(report.warnings[0].contains("imported as the literal"))
        XCTAssertEqual(report.shellCommands, ["Profile 'Selected', rule 'Conversions': open -a Finder && echo hello"])
        XCTAssertTrue(report.warnings[1].contains("runs the shell command `open -a Finder && echo hello`"))
        let profile = try XCTUnwrap(config.activeProfile)
        XCTAssertEqual(profile.rules.map(\.name), ["Simple Modifications", "Conversions", "Conversions", "Conversions"])
        let simple = profile.rules[0]
        XCTAssertEqual(simple.mappings.map(\.action), [.keys([combo("delete")])])
        XCTAssertEqual(simple.mappings.first?.trigger, Trigger(parsing: "backspace"))
        let scoped = profile.rules[1]
        XCTAssertEqual(scoped.scope, AppScope(.only, ["com.apple.finder"]))
        XCTAssertEqual(scoped.passthrough, [.control, .option, .shift, .command, .function])
        XCTAssertEqual(scoped.mappings.map(\.trigger.description), ["ctrl+return", "ctrl+grave"])
        XCTAssertEqual(scoped.mappings.map(\.action), [
            .keys([combo("cmd+left_bracket"), combo("right_bracket")]), .openURL("https://example.org/?a=b&c=d"),
        ])
        let global = profile.rules[2]
        XCTAssertEqual(global.passthrough, [])
        XCTAssertEqual(global.mappings.map(\.action), [
            .openApp("Activity Monitor"), .system(.launchpad), .shell("open -a Finder && echo hello"),
        ])
        XCTAssertEqual(global.mappings.map(\.isTapAlone), [false, true, false])
        let mouse = profile.rules[3]
        XCTAssertEqual(mouse.scope, AppScope(.except, ["com.example"]))
        XCTAssertEqual(mouse.passthrough, [.shift])
        XCTAssertEqual(mouse.mappings.first?.trigger, .mouse(.button4, []))
        XCTAssertEqual(mouse.mappings.first?.action, .mouse(.left, [.command]))
        assertRoundTrip(config)
    }

    func testSkipsUnsupportedManipulatorsAndCountsReasons() throws {
        let json = #"""
        {"profiles":[{"name":"Synthetic","complex_modifications":{"rules":[
          {"description":"Examples","manipulators":[
            {"type":"basic","from":{"key_code":"a"},"to":[{"key_code":"b"}],
             "conditions":[{"type":"variable_if","name":"x","value":1}]},
            {"type":"basic","from":{"key_code":"a"},"to":[{"key_code":"b"}],
             "conditions":[{"type":"device_if","identifiers":[]}]},
            {"type":"basic","from":{"simultaneous":[{"key_code":"a"},{"key_code":"b"}]},"to":[{"key_code":"c"}]},
            {"type":"basic","from":{"key_code":"c"},"to":[{"key_code":"d"}],"to_delayed_action":{}},
            {"type":"basic","from":{"key_code":"d"},"to":[{"key_code":"e"}],"to_after_key_up":[]},
            {"type":"basic","from":{"key_code":"e"},"to":[{"mouse_key":{"x":1}}]},
            {"type":"basic","from":{"key_code":"f"},"to":[{"set_variable":{"name":"x","value":1}}]},
            {"type":"basic","from":{"key_code":"g"},"to":[{"key_code":"h"}],
             "conditions":[{"type":"frontmost_application_unless","file_paths":["^/Applications/(Foo|Bar)\\.app/"]}]},
            {"type":"basic","from":{"key_code":"j"},"to":[]}
          ]}
        ]}}]}
        """#
        let (config, report) = try importJSON(json)
        XCTAssertEqual(report.importedCount, 1)
        XCTAssertEqual(report.skippedCount, 8)
        XCTAssertEqual(report.skippedByReason, [
            "Unsupported condition 'variable_if'": 1,
            "Unsupported condition 'device_if'": 1,
            "Unsupported 'simultaneous'": 1,
            "Unsupported 'to_delayed_action'": 1,
            "Unsupported 'to_after_key_up'": 1,
            "Unsupported 'mouse_key'": 1,
            "Unsupported 'set_variable'": 1,
            "Unsupported frontmost application file_paths": 1,
        ])
        XCTAssertEqual(report.warnings.count, 8)
        XCTAssertEqual(config.activeProfile?.rules.first?.mappings.map(\.action), [.none])
    }

    func testFilePathRegexesBecomePathFragments() throws {
        let json = #"""
        {"profiles":[{"name":"Synthetic","complex_modifications":{"rules":[
          {"description":"Paths","manipulators":[
            {"type":"basic","from":{"key_code":"a"},"to":[{"key_code":"b"}],
             "conditions":[{"type":"frontmost_application_unless","bundle_identifiers":["^com\\.valve\\.steam$"],
               "file_paths":["/steamapps/common/","/League of Legends\\.app/","^/Applications/Epic Games/"]}]},
            {"type":"basic","from":{"key_code":"c"},"to":[{"key_code":"d"}],
             "conditions":[{"type":"frontmost_application_if","file_paths":[".*\\.app/Contents","/Foo/(Bar|Baz)/"]}]},
            {"type":"basic","from":{"key_code":"e"},"to":[{"key_code":"f"}],
             "conditions":[{"type":"frontmost_application_if","bundle_identifiers":["^com\\.a$"],
               "file_paths":["/Foo/(Bar|Baz)/","NoSlash","\\d+/x/"]}]},
            {"type":"basic","from":{"key_code":"g"},"to":[{"key_code":"h"}],
             "conditions":[{"type":"frontmost_application_if","file_paths":["/Games/Foo\\.app$"]}]}
          ]}
        ]}}]}
        """#
        let (config, report) = try importJSON(json)
        XCTAssertEqual(report.importedCount, 3)
        XCTAssertEqual(report.skippedByReason, ["Unsupported frontmost application file_paths": 1])
        XCTAssertEqual(report.warnings.filter { $0.contains("not a literal path fragment") }.count, 3)
        let rules = try XCTUnwrap(config.activeProfile?.rules)
        XCTAssertEqual(rules.map(\.scope), [
            AppScope(.except, ["/applications/epic games/", "/league of legends.app/", "/steamapps/common/",
                               "com.valve.steam"]),
            AppScope(.only, ["com.a"]),
            AppScope(.only, ["/games/foo.app"]),
        ])
        assertRoundTrip(config)
    }

    func testFocusedElementRoleVariablesBecomeFocusConditions() throws {
        func manipulator(_ key: String, _ to: String, _ conditions: String) -> String {
            #"{"type":"basic","from":{"key_code":"\#(key)"},"to":[{"key_code":"\#(to)"}],"conditions":[\#(conditions)]}"#
        }
        func role(_ type: String, _ value: String, name: String = "accessibility.focused_ui_element.role_string") -> String {
            #"{"type":"\#(type)","name":"\#(name)","value":"\#(value)"}"#
        }
        let finder = #"{"type":"frontmost_application_if","bundle_identifiers":["^com\\.apple\\.finder$"]}"#
        let manipulators = [
            manipulator("home", "x", role("variable_if", "AXOutline")),
            manipulator("home", "x", role("variable_if", "AXList")),
            manipulator("home", "x", role("variable_if", "AXTable")),
            manipulator("home", "y", role("variable_if", "AXTextField")),
            manipulator("home", "y", role("variable_if", "AXSearchField")),
            manipulator("home", "x", role("variable_unless", "AXTextArea")),
            manipulator("home", "z", finder + "," + role("variable_if", "AXRow")),
            manipulator("home", "q", role("variable_if", "some.other.variable", name: "some.other.variable")),
            manipulator("home", "q", role("variable_if", "AXWeird")),
            manipulator("home", "q", role("variable_if", "AXTextField") + "," + role("variable_if", "AXOutline")),
        ]
        let json = #"{"profiles":[{"name":"P","complex_modifications":{"rules":[{"description":"Roles","manipulators":[\#(manipulators.joined(separator: ","))]}]}}]}"#
        let (config, report) = try importJSON(json)
        XCTAssertEqual(report.importedCount, 7)
        XCTAssertEqual(report.mergedDuplicateCount, 4)
        XCTAssertEqual(report.skippedByReason, [
            "Unsupported condition 'variable_if'": 1,
            "Unsupported focused element role 'AXWeird'": 1,
            "Contradictory focused element conditions": 1,
        ])
        XCTAssertTrue(report.warnings.filter { $0.contains("narrower") }.isEmpty)
        let rules = try XCTUnwrap(config.activeProfile?.rules)
        XCTAssertEqual(rules.map(\.focus), [.notTextInput, .textInput, .notTextInput])
        XCTAssertEqual(rules.map(\.scope), [.everywhere, .everywhere, AppScope(.only, ["com.apple.finder"])])
        XCTAssertEqual(rules.map { $0.mappings.map(\.action) }, [
            [.keys([combo("x")])], [.keys([combo("y")])], [.keys([combo("z")])],
        ])
        assertRoundTrip(config)
    }

    func testRoleVariableNegationAndPrintScreen() throws {
        let json = #"""
        {"profiles":[{"name":"P","complex_modifications":{"rules":[{"description":"R","manipulators":[
          {"type":"basic","from":{"key_code":"print_screen"},"to":[{"key_code":"spacebar"}],
           "conditions":[{"type":"variable_unless","name":"accessibility.focused_ui_element.role_string","value":"AXList"}]},
          {"type":"basic","from":{"key_code":"a"},"to":[{"key_code":"print_screen"}]}
        ]}]}}]}
        """#
        let (config, report) = try importJSON(json)
        XCTAssertEqual(report.importedCount, 2)
        XCTAssertEqual(report.warnings.filter { $0.contains("narrower") }.count, 1)
        let rules = try XCTUnwrap(config.activeProfile?.rules)
        XCTAssertEqual(rules.map(\.focus), [.textInput, .any])
        XCTAssertEqual(rules[0].mappings.first?.trigger, Trigger(parsing: "f13"))
        XCTAssertEqual(rules[1].mappings.first?.action, .keys([combo("f13")]))
    }

    func testDoesNotReorderOverlappingMappingsWhenGroupingRules() throws {
        let json = #"""
        {"profiles":[{"name":"Synthetic","complex_modifications":{"rules":[
          {"description":"Examples","manipulators":[
            {"type":"basic","from":{"key_code":"b"},"to":[{"key_code":"x"}],
             "conditions":[{"type":"frontmost_application_if","bundle_identifiers":["^app\\.a$"]}]},
            {"type":"basic","from":{"key_code":"a"},"to":[{"key_code":"y"}]},
            {"type":"basic","from":{"key_code":"a"},"to":[{"key_code":"z"}],
             "conditions":[{"type":"frontmost_application_if","bundle_identifiers":["^app\\.a$"]}]}
          ]}
        ]}}]}
        """#
        let (config, report) = try importJSON(json)
        XCTAssertEqual(report.importedCount, 3)
        let rules = try XCTUnwrap(config.activeProfile?.rules)
        XCTAssertEqual(rules.map(\.scope), [.init(.only, ["app.a"]), .everywhere, .init(.only, ["app.a"])])
        XCTAssertEqual(rules.flatMap(\.mappings).map(\.action), [
            .keys([combo("x")]), .keys([combo("y")]), .keys([combo("z")]),
        ])
    }

    func testLocalKarabinerReport() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner/karabiner.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("No local Karabiner config") }
        let (config, report) = try KarabinerImporter.importFile(at: url)
        print("Local Karabiner import: \(report.importedCount) imported (\(report.mergedDuplicateCount) merged "
              + "as duplicates), \(report.skippedCount) skipped, \(report.warnings.count) warning messages, "
              + "\(config.activeProfile?.rules.count ?? 0) rules in the active profile")
        for (reason, count) in report.skippedByReason.sorted(by: { $0.key < $1.key }) {
            print("  \(count) — \(reason)")
        }
        let (roundTripped, diagnostics) = ConfigCodec.decode(ConfigCodec.encode(config))
        XCTAssertTrue(diagnostics.isEmpty, "Imported config produced YAML diagnostics.")
        XCTAssertTrue(withoutIDs(roundTripped) == withoutIDs(config), "Imported config changed on YAML round-trip.")
    }

    func testWarnsAboutLongShellCommandsAndModifierMappingsThatCannotFire() throws {
        let long = String(repeating: "x", count: 300)
        let json = #"""
        {"profiles":[{"name":"P","complex_modifications":{"rules":[{"description":"R","manipulators":[
          {"type":"basic","from":{"key_code":"f1"},"to":[{"shell_command":"\#(long)"}]},
          {"type":"basic","from":{"key_code":"caps_lock"},
           "to":[{"key_code":"left_shift","modifiers":["left_command","left_control","left_option"]}]},
          {"type":"basic","from":{"key_code":"right_command"},"to":[{"key_code":"escape"}]}
        ]}]}}]}
        """#
        let (_, report) = try importJSON(json)
        XCTAssertEqual(report.shellCommands.count, 1)
        XCTAssertEqual(report.shellCommands[0], "Profile 'P', rule 'R': " + String(repeating: "x", count: 200) + "…")
        let modifier = report.warnings.filter { $0.contains(ModifierKeyCheck.explanation) }
        XCTAssertEqual(modifier.count, 1)
        XCTAssertTrue(modifier[0].contains("'caps_lock'"))
    }

    func testRefusesHugeFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: KarabinerImporter.maximumFileSize + 1).write(to: url)
        XCTAssertThrowsError(try KarabinerImporter.importFile(at: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("larger than"))
        }
    }

    private func importJSON(_ json: String) throws -> (Config, ImportReport) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try KarabinerImporter.importFile(at: url)
    }

    private func combo(_ value: String) -> KeyCombo {
        KeyCombo(parsing: value)!
    }
}
