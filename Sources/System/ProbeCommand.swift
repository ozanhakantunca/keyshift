import Darwin
import Foundation

enum ProbeCommand {
    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        if finished.wait(timeout: .now() + .seconds(3)) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + .milliseconds(250)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + .milliseconds(250))
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        do {
            return String(data: try output.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8)
        } catch {
            return nil
        }
    }
}
