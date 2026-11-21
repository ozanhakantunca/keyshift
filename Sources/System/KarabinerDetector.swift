import Foundation

public enum KarabinerDetector {
    private static let processNames: Set<String> = [
        "karabiner_grabber", "Karabiner-Core-Service",
        "karabiner_console_user_server", "Karabiner-Console-User-Server",
    ]

    public static func isRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aww", "-o", "comm="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .contains { matchesProcess(String($0)) }
    }

    public static func matchesProcess(_ command: String) -> Bool {
        let path = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return processNames.contains((path as NSString).lastPathComponent)
    }
}
