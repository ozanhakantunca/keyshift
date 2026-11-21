import AppKit
import KeyshiftCore
import SwiftUI
import UniformTypeIdentifiers

/// Icon for a bundle id, app name, path or path fragment; falls back to a generic symbol.
struct AppIconView: View {
    @ObservedObject private var model = AppModel.shared
    let entry: String
    var size: CGFloat = 16

    var body: some View {
        if let icon = model.appIcon(for: entry) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: AppScope.isPathFragment(entry) ? "folder" : "app.dashed")
                .resizable().scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: size * 0.85, height: size * 0.85)
                .frame(width: size, height: size)
        }
    }
}

/// Display data for one entry of a rule scope (group, path fragment or app).
@MainActor
struct ScopeEntryInfo {
    let name: String
    let isGroup: Bool
    let isPath: Bool

    init(_ entry: String, model: AppModel) {
        if let group = model.config.groupName(for: entry) {
            name = ScopeEntryInfo.groupTitle(group)
            isGroup = true
            isPath = false
        } else if AppScope.isPathFragment(entry) {
            name = entry
            isGroup = false
            isPath = true
        } else {
            name = model.appDisplayName(for: entry)
            isGroup = false
            isPath = false
        }
    }

    /// "remote_desktop" → "Remote Desktop".
    static func groupTitle(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
}

struct ScopeEntryChip: View {
    @ObservedObject private var model = AppModel.shared
    let entry: String
    var onRemove: (() -> Void)?

    var body: some View {
        let info = ScopeEntryInfo(entry, model: model)
        HStack(spacing: 4) {
            if info.isGroup {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.accentColor)
            } else {
                AppIconView(entry: entry, size: 14)
            }
            Text(info.name).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove \(info.name)"))
            }
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .help(info.isGroup ? groupHelp(info) : entry)
    }

    private func groupHelp(_ info: ScopeEntryInfo) -> String {
        let name = model.config.groupName(for: entry) ?? entry
        let apps = (model.config.appGroups[name] ?? []).map { model.appDisplayName(for: $0) }
        return apps.joined(separator: ", ")
    }
}

/// "Everywhere" / "Only in [Finder]" / "Except [Terminals]".
struct ScopeSummary: View {
    let scope: AppScope
    var maxChips = 3

    var body: some View {
        HStack(spacing: 5) {
            switch scope.kind {
            case .everywhere:
                Chip(String(localized: "Everywhere"), symbol: "globe")
            case .only, .except:
                Text(scope.kind == .only ? String(localized: "Only in") : String(localized: "Except in"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if scope.apps.isEmpty {
                    Chip(String(localized: "no apps"), symbol: "exclamationmark.triangle", tint: .orange)
                }
                ForEach(scope.apps.prefix(maxChips), id: \.self) { ScopeEntryChip(entry: $0) }
                if scope.apps.count > maxChips {
                    Text("+\(scope.apps.count - maxChips)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PickableApp: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: NSImage?
}

/// Menu: app groups, running apps, "Choose app…". Calls `onPick` with a group name or bundle id.
struct AppPickerMenu<MenuLabel: View>: View {
    @ObservedObject private var model = AppModel.shared
    var includeGroups = true
    var excluded: Set<String> = []
    let onPick: (String) -> Void
    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        Menu {
            let groups = model.config.appGroups.keys.sorted().filter { !excluded.contains($0) }
            if includeGroups && !groups.isEmpty {
                Section(String(localized: "App groups")) {
                    ForEach(groups, id: \.self) { group in
                        Button { onPick(group) } label: {
                            Label(ScopeEntryInfo.groupTitle(group), systemImage: "square.stack.3d.up")
                        }
                    }
                }
            }
            Section(String(localized: "Running apps")) {
                ForEach(runningApps.filter { !excluded.contains($0.id) }) { app in
                    Button { onPick(app.id) } label: {
                        if let icon = app.icon {
                            Label { Text(app.name) } icon: { Image(nsImage: icon.menuSized) }
                        } else {
                            Text(app.name)
                        }
                    }
                }
            }
            Divider()
            Button(String(localized: "Choose app…")) {
                if let id = AppChooser.chooseApp() { onPick(id) }
            }
        } label: {
            label()
        }
        .fixedSize()
    }

    private var runningApps: [PickableApp] {
        model.runningApps().map { PickableApp(id: $0.id, name: $0.name, icon: $0.icon) }
    }
}

@MainActor
enum AppChooser {
    /// Open panel on /Applications; returns the bundle id, or the path when the app has none.
    static func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an app")
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier ?? url.path
    }

    static func chooseFile(title: String, startingAt directory: URL?, types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.directoryURL = directory
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension NSImage {
    /// A 16 pt copy for menu items (menus otherwise draw the full-size icon).
    var menuSized: NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            return true
        }
        return image
    }
}
