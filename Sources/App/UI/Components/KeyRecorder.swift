import AppKit
import Combine
import KeyshiftCore
import SwiftUI

/// Records one key combo through a local NSEvent monitor. While recording, the event tap is put in
/// pass-through mode (`AppModel.setRecording`) so the recorder sees the raw, un-remapped keys.
///
/// Rules: a key with any held modifiers is recorded on key down. A modifier key pressed and
/// released on its own records that bare key (e.g. Left ⌘). Caps Lock records immediately.
/// Esc without modifiers cancels.
@MainActor
final class KeyRecorder: ObservableObject {
    static let shared = KeyRecorder()

    @Published private(set) var owner: UUID?
    @Published private(set) var liveModifiers: Modifiers = []

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var onRecord: ((KeyCombo) -> Void)?
    private var heldModifierKeys: Set<UInt16> = []
    private var aloneCandidate: UInt16?
    private var functionHeld = false

    private init() {}

    func begin(owner: UUID, onRecord: @escaping (KeyCombo) -> Void) {
        cancel()
        // Synchronously, before the next key event reaches the tap.
        AppModel.shared.setRecording(true)
        self.owner = owner
        self.onRecord = onRecord
        heldModifierKeys = []
        aloneCandidate = nil
        functionHeld = NSEvent.modifierFlags.contains(.function)
        liveModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
    }

    /// Stops recording. With `owner`, only if that recorder is the active one.
    func cancel(owner: UUID? = nil) {
        if let owner, self.owner != owner { return }
        let wasRecording = self.owner != nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        onRecord = nil
        self.owner = nil
        liveModifiers = []
        if wasRecording { AppModel.shared.setRecording(false) }
    }

    private func finish(_ combo: KeyCombo) {
        let callback = onRecord
        cancel()
        callback?(combo)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard owner != nil else { return false }
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            guard !event.isARepeat else { return true }
            aloneCandidate = nil
            let modifiers = Self.modifiers(from: event.modifierFlags, functionHeld: functionHeld)
            if event.keyCode == 53 && modifiers.isEmpty {
                cancel()
            } else {
                finish(KeyCombo(KeyCode(event.keyCode), modifiers))
            }
        default:
            break
        }
        return true
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let code = event.keyCode
        let flags = event.modifierFlags
        if code == 57 { // Caps Lock reports a flag change only when its state toggles.
            finish(KeyCombo(KeyCode(57), Self.modifiers(from: flags, functionHeld: functionHeld)))
            return
        }
        let isDown = Self.isDown(code, flags: flags)
        if code == 63 { functionHeld = isDown }
        if isDown {
            heldModifierKeys.insert(code)
            aloneCandidate = heldModifierKeys.count == 1 ? code : nil
        } else {
            heldModifierKeys.remove(code)
            if aloneCandidate == code && heldModifierKeys.isEmpty {
                finish(KeyCombo(KeyCode(code), []))
                return
            }
            if heldModifierKeys.isEmpty { aloneCandidate = nil }
        }
        liveModifiers = Self.modifiers(from: flags, functionHeld: functionHeld)
    }

    /// Device-dependent bits from IOLLEvent.h tell left and right modifier keys apart.
    private static func isDown(_ code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        let mask: UInt
        switch code {
        case 59: mask = 0x0001      // left ctrl
        case 56: mask = 0x0002      // left shift
        case 60: mask = 0x0004      // right shift
        case 55: mask = 0x0008      // left cmd
        case 54: mask = 0x0010      // right cmd
        case 58: mask = 0x0020      // left alt
        case 61: mask = 0x0040      // right alt
        case 62: mask = 0x2000      // right ctrl
        case 63: return flags.contains(.function)
        default:
            if let modifier = KeyCode(code).modifier {
                return modifiers(from: flags, functionHeld: true).contains(modifier)
            }
            return false
        }
        return raw & mask != 0
    }

    static func modifiers(from flags: NSEvent.ModifierFlags, functionHeld: Bool) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        // Arrow, navigation and F-keys carry .function without a held Fn key.
        if functionHeld && flags.contains(.function) { result.insert(.function) }
        return result
    }
}

/// Keys that are hard or impossible to type into the recorder.
enum SpecialKeys {
    static let functionKeys: [String] = (13...20).map { "f\($0)" }
    static let keys: [(name: String, label: String)] = [
        ("caps_lock", String(localized: "Caps Lock")),
        ("code:131", String(localized: "Launchpad key (F4 on Apple keyboards)")),
        ("code:160", String(localized: "Mission Control key (F3 on Apple keyboards)")),
        ("menu", String(localized: "Menu / Application key")),
        ("insert", String(localized: "Insert")),
        ("left_cmd", String(localized: "Left ⌘ Command alone")),
        ("right_cmd", String(localized: "Right ⌘ Command alone")),
        ("left_alt", String(localized: "Left ⌥ Option alone")),
        ("right_alt", String(localized: "Right ⌥ Option alone")),
        ("left_ctrl", String(localized: "Left ⌃ Control alone")),
        ("right_ctrl", String(localized: "Right ⌃ Control alone")),
        ("left_shift", String(localized: "Left ⇧ Shift alone")),
        ("right_shift", String(localized: "Right ⇧ Shift alone")),
        ("fn", String(localized: "fn / Globe alone")),
    ]

