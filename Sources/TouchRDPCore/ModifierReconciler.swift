import Foundation

// MARK: - ModifierReconciler
//
// macOS reports modifier keys via `flagsChanged` as *state* (the current set of
// active modifiers), not discrete press/release events. Naively emitting a key-DOWN
// on every change leaves modifiers "stuck" on the remote — e.g. releasing Shift sends
// another Shift-down, so following keys come out shifted/"lost".
//
// This reconciler tracks the modifier scancodes currently held on the remote and, for
// a new desired state, returns *only the diffs* (releases first, then presses). It is
// therefore:
//   • correct on release (sends key-UP), fixing the stuck-Shift bug,
//   • self-healing — if an event is missed, the next reconcile restores the true state,
//   • usable to release everything on focus loss (pass all-false).
public struct ModifierReconciler {

    public struct Mod: Hashable, Sendable {
        public let code: UInt16
        public let extended: Bool
        public init(code: UInt16, extended: Bool) { self.code = code; self.extended = extended }
    }

    public private(set) var held: Set<Mod> = []

    public init() {}

    /// Drive the held modifier set to match the requested state, returning the ordered
    /// key actions (releases before presses) needed to get there.
    public mutating func reconcile(shift: Bool, control: Bool, option: Bool, command: Bool,
                                   mode: ModifierMode) -> [KeyAction] {
        var desired: Set<Mod> = []
        if shift  { desired.insert(Mod(code: 0x2A, extended: false)) } // Left Shift
        if option { desired.insert(Mod(code: 0x38, extended: false)) } // Left Alt
        switch mode {
        case .cmdAsCtrl:
            // Both physical Control and Command map to Left-Ctrl; a single scancode
            // covers either (set membership dedupes, so holding both never double-sends).
            if control || command { desired.insert(Mod(code: 0x1D, extended: false)) }
        case .literal:
            if control { desired.insert(Mod(code: 0x1D, extended: false)) }       // Left Ctrl
            if command { desired.insert(Mod(code: 0x5B, extended: true)) }        // Left Win/Super
        }

        var actions: [KeyAction] = []
        for m in held.subtracting(desired) {
            actions.append(KeyAction(kind: .scancode(m.code, extended: m.extended), down: false))
        }
        for m in desired.subtracting(held) {
            actions.append(KeyAction(kind: .scancode(m.code, extended: m.extended), down: true))
        }
        held = desired
        return actions
    }

    /// Convenience: release everything (e.g. on focus loss).
    public mutating func releaseAll(mode: ModifierMode) -> [KeyAction] {
        reconcile(shift: false, control: false, option: false, command: false, mode: mode)
    }

    /// Forget the held set WITHOUT emitting key-ups. Use right after sending an RDP
    /// synchronize event, which already resets the server's modifier keys to up: the
    /// reconciler's view must match (otherwise it believes modifiers are still held and
    /// won't re-assert them). Follow with a `reconcile(...)` to re-press whatever is
    /// genuinely down now.
    public mutating func markAllReleased() {
        held = []
    }
}
