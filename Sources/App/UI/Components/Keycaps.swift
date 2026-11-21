import AppKit
import KeyshiftCore
import SwiftUI

/// One rounded key, like a physical keycap.
struct Keycap: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 22, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0.5, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(prominent ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.14), lineWidth: 1)
            )
    }
}

/// `⌃ C`, `⌘ Left click`: one keycap per modifier plus the key.
struct TriggerKeycaps: View {
    let trigger: Trigger

    var body: some View {
        HStack(spacing: 3) {
            switch trigger {
            case .key(let combo):
                ForEach(UIText.modifierSymbols(combo.modifiers), id: \.self) { Keycap(text: $0) }
                Keycap(text: UIText.keyLabel(combo.key))
            case .mouse(let button, let modifiers):
                ForEach(UIText.modifierSymbols(modifiers), id: \.self) { Keycap(text: $0) }
                Keycap(text: UIText.name(button))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UIText.display(trigger))
    }
}

/// Right-hand side of a mapping: keycaps for keys, an icon + label for everything else.
struct ActionSummary: View {
    @ObservedObject private var model = AppModel.shared
    let action: Action

    var body: some View {
        switch action {
        case .keys(let combos) where combos.count == 1:
            TriggerKeycaps(trigger: .key(combos[0]))
        case .keys(let combos):
            HStack(spacing: 4) {
                ForEach(Array(combos.enumerated()), id: \.offset) { index, combo in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    TriggerKeycaps(trigger: .key(combo))
                }
            }
        case .mouse(let button, let modifiers):
            TriggerKeycaps(trigger: .mouse(button, modifiers))
        case .openApp(let app):
            HStack(spacing: 5) {
                AppIconView(entry: app, size: 16)
                Text("Open \(model.appDisplayName(for: app))")
            }
        case .openURL(let url):
            iconLabel("link", String(localized: "Open \(Self.shortURL(url))"))
        case .shell(let command):
            HStack(spacing: 5) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(command).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.tail)
            }
        case .system(let system):
            iconLabel(UIText.symbol(system), UIText.name(system))
        case .none:
            iconLabel("nosign", String(localized: "Disabled"))
                .foregroundStyle(.secondary)
        }
    }

    private func iconLabel(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(text).lineLimit(1)
        }
    }

    static func shortURL(_ string: String) -> String {
        guard let url = URL(string: string), let host = url.host else { return string }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A whole mapping in one line: `⌃ C → ⌘ C`, `⌘ tap → Launchpad`.
struct MappingLine: View {
    let mapping: Mapping

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                TriggerKeycaps(trigger: mapping.trigger)
                if mapping.isTapAlone {
                    Text("tap")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help(Text("Runs when the key is pressed and released on its own; held, it works as usual."))
                }
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ActionSummary(action: mapping.action)
        }
    }
}

/// Small rounded label used for scope and focus information.
struct Chip<Icon: View>: View {
    let text: String
    var tint: Color = .secondary
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: 4) {
            icon()
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.18)))
    }
}

extension Chip where Icon == AnyView {
    init(_ text: String, symbol: String?, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
        self.icon = {
            if let symbol { return AnyView(Image(systemName: symbol)) }
            return AnyView(EmptyView())
        }
    }
}