    /// Whether the recorder UI should show modifier toggles for a value (keys you can't record
    /// with modifiers held, and mouse buttons).
    static func needsModifierToggles(_ trigger: Trigger?) -> Bool {
        guard let trigger else { return false }
        switch trigger {
        case .mouse: return true
        case .key(let combo):
            if combo.key.isModifier { return false }
            let name = combo.key.name
            return functionKeys.contains(name) || keys.contains { $0.name == name }
        }
    }
}

/// "Click, press the combo, done." Shows keycaps when set, a live prompt while recording, and a
/// menu for keys that are hard to type (and mouse buttons when `allowMouse`).
struct KeyRecorderField: View {
    @Binding var value: Trigger?
    var allowMouse = true
    var placeholder: LocalizedStringKey = "Click to record"

    @ObservedObject private var recorder = KeyRecorder.shared
    @State private var owner = UUID()

    private var isRecording: Bool { recorder.owner == owner }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        content
                        Spacer(minLength: 0)
                        if value != nil && !isRecording {
                            Image(systemName: "record.circle").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minWidth: 220, minHeight: 32)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.15),
                                          lineWidth: isRecording ? 2 : 1)
                    )
                }
                .buttonStyle(.plain)
                .help(Text("Click, then press the keys"))
                .accessibilityLabel(Text("Record keys"))
                .accessibilityValue(value.map { UIText.display($0) } ?? String(localized: "Not set"))

                specialMenu
            }
            if isRecording {
                Text("Press the keys now. A modifier pressed alone records that key. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if SpecialKeys.needsModifierToggles(value), let current = value {
                ModifierToggles(modifiers: Binding(
                    get: { current.modifiers },
                    set: { value = current.withModifiers($0) }
                ))
            }
        }
        .onDisappear { recorder.cancel(owner: owner) }
    }

    @ViewBuilder private var content: some View {
        if isRecording {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                if recorder.liveModifiers.isEmpty {
                    Text("Press keys…").foregroundStyle(.secondary)
                } else {
                    ForEach(UIText.modifierSymbols(recorder.liveModifiers), id: \.self) { Keycap(text: $0, prominent: true) }
                }
            }
        } else if let value {
            TriggerKeycaps(trigger: value)
        } else {
            Text(placeholder).foregroundStyle(.secondary)
        }
    }

    private var specialMenu: some View {
        Menu {
            Section(String(localized: "Special keys")) {
                ForEach(SpecialKeys.keys, id: \.name) { key in
                    Button(key.label) { pick(key.name) }
                }
            }
            Menu(String(localized: "F13 – F20")) {
                ForEach(SpecialKeys.functionKeys, id: \.self) { name in
                    Button(name.uppercased()) { pick(name) }
                }
            }
            if allowMouse {
                Section(String(localized: "Mouse")) {
                    ForEach(MouseButton.allCases, id: \.self) { button in
                        Button(UIText.name(button)) {
                            recorder.cancel(owner: owner)
                            value = .mouse(button, value?.modifiers ?? [])
                        }
                    }
                }
            }
            if value != nil {
                Divider()
                Button(String(localized: "Clear")) { value = nil }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text("Keys that are hard to type, and mouse buttons"))
    }

    private func toggle() {
        if isRecording {
            recorder.cancel(owner: owner)
        } else {
            recorder.begin(owner: owner) { combo in value = .key(combo) }
        }
    }

    private func pick(_ name: String) {
        recorder.cancel(owner: owner)
        guard let key = KeyCode.named(name) else { return }
        value = .key(KeyCombo(key, []))
    }
}

/// ⌃ ⌥ ⇧ ⌘ toggle buttons.
struct ModifierToggles: View {
    @Binding var modifiers: Modifiers
    var flags: [Modifiers] = [.control, .option, .shift, .command]

    var body: some View {
        HStack(spacing: 4) {
            Text("With:").font(.caption).foregroundStyle(.secondary)
            ForEach(Modifiers.canonical.filter { flags.contains($0.flag) }, id: \.name) { entry in
                Toggle(isOn: Binding(
                    get: { modifiers.contains(entry.flag) },
                    set: { on in if on { modifiers.insert(entry.flag) } else { modifiers.remove(entry.flag) } }
                )) {
                    Text(entry.symbol).frame(minWidth: 16)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(UIText.modifierName(entry.flag))
            }
        }
    }
}
