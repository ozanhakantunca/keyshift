import KeyshiftCore
import SwiftUI

extension SettingsSection {
    var title: String {
        switch self {
        case .rules: return String(localized: "Rules")
        case .presets: return String(localized: "Presets")
        case .apps: return String(localized: "App Groups")
        case .conflicts: return String(localized: "Conflicts")
        case .events: return String(localized: "Event Viewer")
        case .general: return String(localized: "General")
        case .about: return String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .rules: return "keyboard"
        case .presets: return "square.grid.2x2"
        case .apps: return "square.stack.3d.up"
        case .conflicts: return "exclamationmark.triangle"
        case .events: return "list.bullet.rectangle"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject private var model = AppModel.shared
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.section) {
                Section {
                    row(.rules)
                    row(.presets)
                    row(.apps)
                }
                Section {
                    row(.conflicts)
                        .badge(model.ruleConflicts.count)
                    row(.events)
                }
                Section {
                    row(.general)
                    row(.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) { EngineStatusFooter() }
        } detail: {
            VStack(spacing: 0) {
                GlobalBanners()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle((navigation.section ?? .rules).title)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func row(_ section: SettingsSection) -> some View {
        Label(section.title, systemImage: section.symbol).tag(section)
    }

    @ViewBuilder private var detail: some View {
        switch navigation.section ?? .rules {
        case .rules: RulesView()
        case .presets: PresetsView()
        case .apps: AppGroupsView()
        case .conflicts: ConflictsView()
        case .events: EventViewerView()
        case .general: GeneralView()
        case .about: AboutView()
        }
    }
}

/// On/off switch at the bottom of the sidebar.
private struct EngineStatusFooter: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Toggle(String(localized: "Enabled"), isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(Text("Turn all remapping on or off"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        if !model.isEnabled { return .gray }
        return model.engineRunning ? .green : .orange
    }

    private var statusText: String {
        if !model.isEnabled { return String(localized: "Paused") }
        return model.engineRunning ? String(localized: "Running") : String(localized: "Not running")
    }
}

/// Centered placeholder for empty lists.
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            actions().padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// Section header used inside scrolling pages.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
