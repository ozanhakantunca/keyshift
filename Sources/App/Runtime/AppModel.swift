import AppKit
import Combine
import KeyshiftConfig
import KeyshiftCore
import KeyshiftSystem
import UniformTypeIdentifiers

/// One row in the live event viewer.
struct EventLogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let input: String          // e.g. "⌃C down"
    let output: String         // e.g. "⌘C" / "passed" / "open Ghostty"
    let ruleName: String?
    let app: String?           // frontmost bundle id
}

struct PermissionState: Hashable {
    var accessibility = false
    var inputMonitoring = false
    var allGranted: Bool { accessibility && inputMonitoring }
}

/// Single source of truth shared by the menu bar, settings window, onboarding and CLI server.
///
/// CONTRACT between the runtime layer (`Sources/App/Runtime`, owns the implementation) and the
/// UI layer (`Sources/App/UI`, only consumes this API). Do not change signatures without the lead.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: State (read by UI)
    @Published private(set) var config = Config()
    @Published private(set) var diagnostics: [Diagnostic] = []
    /// Conflicts for the active profile (rules vs rules and vs macOS shortcuts).
    @Published private(set) var conflicts: [Conflict] = []
    /// Only real rule-vs-rule conflicts (not intentional macOS shortcut overrides).
    var ruleConflicts: [Conflict] { conflicts.filter { $0.kind.isRuleConflict } }
    /// False until a config file exists (first launch → onboarding offers presets / Karabiner import).
    @Published private(set) var hasConfigFile = false
    /// User-facing on/off switch (menu bar). Off = backend paused, everything passes through.
    @Published var isEnabled = true {
        didSet {
            if oldValue != isEnabled { applyPauseState() }
        }
    }
    @Published private(set) var engineRunning = false
    @Published private(set) var lastStartError: String?
    @Published private(set) var permissions = PermissionState()
    @Published private(set) var karabinerRunning = false
    /// Filled only while `eventViewerActive` is true; newest first, capped (~200).
    @Published private(set) var recentEvents: [EventLogEntry] = []
    @Published var eventViewerActive = false {
        didSet {
            if oldValue != eventViewerActive { updateEventViewer() }
        }
    }
    /// Enabled macOS symbolic hotkeys, for conflict hints in the UI.
    private(set) var systemShortcuts: [KeyCombo: String] = [:]

    var configURL: URL { store.url }
    var activeProfile: Profile? { config.activeProfile }

    private let store: ConfigStore
    private lazy var context = ContextProvider()
    private let modifierRemapper = ModifierRemapper()
    private lazy var backend = EventTapBackend(engine: Engine(), context: context, executor: ActionExecutor())
    private var permissionObservation: Permissions.Observation?
    private var layoutObservation: NSObjectProtocol?
    private var statusPoll: DispatchSourceTimer?
    private var started = false
    private var recording = false
    private var plan = ModifierRemapper.plan(for: Config())
    private var configDiagnostics: [Diagnostic] = []
    private var fileDiagnostic: Diagnostic?
    private var hidDiagnostic: Diagnostic?
    private var ruleNames: [UUID: String] = [:]

    init(store: ConfigStore = ConfigStore()) {
        self.store = store
    }

    // MARK: Lifecycle
    /// Called once from AppDelegate: load config, start watching, observe permissions,
    /// start the backend when permitted.
    func start() {
        guard !started else { return }
        started = true
        permissions = readPermissions()
        karabinerRunning = KarabinerDetector.isRunning()
        backend.setKeyLayout(KeyboardLayout.currentMap())
        layoutObservation = DistributedNotificationCenter.default().addObserver(
            forName: KeyboardLayout.changeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.backend.setKeyLayout(KeyboardLayout.currentMap()) }
        store.startWatching { [weak self] _, _ in
            // Read the latest snapshot so a queued callback cannot undo a more recent reload.
            self?.reloadFromDisk()
        }
        reloadFromDisk()
        updateEventViewer()

        permissionObservation = Permissions.observeGrants { [weak self] _ in
            self?.refreshPermissions()
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(4), repeating: .seconds(4), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            let running = KarabinerDetector.isRunning()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started else { return }
                if self.karabinerRunning != running { self.karabinerRunning = running }
                self.refreshPermissions()
            }
        }
        timer.resume()
        statusPoll = timer
    }

    func stop() {
        guard started else { return }
        started = false
        store.stopWatching()
        permissionObservation?.cancel()
        permissionObservation = nil
        statusPoll?.cancel()
        statusPoll = nil
        backend.onEvent = nil
        backend.stop()
        if engineRunning { engineRunning = false }
        updateHIDMappings()
    }

    func reloadFromDisk() {
        let loaded = store.load()
        install(loaded?.0 ?? Config(), diagnostics: loaded?.1 ?? [], hasFile: loaded != nil)
    }

    func prepareCLIEdit() throws {
        reloadFromDisk()
        guard !ConfigEdits.hasErrors(configDiagnostics) else { throw ConfigEditError.invalidConfig(configURL) }
    }

    private func install(_ next: Config, diagnostics: [Diagnostic], hasFile: Bool) {
        configDiagnostics = diagnostics
        fileDiagnostic = nil
        systemShortcuts = SystemShortcuts.enabled()
        conflicts = ConfigEdits.conflicts(in: next, shortcuts: systemShortcuts)
        hasConfigFile = hasFile
        config = next
        var names: [UUID: String] = [:]
        for rule in next.activeProfile?.rules ?? [] { names[rule.id] = rule.name }
        ruleNames = names
        plan = ModifierRemapper.plan(for: next)
        if started {
            backend.reload(plan.eventTapConfig)
            reconcileBackend(reapplyHID: true)
        }
        publishDiagnostics()
    }

    private func readPermissions() -> PermissionState {
        PermissionState(accessibility: Permissions.accessibility(), inputMonitoring: Permissions.inputMonitoring())
    }

    private func refreshPermissions() {
        let current = readPermissions()
        if current != permissions { permissions = current }
        reconcileBackend()
    }

    private func reconcileBackend(reapplyHID: Bool = false) {
        guard started else { return }
        if hasConfigFile && permissions.accessibility {
            if !backend.isRunning {
                backend.setPaused(!isEnabled || recording)
                do {
                    try backend.start()
                    lastStartError = nil
                } catch {
                    if lastStartError != error.localizedDescription { lastStartError = error.localizedDescription }
                }
            }
        } else {
            backend.stop()
            if lastStartError != nil { lastStartError = nil }
        }
        let running = backend.isRunning
        if engineRunning != running { engineRunning = running }
        updateHIDMappings(reapply: reapplyHID)
    }

    private func applyPauseState() {
        guard started else { return }
        backend.setPaused(!isEnabled || recording)
        updateHIDMappings()
    }

    private func updateHIDMappings(reapply: Bool = false) {
        let active = engineRunning && isEnabled && !recording
        let success = active ? modifierRemapper.apply(plan.remaps, reapply: reapply) : modifierRemapper.restore()
        let next = success ? nil : Diagnostic(
            message: active && !plan.remaps.isEmpty
                ? "macOS could not apply modifier remaps. Check Input Monitoring permissions."
                : "macOS could not restore the previous keyboard mappings.",
            severity: .warning
        )
        if hidDiagnostic != next {
            hidDiagnostic = next
            publishDiagnostics()
        }
    }

    private func publishDiagnostics() {
        let next = configDiagnostics + [fileDiagnostic, hidDiagnostic].compactMap { $0 }
        if diagnostics != next { diagnostics = next }
    }

    // MARK: Editing (UI calls these; each saves the file and hot-reloads the engine)
    /// Apply any change to the config. Saves (with .bak), recomputes diagnostics/conflicts, reloads engine.
    func update(_ mutate: (inout Config) -> Void) {
        reportFileError { try saveUpdate(mutate) }
    }

    func saveUpdate(_ mutate: (inout Config) throws -> Void) throws {
        var next = config
        try mutate(&next)
        try store.save(next)
        install(next, diagnostics: ConfigCodec.decode(ConfigCodec.encode(next)).1, hasFile: true)
    }

    private func reportFileError(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            fileDiagnostic = Diagnostic(message: error.localizedDescription)
            publishDiagnostics()
        }
    }

    func selectProfile(_ name: String) {
        reportFileError { try switchProfile(name) }
    }

    func switchProfile(_ name: String) throws {
        if hasConfigFile && config.selectedProfile == name && activeProfile?.name == name { return }
        try saveUpdate { try ConfigEdits.select(name, in: &$0) }
    }

    /// Adds the preset as a new profile (unique name) and merges its app groups; selects it.
    func applyPreset(_ id: String) {
        guard let (profile, groups) = Presets.load(id) else { return }
        let preset = Config(appGroups: groups, profiles: [profile])
        update { ConfigEdits.append(preset, to: &$0, selectIncoming: true) }
    }

    /// Imports karabiner.json (default ~/.config/karabiner/karabiner.json); adds its profiles, merges groups.
    func importKarabiner(from url: URL? = nil) throws -> ImportReport {
        let (incoming, report) = try KarabinerImporter.importFile(at: url ?? ConfigEdits.defaultKarabinerURL)
        if !incoming.profiles.isEmpty {
            try saveUpdate { ConfigEdits.append(incoming, to: &$0) }
        }
        return report
    }

    func runSelfTestSuite() throws -> [SelfTestSuite.Row] {
        guard !recording else { throw ConfigEditError.recording }
        guard isEnabled else { throw ConfigEditError.remappingDisabled }
        return SelfTestSuite.run(backend: backend, context: context)
    }

    func runSelfTest() throws -> SelfTest.Result {
        guard !recording else { throw ConfigEditError.recording }
        guard engineRunning else { return SelfTest.run(backend: backend) }

        let input = KeyCombo(KeyCode(8), .control)
        let expected = KeyCombo(KeyCode(8), .command)
        let mapping = Mapping(trigger: .key(input), action: .keys([expected]))
        let probe = Profile(name: "Probe", rules: [Rule(name: "Self-test", passthrough: [], mappings: [mapping])])
        backend.reload(Config(profiles: [probe]), applyingLayout: false)
        backend.setPaused(false)
        defer {
            backend.setPaused(!isEnabled || recording)
            backend.reload(plan.eventTapConfig)
        }
        return SelfTest.run(backend: backend, input: input, expected: expected)
    }

    // MARK: Helpers for the UI
    /// While true the event tap passes everything through so the key recorder sees raw keys.
    func setRecording(_ recording: Bool) {
        guard self.recording != recording else { return }
        self.recording = recording
        applyPauseState()
    }

    func requestPermissions() {
        if !permissions.accessibility { Permissions.accessibility(prompt: true) }
        if !permissions.inputMonitoring { Permissions.inputMonitoring(prompt: true) }
        refreshPermissions()
    }

    func openPermissionSettings(_ kind: Permissions.Kind) {
        Permissions.openSettings(for: kind)
    }

    func openConfigInEditor() {
        reportFileError {
            if store.load() == nil { try saveUpdate { _ in } }
            let workspace = NSWorkspace.shared
            if let editor = workspace.urlForApplication(toOpen: UTType.plainText) {
                workspace.open([configURL], withApplicationAt: editor, configuration: .init()) { [weak self] _, error in
                    guard let error else { return }
                    DispatchQueue.main.async { [weak self] in
                        self?.reportFileError { throw error }
                    }
                }
            } else if !workspace.open(configURL) {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Could not open the config file in an editor."])
            }
        }
    }

    func revealConfigInFinder() {
        let directory = configURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: configURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([configURL])
        } else if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.open(directory)
        }
    }

    func clearEventLog() { recentEvents.removeAll() }

    private func updateEventViewer() {
        guard started else { return }
        if eventViewerActive {
            backend.onEvent = { [weak self] input, decision in self?.logEvent(input, decision: decision) }
        } else {
            backend.onEvent = nil
        }
    }

    private func logEvent(_ input: InputEvent, decision: Decision) {
        guard started, eventViewerActive else { return }
        let name = decision.matched.flatMap { ruleNames[$0.rule] }
        let row = EventLogEntry(date: .now, input: EventDescription.input(input),
                                output: EventDescription.decision(decision), ruleName: name,
                                app: context.frontmostBundleID)
        var events = recentEvents
        events.insert(row, at: 0)
        if events.count > 200 { events.removeLast() }
        recentEvents = events
    }

    /// Pretty name for a bundle id or path fragment ("com.apple.finder" → "Finder").
    func appDisplayName(for entry: String) -> String {
        if let running = runningApp(matching: entry), let name = running.localizedName { return name }
        if let url = appURL(for: entry) {
            let bundle = Bundle(url: url)
            return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? FileManager.default.displayName(atPath: url.path)
        }
        if AppScope.isPathFragment(entry),
           let bundle = entry.split(separator: "/").last(where: { $0.lowercased().hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }
        return entry
    }

    func appIcon(for entry: String) -> NSImage? {
        if let icon = runningApp(matching: entry)?.icon { return icon }
        return appURL(for: entry).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Running regular apps (for the app picker), sorted by name: (bundleID, name, icon).
    func runningApps() -> [(id: String, name: String, icon: NSImage?)] {
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  seen.insert(id.lowercased()).inserted else { return nil }
            let name = app.localizedName ?? id
            return (id: id, name: name, icon: app.icon)
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    private func runningApp(matching entry: String) -> NSRunningApplication? {
        if AppScope.isPathFragment(entry) {
            let path = (entry as NSString).expandingTildeInPath
            return NSWorkspace.shared.runningApplications.first {
                $0.bundleURL?.path.localizedCaseInsensitiveContains(path) == true
            }
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: entry).first
            ?? NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier?.caseInsensitiveCompare(entry) == .orderedSame
                    || $0.localizedName?.caseInsensitiveCompare(entry) == .orderedSame
            }
    }

    private func appURL(for entry: String) -> URL? {
        if AppScope.isPathFragment(entry) {
            let path = (entry as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry)
    }
}
