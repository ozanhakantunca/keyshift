import KeyshiftConfig
import KeyshiftCore
import SwiftUI

/// Welcome → Permissions → "Where are you coming from?" → Done. Steps already satisfied are skipped.
struct OnboardingView: View {
    enum Step: Hashable { case welcome, permissions, origin, done }

    enum Origin: String, CaseIterable, Identifiable {
        case windows, linux, terminal, karabiner, empty
        var id: String { rawValue }

        var presetID: String? {
            switch self {
            case .windows, .linux, .terminal: return rawValue
            case .karabiner, .empty: return nil
            }
        }

        var title: String {
            switch self {
            case .windows: return String(localized: "Windows")
            case .linux: return String(localized: "Linux")
            case .terminal: return String(localized: "Just terminal fixes")
            case .karabiner: return String(localized: "My Karabiner config")
            case .empty: return String(localized: "Start empty")
            }
        }

        var detail: String {
            switch self {
            case .windows: return String(localized: "Ctrl+C/V, Home/End, Alt+F4, F2 to rename, the Windows key")
            case .linux: return String(localized: "Ctrl shortcuts, Super key actions, workspace switching")
            case .terminal: return String(localized: "Word jumps, Home/End and Ctrl+Shift+C/V in terminals")
            case .karabiner: return String(localized: "Import the rules from Karabiner-Elements")
            case .empty: return String(localized: "Record your own shortcuts from scratch")
            }
        }

        var symbol: String {
            switch self {
            case .windows: return "pc"
            case .linux: return "terminal"
            case .terminal: return "apple.terminal"
            case .karabiner: return "square.and.arrow.down"
            case .empty: return "plus.square.dashed"
            }
        }
    }

