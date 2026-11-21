import AppKit

MainActor.assumeIsolated {
    if let code = CLI.runIfRequested(arguments: CommandLine.arguments) {
        exit(code)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
