import Foundation
import OSLog
import ServiceManagement

@MainActor
enum LoginItem {
    private static let logger = Logger(subsystem: "io.github.ozanhakantunca.keyshift", category: "login-item")

    @discardableResult
    static func apply(enabled: Bool) -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return true }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            return true
        } catch {
            logger.error("Could not change launch at login: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