    @ObservedObject private var model = AppModel.shared
    @State private var steps: [Step] = [.welcome, .permissions, .origin, .done]
    @State private var step: Step = .welcome
    @State private var origin: Origin = .windows
    @State private var importError: String?
    @State private var importSummary: String?
    @State private var importedShellCommands = 0
    /// Explicit choice to overwrite a config file that exists but has errors.
    @State private var replaceInvalidFile = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .origin:
                    // The error banner makes this step taller than the fixed window.
                    if model.configHasErrors { ScrollView { originPicker } } else { originPicker }
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 40)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.bar)
        }
        .frame(width: 620, height: 520)
        .onAppear(perform: planSteps)
        .alert(String(localized: "Import failed"), isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 16) {
            appIcon.frame(width: 96, height: 96)
            Text("Welcome to Keyshift").font(.largeTitle.weight(.semibold))
            Text("Make your Mac keyboard work the way you're used to — Ctrl+C to copy, Home and End, Alt+F4 and more.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            VStack(alignment: .leading, spacing: 10) {
                feature("checkmark.shield", String(localized: "Free and open source. No drivers, no account, no tracking."))
                feature("slider.horizontal.3", String(localized: "Change any shortcut later in Settings — no files to edit."))
                feature("pause.circle", String(localized: "Pause it anytime from the menu bar."))
            }
            .padding(.top, 8)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle(String(localized: "Allow Keyshift to see and change keys"),
                      String(localized: "macOS asks for two permissions. Turn on Keyshift in each list, then come back here — this page updates by itself."))
            VStack(spacing: 14) {
                PermissionRow(kind: .accessibility, granted: model.permissions.accessibility)
                Divider()
                PermissionRow(kind: .inputMonitoring, granted: model.permissions.inputMonitoring)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            Label {
                Text("Everything happens on your Mac. Keyshift never records, stores or sends your keystrokes.")
            } icon: {
                Image(systemName: "lock.shield").foregroundStyle(.green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if model.permissions.allGranted {
                Label(String(localized: "All set!"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            }
        }
    }

    private var originPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle(String(localized: "Where are you coming from?"),
                      String(localized: "Pick a starting point. You can change everything later or add more presets."))
            if model.configHasErrors {
                Banner(style: .error, title: String(localized: "Your config file has errors")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keyshift leaves it unchanged unless you choose to replace it. The current file is then kept as config.yaml.invalid.bak.")
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle(String(localized: "Replace my config file with this starting point"), isOn: $replaceInvalidFile)
                            .toggleStyle(.checkbox)
                            .foregroundStyle(.primary)
                    }
                } actions: {
                    Button(String(localized: "Open in Editor")) { model.openConfigInEditor() }
                }
            }
            VStack(spacing: 8) {
                ForEach(availableOrigins) { option in
                    OriginRow(option: option, selected: origin == option) { origin = option }
                }
            }
            .disabled(model.configHasErrors && !replaceInvalidFile)
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("You're all set").font(.largeTitle.weight(.semibold))
            if let importSummary {
                Text(importSummary).foregroundStyle(.secondary)
            }
            if importedShellCommands > 0 {
                Label(String(localized: "\(importedShellCommands) imported shortcuts run shell commands. Review them in Settings → Rules."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 12) {
                feature("keyboard", String(localized: "Keyshift lives in the menu bar. Click its icon to switch profiles or open Settings."))
                feature("pause.circle", String(localized: "To pause remapping, untick “Enabled” in the menu bar icon’s menu."))
                feature("exclamationmark.triangle", String(localized: "Settings points out shortcuts that overlap with another rule, and tells you when you override a macOS one."))
            }
            .frame(maxWidth: 460)
            .padding(.top, 8)
        }
    }

    // MARK: Footer & navigation

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Spacer()
            if step != steps.first && step != .done {
                Button(String(localized: "Back"), action: back)
            }
            switch step {
            case .done:
                Button(String(localized: "Open Settings")) {
                    WindowRouter.closeOnboarding()
                    WindowRouter.showSettings(.rules)
                }
                Button(String(localized: "Done")) { WindowRouter.closeOnboarding() }
                    .keyboardShortcut(.defaultAction)
            case .permissions:
                Button(model.permissions.allGranted ? String(localized: "Continue") : String(localized: "Later"), action: next)
                    .keyboardShortcut(.defaultAction)
            case .origin:
                Button(String(localized: "Continue"), action: applyOrigin)
                    .keyboardShortcut(.defaultAction)
            case .welcome:
                Button(String(localized: "Get Started"), action: next)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func planSteps() {
        var planned: [Step] = [.welcome]
        if !model.permissions.allGranted { planned.append(.permissions) }
        if !model.hasConfigFile || model.config.profiles.isEmpty { planned.append(.origin) }
        planned.append(.done)
        steps = planned
        step = .welcome
    }

    private func next() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        if steps[i + 1] == .permissions { model.requestPermissions() }
        step = steps[i + 1]
    }

    private func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        step = steps[i - 1]
    }

    private func applyOrigin() {
        // A file that exists but has errors is only replaced when the user ticked the box.
        if model.configHasErrors && !replaceInvalidFile {
            next()
            return
        }
        let replace = model.configHasErrors && replaceInvalidFile
        switch origin {
        case .windows, .linux, .terminal:
            if let id = origin.presetID { model.applyPreset(id, overridingErrors: replace) }
        case .karabiner:
            do {
                let report = try model.importKarabiner(overridingErrors: replace)
                importSummary = String(localized: "Imported \(report.importedCount) shortcuts from Karabiner-Elements (\(report.skippedCount) skipped).")
                importedShellCommands = report.shellCommands.count
            } catch {
                importError = error.localizedDescription
                return
            }
        case .empty:
            model.update(overridingErrors: replace) { config in
                config.editActiveProfile { _ in }
            }
        }
        next()
    }

    private var availableOrigins: [Origin] {
        let presetIDs = Set(Presets.all().map(\.id))
        let hasKarabiner = FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/karabiner/karabiner.json").path)
        return Origin.allCases.filter { option in
            if let id = option.presetID { return presetIDs.contains(id) }
            if option == .karabiner { return hasKarabiner }
            return true
        }
    }

    // MARK: Pieces

    private var appIcon: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "keyboard").resizable().scaledToFit()
            }
        }
    }

    private func stepTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OriginRow: View {
    let option: OnboardingView.Origin
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: option.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(.headline)
                    Text(option.detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
