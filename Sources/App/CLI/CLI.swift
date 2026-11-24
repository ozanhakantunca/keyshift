import CoreFoundation
import Foundation
import KeyshiftConfig
import KeyshiftCore
import KeyshiftSystem

enum CLI {
    enum Invocation: Equatable {
        case help, version
        case check(String?)
        case importDryRun(String?)
        case request(CLIRequest)
    }

    static let help = """
    Usage: keyshift <command>
      status                         Show engine, profile, permissions, and issues.
      reload                         Reload the config in the running app.
      check [path]                   Validate YAML and show conflicts.
      profile [name]                 List profiles or select one.
      import-karabiner [path] [--dry-run]
                                     Import karabiner.json or preview its report.
      selftest [--suite]             Run the Ctrl+C probe or the live Windows preset suite.
      open [section]                 Open settings (rules, presets, apps, conflicts, events, general, about).
      enable | disable               Resume or pause remapping for this app session.
      --help                         Show this help.
      --version                      Print the installed version.
    """

    /// Arguments include argv[0], matching CommandLine.arguments.
    static func parse(_ arguments: [String]) throws -> Invocation? {
        let args = Array(arguments.dropFirst())
        guard let command = args.first else {
            let executable = (arguments.first as NSString?)?.lastPathComponent
            return executable == "keyshift" ? .help : nil
        }
        let operands = Array(args.dropFirst())
        if args == ["--help"] || args == ["-h"] { return .help }
        if args == ["--version"] { return .version }
        if command == "import-karabiner" {
            let paths = operands.filter { $0 != "--dry-run" }
            guard operands.count - paths.count <= 1 else { throw CLIProtocolError.invalidRequest }
            let path = try optionalArgument(paths)
            if operands.contains("--dry-run") { return .importDryRun(path) }
            return .request(CLIRequest(command: .importKarabiner, argument: path.map { fileURL($0).path }))
        }
        if command == "check" { return .check(try optionalArgument(operands)) }
        if command == "selftest" {
            guard operands.isEmpty || operands == ["--suite"] else { throw CLIProtocolError.invalidRequest }
            return .request(CLIRequest(command: .selftest, argument: operands.first))
        }
        guard let kind = CLIRequest.Command(rawValue: command), kind != .importKarabiner else {
            throw CLIProtocolError.invalidRequest
        }
        let request = try CLIRequest(command: kind, argument: optionalArgument(operands))
        try request.validate()
        return .request(request)
    }

    private static func optionalArgument(_ operands: [String]) throws -> String? {
        if operands.count == 2, operands[0] == "--", !operands[1].isEmpty { return operands[1] }
        guard operands.count <= 1, operands.first?.isEmpty != true, operands.first?.hasPrefix("-") != true else {
            throw CLIProtocolError.invalidRequest
        }
        return operands.first
    }

