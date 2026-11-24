import AppKit
import Combine

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let profilesMenu = NSMenu()
    private let profilesItem = NSMenuItem(title: String(localized: "Profiles"), action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem()
    private let warningLine = NSMenuItem(title: String(localized: "⚠ Karabiner-Elements is also running"), action: nil, keyEquivalent: "")
    private var enabledItem: NSMenuItem!
    private var conflictsItem: NSMenuItem!
    private var observations: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        super.init()

        let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyshift")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Keyshift"

        menu.delegate = self
        menu.autoenablesItems = false
        profilesMenu.autoenablesItems = false

        enabledItem = item(String(localized: "Enabled"), #selector(toggleEnabled))
        menu.addItem(enabledItem)
        profilesItem.submenu = profilesMenu
        menu.addItem(profilesItem)
        menu.addItem(.separator())

        statusLine.target = self
        menu.addItem(statusLine)
        warningLine.isEnabled = false
        menu.addItem(warningLine)
        conflictsItem = item("", #selector(showConflicts))
        menu.addItem(conflictsItem)
        menu.addItem(.separator())

        menu.addItem(item(String(localized: "Settings…"), #selector(showSettings), key: ","))
        menu.addItem(item(String(localized: "Edit config file"), #selector(editConfig)))
        menu.addItem(item(String(localized: "Event viewer"), #selector(showEvents)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Keyshift"), #selector(quit), key: "q"))
        statusItem.menu = menu

        model.$isEnabled.combineLatest(model.$engineRunning).sink { [weak self] enabled, running in
            self?.statusItem.button?.alphaValue = enabled && running ? 1 : 0.45
        }.store(in: &observations)
        model.$config.sink { [weak self, weak model] config in
            self?.statusItem.isVisible = model?.hasConfigFile != true || config.settings.showMenuBarIcon
        }.store(in: &observations)
        refreshMenu()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        enabledItem.state = model.isEnabled ? .on : .off
        profilesMenu.removeAllItems()
        for profile in model.config.profiles {
            let profileItem = item(profile.name, #selector(selectProfile(_:)))
            profileItem.representedObject = profile.name
            profileItem.state = profile.id == model.activeProfile?.id ? .on : .off
            profilesMenu.addItem(profileItem)
        }
        // Switching profiles saves the file, which is refused while it has errors.
        profilesItem.isEnabled = !model.config.profiles.isEmpty && !model.configHasErrors

        let needsSetup = !model.permissions.allGranted || !model.hasConfigFile
        if !model.permissions.allGranted {
            statusLine.title = String(localized: "Needs permission")
        } else if !model.hasConfigFile {
            statusLine.title = String(localized: "Set up Keyshift…")
        } else if !model.engineRunning {
            statusLine.title = String(localized: "Engine stopped")
        } else if model.isEnabled && model.secureInputActive {
            statusLine.title = String(localized: "Paused by macOS (secure input)")
        } else {
            statusLine.title = model.isEnabled ? String(localized: "Running") : String(localized: "Paused")
        }
        statusLine.toolTip = model.lastStartError
            ?? (model.configHasErrors ? String(localized: "The config file has errors. Fix the file before editing here.") : nil)
        statusLine.action = needsSetup ? #selector(showOnboarding) : nil
        statusLine.isEnabled = needsSetup
        warningLine.isHidden = !model.karabinerRunning
        let count = model.ruleConflicts.count
        conflictsItem.title = count == 1 ? String(localized: "1 conflict") : String(localized: "\(count) conflicts")
    }

    @objc private func toggleEnabled() { model.isEnabled.toggle() }
    @objc private func selectProfile(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { model.selectProfile(name) }
    }

    @objc private func showOnboarding() { WindowRouter.showOnboarding() }
    @objc private func showSettings() { WindowRouter.showSettings(.rules) }
    @objc private func showConflicts() { WindowRouter.showSettings(.conflicts) }
    @objc private func showEvents() { WindowRouter.showSettings(.events) }
    @objc private func editConfig() { model.openConfigInEditor() }
    @objc private func quit() { NSApp.terminate(nil) }
}
