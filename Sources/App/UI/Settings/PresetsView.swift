import Foundation
import KeyshiftConfig
import SwiftUI
import UniformTypeIdentifiers

/// Gallery of presets plus the Karabiner-Elements importer.
struct PresetsView: View {
    @ObservedObject private var model = AppModel.shared
    @EnvironmentObject private var navigation: SettingsNavigation
    @State private var report: ImportReport?
    @State private var importError: String?

    /// Most common starting points first.
    private let presets: [PresetInfo] = {
        let order = ["windows", "linux", "terminal"]
        return Presets.all().sorted { a, b in
            (order.firstIndex(of: a.id) ?? order.count, a.name) < (order.firstIndex(of: b.id) ?? order.count, b.name)
        }
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: String(localized: "Start from a preset"),
                    subtitle: String(localized: "Each preset is added as a new profile you can change freely. Your existing profiles stay as they are.")
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    ForEach(presets) { preset in
                        PresetCard(preset: preset) {
                            model.applyPreset(preset.id)
                            navigation.section = .rules
                        }
                    }
                    KarabinerCard(onImport: runImport)
                }
                if presets.isEmpty {
                    Text("No presets were found in this build.").foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            if let report {
                ImportReportSheet(report: report) {
                    self.report = nil
                    navigation.section = .rules
                }
            }
        }
        .alert(String(localized: "Import failed"), isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func runImport(_ url: URL?) {
        do {
            report = try model.importKarabiner(from: url)
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct PresetCard: View {
    @ObservedObject private var model = AppModel.shared
    let preset: PresetInfo
    let onAdd: () -> Void

    /// Bundled presets never change while the app runs; decode each once, not on every render.
    @MainActor private static var counts: [String: Int] = [:]

    private var count: Int {
        if let count = Self.counts[preset.id] { return count }
        let count = Presets.load(preset.id)?.0.rules.reduce(0) { $0 + $1.mappings.count } ?? 0
        Self.counts[preset.id] = count
        return count
    }

    var body: some View {
        let text = UIText.splitPresetDescription(preset)
        let count = self.count
        let inUse = model.config.profiles.contains { $0.name == preset.name }
        GalleryCard(symbol: UIText.presetSymbol(preset.id), tint: .accentColor) {
            Text(text.title).font(.headline)
            if !text.detail.isEmpty {
                Text(text.detail).font(.callout).foregroundStyle(.secondary)
            }
        } footer: {
            Text("\(count) shortcuts").font(.caption).foregroundStyle(.secondary)
            if inUse {
                Text("· already added").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(inUse ? String(localized: "Add Again") : String(localized: "Add as Profile"), action: onAdd)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

private struct KarabinerCard: View {
    let onImport: (URL?) -> Void

    private var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner/karabiner.json")
    }

    var body: some View {
        let hasDefault = FileManager.default.fileExists(atPath: defaultFile.path)
        GalleryCard(symbol: "square.and.arrow.down", tint: .orange) {
            Text("Import from Karabiner-Elements").font(.headline)
            Text("Brings over your simple and complex modifications as new profiles. Anything Keyshift can't do is listed after the import.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } footer: {
            Button(String(localized: "Choose File…")) {
                if let url = AppChooser.chooseFile(
                    title: String(localized: "Choose karabiner.json"),
                    startingAt: defaultFile.deletingLastPathComponent(),
                    types: [.json]
                ) { onImport(url) }
            }
            .controlSize(.small)
            Spacer()
            Button(String(localized: "Import")) { onImport(nil) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasDefault)
                .help(hasDefault ? Text(defaultFile.path) : Text("No karabiner.json found in ~/.config/karabiner"))
        }
    }
}

/// Card with an icon tile, body text and a footer row.
struct GalleryCard<Content: View, Footer: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 4) { content() }
            Spacer(minLength: 0)
            HStack(spacing: 6) { footer() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Summary after a Karabiner import.
struct ImportReportSheet: View {
    let report: ImportReport
    let onDone: () -> Void
    @State private var showWarnings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: report.importedCount > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(report.importedCount > 0 ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Karabiner import finished").font(.title3.weight(.semibold))
                    Text("\(report.importedCount) imported · \(report.skippedCount) skipped")
                        .foregroundStyle(.secondary)
                }
            }
            if !report.shellCommands.isEmpty {
                Banner(style: .warning, title: report.shellCommands.count == 1
                    ? String(localized: "1 imported shortcut runs a shell command")
                    : String(localized: "\(report.shellCommands.count) imported shortcuts run shell commands")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("They are active now. Check that you trust each command, or delete the shortcut in Rules.")
                        ScrollView {
                            Text(report.shellCommands.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                } actions: { EmptyView() }
            }
            if !report.skippedByReason.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skipped because").font(.headline)
                    ForEach(report.skippedByReason.sorted { $0.value > $1.value }, id: \.key) { reason, count in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(count)×").monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                            Text(reason).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
            }
            if !report.warnings.isEmpty {
                DisclosureGroup(isExpanded: $showWarnings) {
                    ScrollView {
                        Text(report.warnings.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                } label: {
                    Text("Details (\(report.warnings.count))")
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(String(localized: "Show Rules"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .frame(minHeight: 260)
    }
}
