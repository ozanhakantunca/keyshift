import CoreFoundation
import Foundation
import KeyshiftCore

@MainActor
final class CLIServer {
    private let model: AppModel
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    init(model: AppModel) {
        self.model = model
    }

    /// The main run loop serializes commands with UI edits and config reloads.
    func start() -> Bool {
        if port != nil { return true }
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        var shouldFree = DarwinBoolean(false)
        guard let port = CFMessagePortCreateLocal(nil, CLICoding.portName as CFString, { _, _, data, info in
            guard let data, let info else { return nil }
            return MainActor.assumeIsolated {
                let server = Unmanaged<CLIServer>.fromOpaque(info).takeUnretainedValue()
                let response = server.respond(to: data as Data)
                let encoded = (try? CLICoding.encode(response))
                    ?? (try? CLICoding.encode(CLIResponse(error: CLIProtocolError.oversizedPayload.localizedDescription)))
                return encoded.map { Unmanaged.passRetained($0 as CFData) }
            }
        }, &context, &shouldFree), !shouldFree.boolValue else { return false }
        guard let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
            CFMessagePortInvalidate(port)
            return false
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        if let port { CFMessagePortInvalidate(port) }
        if let source { CFRunLoopSourceInvalidate(source) }
        source = nil
        port = nil
    }

    deinit {
        if let port { CFMessagePortInvalidate(port) }
        if let source { CFRunLoopSourceInvalidate(source) }
    }

    private func respond(to data: Data) -> CLIResponse {
        do {
            let request = try CLICoding.decode(CLIRequest.self, from: data)
            try request.validate()
            return try respond(to: request)
        } catch {
            return CLIResponse(error: error.localizedDescription)
        }
    }

    private func respond(to request: CLIRequest) throws -> CLIResponse {
        switch request.command {
        case .status:
            return CLIResponse(lines: CLI.statusLines(
                appRunning: true, engineRunning: model.engineRunning, enabled: model.isEnabled,
                hasConfig: model.hasConfigFile, profile: model.activeProfile?.name, permissions: model.permissions,
                karabinerRunning: model.karabinerRunning, secureInput: model.secureInputActive,
                diagnostics: model.diagnostics.count, conflicts: model.conflicts.count, startError: model.lastStartError,
                usingPreviousConfig: model.usingPreviousConfig
            ))
        case .reload:
            model.reloadFromDisk()
            let diagnostics = model.diagnostics
            let previous = model.usingPreviousConfig
                ? ["The file could not be parsed; the previous configuration stays active."] : []
            return CLIResponse(lines: ["Reloaded \(model.configURL.path)."] + previous
                                   + CLI.diagnosticLines(diagnostics, at: model.configURL),
                               exitCode: ConfigEdits.hasErrors(diagnostics) ? 1 : 0)
        case .profile:
            guard let name = request.argument else { return CLIResponse(lines: CLI.profileLines(model.config)) }
            try model.prepareCLIEdit()
            try model.switchProfile(name)
            return CLIResponse(lines: ["Selected profile: \(name)"])
        case .importKarabiner:
            try model.prepareCLIEdit()
            let report = try model.importKarabiner(from: request.argument.map { URL(fileURLWithPath: $0) })
            return CLIResponse(lines: CLI.importLines(report))
        case .selftest:
            if request.argument == "--suite" {
                let rows = try model.runSelfTestSuite()
                let width = max(8, rows.map { $0.scenario.count }.max() ?? 0)
                let header = "Scenario".padding(toLength: width, withPad: " ", startingAt: 0) + "  Result  Observed"
                let lines = rows.map { row in
                    let name = row.scenario + String(repeating: " ", count: width - row.scenario.count)
                    return "\(name)  \(row.status.rawValue)    \(row.detail)"
                }
                return CLIResponse(lines: [header] + lines, exitCode: rows.contains { $0.status == .fail } ? 1 : 0)
            }
            let result = try model.runSelfTest()
            let observed = result.observed.map(EventDescription.input).joined(separator: ", ")
            let lines = [
                "Self-test: \(result.outcome.rawValue)",
                "Expected: \(result.input.displayString) → \(result.expected.displayString)",
                "Observed: \(observed.isEmpty ? "none" : observed)",
            ]
            return CLIResponse(lines: lines, exitCode: result.passed ? 0 : 1)
        case .open:
            WindowRouter.showSettings(request.argument.flatMap(SettingsSection.init(rawValue:)) ?? .rules)
            return CLIResponse()
        case .enable, .disable:
            model.isEnabled = request.command == .enable
            return CLIResponse(lines: ["Remapping \(model.isEnabled ? "enabled" : "disabled")."])
        }
    }
}
