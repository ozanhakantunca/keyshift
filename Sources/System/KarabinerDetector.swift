import Darwin
import Foundation

public enum KarabinerDetector {
    private static let processNames: Set<String> = [
        "karabiner_grabber", "Karabiner-Core-Service",
        "karabiner_console_user_server", "Karabiner-Console-User-Server",
    ]

    /// Reads the process table directly (no `ps` child process). Karabiner's daemons run as root;
    /// `proc_pidpath` still reports their executable path.
    public static func isRunning() -> Bool {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }
        // Leave room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                if matchesProcess(String(cString: path)) { return true }
            } else if proc_name(pid, &path, UInt32(path.count)) > 0, matchesProcess(String(cString: path)) {
                return true
            }
        }
        return false
    }

    public static func matchesProcess(_ command: String) -> Bool {
        let path = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return processNames.contains((path as NSString).lastPathComponent)
    }
}
