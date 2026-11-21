import KeyshiftCore
import SwiftUI

struct GeneralView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var tapTimeout: Double?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remap keys")
                        Text("Turn off to use your keyboard as normal. You can also pause from the menu bar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(String(localized: "Open Keyshift at login"), isOn: setting(\.launchAtLogin))
                Toggle(isOn: setting(\.showMenuBarIcon)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show icon in the menu bar")
                        if !model.config.settings.showMenuBarIcon {
                            Text("To get back here, open Keyshift again from your Applications folder.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tap time limit")
                        Spacer()
                        Text("\(Int(currentTapTimeout)) ms").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { currentTapTimeout }, set: { tapTimeout = ($0 / 10).rounded() * 10 }),
                           in: 150...1000) { editing in
                        if !editing, let value = tapTimeout {
                            model.update { $0.settings.tapTimeoutMs = Int(value) }
                            tapTimeout = nil
                        }
                    }
                    Text("For “tapped alone” shortcuts: a key held longer than this counts as held, not tapped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Timing")
            }

            Section {
                LabeledContent(String(localized: "Config file")) {
                    Text(model.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button(String(localized: "Open in Editor")) { model.openConfigInEditor() }
                    Button(String(localized: "Show in Finder")) { model.revealConfigInFinder() }
                    Spacer()
                }
                Text("Prefer text? Edit the YAML file directly — Keyshift reloads it as soon as you save.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Configuration")
            }

            Section {
                PermissionRow(kind: .accessibility, granted: model.permissions.accessibility)
                PermissionRow(kind: .inputMonitoring, granted: model.permissions.inputMonitoring)
            } header: {
                Text("Permissions")
            }

            if model.karabinerRunning {
                Section {
                    Label {
                        Text("Karabiner-Elements is running. Quit it (or turn off its rules) so keys aren't remapped twice.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var currentTapTimeout: Double { tapTimeout ?? Double(model.config.settings.tapTimeoutMs) }

    private func setting(_ keyPath: WritableKeyPath<KeyshiftCore.Settings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.config.settings[keyPath: keyPath] },
            set: { value in model.update { $0.settings[keyPath: keyPath] = value } }
        )
    }
}
