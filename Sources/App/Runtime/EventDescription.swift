import KeyshiftCore

enum EventDescription {
    static func input(_ event: InputEvent) -> String {
        let key = KeyCombo(event.key, event.modifiers).displayString
        switch event.kind {
        case .keyDown: return "\(key) down"
        case .keyUp: return "\(key) up"
        case .flagsChanged(let down):
            var modifiers = event.modifiers
            if let modifier = event.key.modifier { modifiers.remove(modifier) }
            return "\(KeyCombo(event.key, modifiers).displayString) \(down ? "down" : "up")"
        case .mouseDown(let button): return "\(mouse(button, event.modifiers)) down"
        case .mouseUp(let button): return "\(mouse(button, event.modifiers)) up"
        }
    }

    static func decision(_ decision: Decision) -> String {
        var parts: [String] = []
        switch decision.disposition {
        case .pass: parts.append("passed")
        case .rewrite(let event): parts.append(output(event))
        case .replace:
            parts += decision.emit.compactMap { event in
                switch event {
                case .keyDown, .mouseDown: return output(event)
                case .keyUp, .mouseUp: return nil
                }
            }
            if parts.isEmpty, let event = decision.emit.first { parts.append(output(event)) }
        }
        parts += decision.actions.map { action in
            switch action {
            case .openApp(let name): return "open \(name)"
            case .openURL(let url): return "open \(url)"
            case .shell: return "run shell command"
            case .system(let action): return action.rawValue.replacingOccurrences(of: "_", with: " ")
            case .keys(let keys): return keys.map(\.displayString).joined(separator: ", ")
            case .mouse(let button, let modifiers): return mouse(button, modifiers)
            case .none: return "blocked"
            }
        }
        return parts.isEmpty ? "blocked" : parts.joined(separator: ", ")
    }

    private static func output(_ event: OutputEvent) -> String {
        switch event {
        case .keyDown(let key, let modifiers, _), .keyUp(let key, let modifiers):
            return KeyCombo(key, modifiers).displayString
        case .mouseDown(let button, let modifiers), .mouseUp(let button, let modifiers):
            return mouse(button, modifiers)
        }
    }

    private static func mouse(_ button: MouseButton, _ modifiers: Modifiers) -> String {
        modifiers.symbols + button.rawValue.replacingOccurrences(of: "_", with: " ")
    }
}
