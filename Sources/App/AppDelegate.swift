import AppKit
import Combine
import CoreFoundation
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "io.github.ozanhakantunca.keyshift", category: "app")

    private let model = AppModel.shared
    private var statusMenu: StatusMenu?
    private var cliServer: CLIServer?
    private var loginSetting: AnyCancellable?
    private var appliedLoginSetting: Bool?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOnSignals()
        let server = CLIServer(model: model)
        if server.start() {
            cliServer = server
        } else if CFMessagePortCreateRemote(nil, CLICoding.portName as CFString) != nil {
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        } else {
            Self.logger.error("Could not start the CLI message port.")
        }

        statusMenu = StatusMenu(model: model)
        loginSetting = model.$config.sink { [weak self, weak model] config in
            guard let self, let model, model.hasConfigFile || self.appliedLoginSetting != nil else { return }
            let enabled = model.hasConfigFile && config.settings.launchAtLogin
            if self.appliedLoginSetting != enabled, LoginItem.apply(enabled: enabled) {
                self.appliedLoginSetting = enabled
            }
        }
        model.start()
        if needsOnboarding { WindowRouter.showOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard statusMenu != nil else { return }
        cliServer?.stop()
        model.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if needsOnboarding {
            WindowRouter.showOnboarding()
        } else {
            WindowRouter.showSettings()
        }
        return true
    }

    /// HID remaps outlive the process, so termination signals must go through applicationWillTerminate.
    private func terminateOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private var needsOnboarding: Bool { !model.hasConfigFile || !model.permissions.allGranted }

    private func activateExistingInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != pid }?.activate(options: [])
    }
}
