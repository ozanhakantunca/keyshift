import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case rules, presets, apps, conflicts, events, general, about
    var id: String { rawValue }
}

/// CONTRACT: the UI layer (`Sources/App/UI`) implements these; the runtime layer (menu bar,
/// AppDelegate, CLI `keyshift open`) only calls them. Do not change signatures without the lead.
@MainActor
enum WindowRouter {
    static func showSettings(_ section: SettingsSection = .rules) {
        navigation.section = section
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        present(window)
    }

    static func showOnboarding() {
        let window = onboardingWindow ?? makeOnboardingWindow()
        onboardingWindow = window
        present(window)
    }

    // MARK: - Internal (UI layer only)

    /// Shared navigation state of the settings window (section + "show this rule" requests).
    static let navigation = SettingsNavigation()

    static func closeOnboarding() {
        onboardingWindow?.close()
    }

    private static var settingsWindow: NSWindow?
    private static var onboardingWindow: NSWindow?
    private static let windowDelegate = WindowDelegate()

    private static func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeSettingsWindow() -> NSWindow {
        let root = SettingsRootView()
            .environmentObject(AppModel.shared)
            .environmentObject(navigation)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        let controller = NSHostingController(rootView: root)
        // The window owns its size; SwiftUI's ideal/min sizes must not grow it (long rule lists).
        controller.sizingOptions = []
        window.contentViewController = controller
        window.title = String(localized: "Keyshift Settings")
        window.toolbar = NSToolbar(identifier: "KeyshiftSettings")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 900, height: 620))
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.delegate = windowDelegate
        window.center()
        window.setFrameAutosaveName("KeyshiftSettings")
        return window
    }

    private static func makeOnboardingWindow() -> NSWindow {
        let root = OnboardingView()
            .environmentObject(AppModel.shared)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentViewController = NSHostingController(rootView: root)
        window.title = String(localized: "Welcome to Keyshift")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("onboarding")
        window.delegate = windowDelegate
        window.center()
        return window
    }

    /// Stops recording / the event viewer when a window goes away.
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                KeyRecorder.shared.cancel()
                if (notification.object as? NSWindow)?.identifier?.rawValue == "settings" {
                    AppModel.shared.eventViewerActive = false
                }
            }
        }

        func windowDidBecomeKey(_ notification: Notification) {
            MainActor.assumeIsolated {
                if (notification.object as? NSWindow)?.identifier?.rawValue == "settings",
                   WindowRouter.navigation.section == .events {
                    AppModel.shared.eventViewerActive = true
                }
            }
        }
    }
}

/// Selected sidebar section and a pending "scroll to this rule" request.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection? = .rules
    @Published var focusedRuleID: UUID?

    func showRule(_ id: UUID) {
        section = .rules
        focusedRuleID = id
    }
}
