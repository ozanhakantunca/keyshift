import SwiftUI

/// Live table of what the engine did with each key. Only collects while visible.
struct EventViewerView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var frozen: [EventLogEntry]?

    private var rows: [EventLogEntry] { frozen ?? model.recentEvents }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Press keys to see what Keyshift does with them.").font(.callout)
                    Text("Useful to check why a shortcut does or doesn't change. Nothing is saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: Binding(
                    get: { frozen != nil },
                    set: { frozen = $0 ? model.recentEvents : nil }
                )) {
                    Label(String(localized: "Pause"), systemImage: "pause.fill")
                }
                .toggleStyle(.button)
                Button {
                    model.clearEventLog()
                    if frozen != nil { frozen = [] }
                } label: {
                    Label(String(localized: "Clear"), systemImage: "trash")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if !model.engineRunning {
                Banner(style: .warning, title: String(localized: "The remapping engine is not running")) {
                    Text(model.isEnabled
                         ? String(localized: "Grant the permissions above; events appear once it starts.")
                         : String(localized: "Keyshift is paused. Turn it on to see events."))
                } actions: {
                    if !model.isEnabled {
                        Button(String(localized: "Resume")) { model.isEnabled = true }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Divider()

            if rows.isEmpty {
                EmptyStateView(
                    symbol: "keyboard.badge.ellipsis",
                    title: String(localized: "Waiting for keys"),
                    message: String(localized: "Type anywhere — in this window or another app — and events show up here.")
                )
            } else {
                Table(rows) {
                    TableColumn(String(localized: "Time")) { entry in
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 80, max: 100)
                    TableColumn(String(localized: "You pressed")) { entry in
                        Text(entry.input).font(.system(.body, design: .rounded).weight(.medium))
                    }
                    TableColumn(String(localized: "Result")) { entry in
                        Text(entry.output)
                            .foregroundStyle(entry.ruleName == nil ? .secondary : .primary)
                    }
                    TableColumn(String(localized: "Rule")) { entry in
                        Text(entry.ruleName ?? "—").foregroundStyle(entry.ruleName == nil ? .tertiary : .primary)
                    }
                    TableColumn(String(localized: "App")) { entry in
                        if let app = entry.app {
                            HStack(spacing: 5) {
                                AppIconView(entry: app, size: 14)
                                Text(model.appDisplayName(for: app)).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { model.eventViewerActive = true }
        .onDisappear { model.eventViewerActive = false }
    }
}
