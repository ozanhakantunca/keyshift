import Foundation

struct CLIRequest: Codable, Equatable {
    enum Command: String, Codable {
        case status, reload, profile, importKarabiner, selftest, open, enable, disable
    }

    let command: Command
    var argument: String? = nil

    func validate() throws {
        switch command {
        case .selftest:
            guard argument == nil || argument == "--suite" else { throw CLIProtocolError.invalidRequest }
        case .status, .reload, .enable, .disable:
            guard argument == nil else { throw CLIProtocolError.invalidRequest }
        case .profile:
            guard argument?.isEmpty != true else { throw CLIProtocolError.invalidRequest }
        case .importKarabiner:
            guard argument == nil || argument?.hasPrefix("/") == true else { throw CLIProtocolError.invalidRequest }
        case .open:
            if let argument, SettingsSection(rawValue: argument) == nil { throw CLIProtocolError.invalidRequest }
        }
    }
}

struct CLIResponse: Codable {
    var lines: [String] = []
    var error: String? = nil
    var exitCode: Int32 = 0
}

enum CLIProtocolError: LocalizedError {
    case invalidRequest, oversizedPayload, unavailable, transport(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid command or arguments."
        case .oversizedPayload: return "The IPC payload is too large."
        case .unavailable: return "Keyshift is not running. Open Keyshift.app and try again."
        case .transport(let status): return "Could not reach the running app (transport status \(status))."
        }
    }
}

enum CLICoding {
    static let portName = "io.github.ozanhakantunca.keyshift.cli"
    private static let maximumPayloadSize = 1_048_576

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumPayloadSize else { throw CLIProtocolError.oversizedPayload }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumPayloadSize else { throw CLIProtocolError.oversizedPayload }
        return try JSONDecoder().decode(type, from: data)
    }
}