    static func runIfRequested(arguments: [String]) -> Int32? {
        let invocation: Invocation
        do {
            guard let parsed = try parse(arguments) else { return nil }
            invocation = parsed
        } catch {
            return fail("\(error.localizedDescription)\n\(help)")
        }

        do {
            let response: CLIResponse
            switch invocation {
            case .help:
                print(help)
                return 0
            case .version:
                print("Keyshift \(installedVersion())")
                return 0
            case .check(let path):
                response = try check(path.map(fileURL) ?? ConfigStore.defaultURL)
            case .importDryRun(let path):
                let (_, report) = try KarabinerImporter.importFile(at: path.map(fileURL) ?? ConfigEdits.defaultKarabinerURL)
                response = CLIResponse(lines: importLines(report))
            case .request(let request):
                if let port = CFMessagePortCreateRemote(nil, CLICoding.portName as CFString) {
                    response = try send(request, to: port)
                } else {
                    response = try offline(request)
                }
            }
            response.lines.forEach { print($0) }
            if let error = response.error { return fail(error) }
            return response.exitCode
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private static func send(_ request: CLIRequest, to port: CFMessagePort) throws -> CLIResponse {
        let data = try CLICoding.encode(request)
        var reply: Unmanaged<CFData>?
        let isLong = request.command == .importKarabiner || (request.command == .selftest && request.argument == "--suite")
        let timeout: CFTimeInterval = isLong ? 40 : 5
        let status = CFMessagePortSendRequest(port, 1, data as CFData, 2, timeout, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let result = reply?.takeRetainedValue() else {
            throw CLIProtocolError.transport(status)
        }
        return try CLICoding.decode(CLIResponse.self, from: result as Data)
    }

    private static func offline(_ request: CLIRequest) throws -> CLIResponse {
        let store = ConfigStore()
        switch request.command {
        case .status:
            let loaded = store.load()
            let config = loaded?.0 ?? Config()
            let diagnostics = loaded?.1 ?? []
            let conflicts = ConfigEdits.conflicts(in: config, shortcuts: SystemShortcuts.enabled())
            return CLIResponse(lines: statusLines(
                appRunning: false, engineRunning: false, enabled: nil, hasConfig: loaded != nil,
                profile: config.activeProfile?.name,
                permissions: PermissionState(accessibility: Permissions.accessibility(),
                                             inputMonitoring: Permissions.inputMonitoring()),
                karabinerRunning: KarabinerDetector.isRunning(), secureInput: SecureInput.isEnabled(),
                diagnostics: diagnostics.count, conflicts: conflicts.count, startError: nil
            ))
        case .profile:
            if let name = request.argument {
                var (config, contents) = try editableConfig(in: store)
                try ConfigEdits.select(name, in: &config)
                try store.save(config, condition: .unchangedSince(contents))
                return CLIResponse(lines: ["Selected profile: \(name)"])
            }
            let (config, diagnostics) = store.load() ?? (Config(), [])
            return CLIResponse(lines: profileLines(config) + diagnosticLines(diagnostics, at: store.url),
                               exitCode: ConfigEdits.hasErrors(diagnostics) ? 1 : 0)
        case .importKarabiner:
            let url = request.argument.map(fileURL) ?? ConfigEdits.defaultKarabinerURL
            let (incoming, report) = try KarabinerImporter.importFile(at: url)
            if !incoming.profiles.isEmpty {
                var (config, contents) = try editableConfig(in: store)
                ConfigEdits.append(incoming, to: &config)
                try store.save(config, condition: .unchangedSince(contents))
            }
            return CLIResponse(lines: importLines(report))
        case .reload, .selftest, .open, .enable, .disable:
            throw CLIProtocolError.unavailable
        }
    }

    /// The config to edit and the bytes it was read from (nil: no file yet).
    private static func editableConfig(in store: ConfigStore) throws -> (Config, Data?) {
        guard let loaded = store.loadDetailed() else { return (Config(), nil) }
        guard !loaded.hasErrors else { throw ConfigEditError.invalidConfig(store.url) }
        return (loaded.config, loaded.contents)
    }

    private static func check(_ url: URL) throws -> CLIResponse {
        let store = ConfigStore(url: url)
        guard let (config, fileDiagnostics) = store.load() else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Config file does not exist at \(store.url.path)."])
        }
        let diagnostics = fileDiagnostics + (config.activeProfile.map { profile in
            ModifierKeyCheck.diagnostics(in: profile) { ModifierRemapper.hidUsage(for: $0) != nil }
        } ?? [])
        let conflicts = ConfigEdits.conflicts(in: config, shortcuts: SystemShortcuts.enabled())
        let lines = diagnosticLines(diagnostics, at: store.url) + conflictLines(conflicts)
        return CLIResponse(lines: lines + ["\(diagnostics.count) diagnostic(s), \(conflicts.count) conflict(s)."],
                           exitCode: ConfigEdits.hasErrors(diagnostics) ? 1 : 0)
    }

    static func diagnosticLines(_ diagnostics: [Diagnostic], at url: URL) -> [String] {
        diagnostics.map { diagnostic in
            let location = diagnostic.line.map { "\(url.path):\($0)" } ?? url.path
            return "\(location): \(diagnostic.severity.rawValue): \(diagnostic.message)"
        }
    }

    private static func conflictLines(_ conflicts: [Conflict]) -> [String] {
        conflicts.map { "conflict: \($0.message)" }
    }

    static func profileLines(_ config: Config) -> [String] {
        guard !config.profiles.isEmpty else { return ["No profiles."] }
        return config.profiles.map { "\($0.id == config.activeProfile?.id ? "*" : " ") \($0.name)" }
    }

    /// Warning lines beyond this are summarized, so the reply stays within the IPC payload limit.
    static let maximumImportWarnings = 200

    static func importLines(_ report: ImportReport) -> [String] {
        let warnings = report.warnings.prefix(maximumImportWarnings).map { "warning: \($0)" }
        let hidden = report.warnings.count - warnings.count
        return ["Imported \(report.importedCount) mapping(s), skipped \(report.skippedCount)."]
            + report.skippedByReason.keys.sorted().map { "  \($0): \(report.skippedByReason[$0, default: 0])" }
            + (report.shellCommands.isEmpty ? [] : [
                "\(report.shellCommands.count) imported mapping(s) run shell commands; review them (see the warnings).",
            ])
            + warnings
            + (hidden > 0 ? ["…and \(hidden) more warning(s)."] : [])
    }

    static func statusLines(
        appRunning: Bool, engineRunning: Bool, enabled: Bool?, hasConfig: Bool,
        profile: String?, permissions: PermissionState, karabinerRunning: Bool, secureInput: Bool,
        diagnostics: Int, conflicts: Int, startError: String?, usingPreviousConfig: Bool = false
    ) -> [String] {
        var lines = [
            "App: \(appRunning ? "running" : "stopped")",
            "Engine: \(engineRunning ? "running" : "stopped")",
            "Config: \(hasConfig ? "present" : "missing")",
            "Profile: \(profile ?? "none")",
            "Accessibility: \(permissions.accessibility ? "granted" : "required")",
            "Input Monitoring: \(permissions.inputMonitoring ? "granted" : "required")",
            "Karabiner-Elements: \(karabinerRunning ? "also running (warning)" : "stopped")",
            "Secure Input: \(secureInput ? "active (macOS pauses most remapping)" : "inactive")",
            "Diagnostics: \(diagnostics)",
            "Conflicts: \(conflicts)",
        ]
        if let enabled { lines.insert("Remapping: \(enabled ? "enabled" : "disabled")", at: 2) }
        if let startError { lines.append("Engine start error: \(startError)") }
        if usingPreviousConfig { lines.append("Config file could not be parsed; the previous configuration is still active.") }
        return lines
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func installedVersion() -> String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        let executable = fileURL(CommandLine.arguments[0]).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        if contents.lastPathComponent == "Contents",
           let bundle = Bundle(url: contents.deletingLastPathComponent()),
           let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        let versionFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("VERSION")
        return (try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
            ?? "0.1.0"
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("keyshift: \(message)\n".utf8))
        return 1
    }
}
