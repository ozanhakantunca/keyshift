import KeyshiftConfig
import KeyshiftSystem
import SwiftUI

/// Tinted callout with an icon, text and optional buttons.
struct Banner<Content: View, Actions: View>: View {
    enum Style {
        case warning, error, info

        var tint: Color {
            switch self {
            case .warning: return .orange
            case .error: return .red
            case .info: return .accentColor
            }
        }

        var symbol: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    let style: Style
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.tint)
                .font(.system(size: 15))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                content()
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: 6) { actions() }
                .controlSize(.small)
                .fixedSize()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style.tint.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style.tint.opacity(0.25))
        )
    }
}

/// Banners shown above every settings page when something needs attention.
struct GlobalBanners: View {
    @ObservedObject private var model = AppModel.shared
    @State private var showDiagnostics = false

    var body: some View {
        let banners = VStack(spacing: 8) {
            if !model.permissions.allGranted {
                PermissionsBanner()
            }
            if model.karabinerRunning {
                Banner(style: .warning, title: String(localized: "Karabiner-Elements is running")) {
                    Text("Quit it (or turn off its rules) to avoid keys being remapped twice.")
                } actions: { EmptyView() }
            }
            if !model.isEnabled {
                Banner(style: .info, title: String(localized: "Keyshift is paused")) {
                    Text("All keys work as usual until you turn it back on.")
                } actions: {
                    Button(String(localized: "Resume")) { model.isEnabled = true }
                }
            } else if let error = model.lastStartError, model.permissions.allGranted {
                Banner(style: .error, title: String(localized: "Remapping could not start")) {
                    Text(error)
                } actions: { EmptyView() }
            }
            if !model.diagnostics.isEmpty {
                diagnosticsBanner
            }
        }
        if needsBanners {
            banners
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
        }
    }

    private var needsBanners: Bool {
        !model.permissions.allGranted || model.karabinerRunning || !model.isEnabled
            || model.lastStartError != nil || !model.diagnostics.isEmpty
    }

    private var diagnosticsBanner: some View {
        let errors = model.diagnostics.filter { $0.severity == .error }.count
        let title = errors > 0
            ? String(localized: "\(model.diagnostics.count) problems in the config file")
            : String(localized: "\(model.diagnostics.count) warnings in the config file")
        return Banner(style: errors > 0 ? .error : .warning, title: title) {
            VStack(alignment: .leading, spacing: 4) {
                Text("The rest of the file loaded normally; the lines below were skipped.")
                DisclosureGroup(isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            DiagnosticRow(diagnostic: diagnostic)
                        }
                    }
                    .padding(.top, 4)
                    .textSelection(.enabled)
                } label: {
                    Text(showDiagnostics ? String(localized: "Hide details") : String(localized: "Show details"))
                }
            }
        } actions: {
            Button(String(localized: "Open in Editor")) { model.openConfigInEditor() }
        }
    }
}

struct DiagnosticRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: diagnostic.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.orange)
                .font(.caption)
            if let line = diagnostic.line {
                Text("Line \(line)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
            }
            Text(diagnostic.message).font(.caption)
        }
    }
}

private struct PermissionsBanner: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Banner(style: .warning, title: String(localized: "Keyshift needs permission to remap keys")) {
            Text("Turn Keyshift on in System Settings → Privacy & Security. Nothing leaves your Mac.")
        } actions: {
            if !model.permissions.accessibility {
                Button(String(localized: "Accessibility…")) { model.openPermissionSettings(.accessibility) }
            }
            if !model.permissions.inputMonitoring {
                Button(String(localized: "Input Monitoring…")) { model.openPermissionSettings(.inputMonitoring) }
            }
        }
    }
}

/// Permission status row with live check mark, used in General and onboarding.
struct PermissionRow: View {
    @ObservedObject private var model = AppModel.shared
    let kind: Permissions.Kind
    let granted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if granted {
                    Text("Allowed").foregroundStyle(.green).font(.callout.weight(.medium))
                } else {
                    Button(String(localized: "Open System Settings")) {
                        model.requestPermissions()
                        model.openPermissionSettings(kind)
                    }
                }
            }
            .fixedSize()
        }
    }

    private var title: String {
        switch kind {
        case .accessibility: return String(localized: "Accessibility")
        case .inputMonitoring: return String(localized: "Input Monitoring")
        }
    }

    private var detail: String {
        switch kind {
        case .accessibility:
            return String(localized: "Lets Keyshift change the keys you press and send the new ones.")
        case .inputMonitoring:
            return String(localized: "Lets Keyshift see which keys you press. Keystrokes are handled on your Mac and never stored or sent anywhere.")
        }
    }
}
