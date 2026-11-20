import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let togglePopover = Self("togglePopover", default: .init(.v, modifiers: [.command, .shift]))
}

enum Hotkey {
    @MainActor
    static func register(_ action: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .togglePopover) {
            Task { @MainActor in action() }
        }
    }
}
