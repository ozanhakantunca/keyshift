import Carbon

/// While any app holds Secure Event Input (password fields, Terminal's Secure Keyboard Entry, some
/// password managers), macOS delivers no key events to event taps, so only HID remaps keep working.
public enum SecureInput {
    public static func isEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }
}
