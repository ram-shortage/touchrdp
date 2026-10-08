import Foundation

// MARK: - ScancodeKeyboardMapper
//
// Maps macOS NSEvent virtual key codes to PC/AT Set-1 scancodes for RDP input
// via freerdp_input_send_keyboard_event (PRD §8.6, FR-8.12–8.16).
//
// Set-1 make codes are the values FreeRDP expects.  Keys with the E0 prefix
// (arrows, navigation cluster, Right-Ctrl, Right-Alt, keypad Enter/slash,
// Windows/Super) return `extended: true`; the RDP layer prepends the E0 byte.
//
// Modifier mode (FR-8.12):
//   .cmdAsCtrl  — Mac Command → Windows Left-Ctrl (0x1D) so Cmd-C/V/X/Z/A work
//                 with muscle memory. Physical Control also maps to Left-Ctrl.
//                 Super key is never emitted for Command in this mode.
//   .literal    — Mac Command → Windows Left-Super (extended 0x5B); Ctrl → Ctrl.
//
// Unicode fallback (FR-8.16 / §8.6.16):
//   When `useUnicodeFallback` is true, or when a key code is absent from the
//   scancode table but `characters` carries a typeable string, each UTF-16 unit
//   is emitted as `.unicode(UInt16)`.  This covers dead keys, AltGr sequences,
//   and international layouts that differ from US ANSI positions.

public final class ScancodeKeyboardMapper: KeyboardMapper {

    // MARK: - NSEvent modifier flag bit constants (device-independent bits)
    // Values from AppKit NSEvent.ModifierFlags; listed here so we avoid importing AppKit.
    private static let maskShift:   UInt = 1 << 17   // .shift
    private static let maskControl: UInt = 1 << 18   // .control
    private static let maskOption:  UInt = 1 << 19   // .option / Alt
    private static let maskCommand: UInt = 1 << 20   // .command

    // MARK: - Properties

    public var modifierMode: ModifierMode
    public var useUnicodeFallback: Bool

    // F-15: per-connection scancode overrides, consulted BEFORE the standard table
    // (and before the unicode fallback — an explicit user remap always wins). Built
    // ONCE here when the mapper is configured, so the per-keypress hot path pays only
    // a single dictionary lookup (O(1); zero-cost no-op when the list is empty).
    private var overrideTable: [UInt16: (UInt16, Bool)] = [:]

    public init(modifierMode: ModifierMode = .cmdAsCtrl,
                useUnicodeFallback: Bool = false,
                keyOverrides: [KeyOverride] = []) {
        self.modifierMode = modifierMode
        self.useUnicodeFallback = useUnicodeFallback
        setKeyOverrides(keyOverrides)
    }

    /// F-15: (re)configure the override list. Duplicate `macKeyCode` entries keep the
    /// first occurrence (list order = priority).
    public func setKeyOverrides(_ overrides: [KeyOverride]) {
        overrideTable = overrides.reduce(into: [:]) { table, o in
            if table[o.macKeyCode] == nil { table[o.macKeyCode] = (o.scancode, o.extended) }
        }
    }

    // MARK: - KeyboardMapper

    /// Returns the ordered `[KeyAction]` for a macOS key event.
    ///
    /// For known key codes: one `.scancode` action with the correct `down` flag.
    /// For unknown key codes or when `useUnicodeFallback` is true: one `.unicode`
    /// action per UTF-16 unit in `characters` (PRD §8.6.16).
    /// Returns `[]` when the key code is unknown and no characters are available.
    ///
    /// - Parameters:
    ///   - keyCode:    NSEvent.keyCode (the hardware-position virtual key code).
    ///   - characters: NSEvent.characters — used only for the unicode fallback path.
    ///   - modifiers:  NSEvent.modifierFlags.rawValue — unused here; the caller sends
    ///                 modifier key events separately via `modifierDownActions`.
    ///   - keyDown:    true for key-down, false for key-up.
    public func actions(forKeyCode keyCode: UInt16,
                        characters: String?,
                        modifiers: UInt,
                        keyDown: Bool) -> [KeyAction] {

        // F-15: an explicit per-connection override wins over EVERYTHING — the
        // standard table and the unicode fallback alike.
        if let (code, extended) = overrideTable[keyCode] {
            return [KeyAction(kind: .scancode(code, extended: extended), down: keyDown)]
        }

        let entry = Self.scancodeTable[keyCode]

        // Honour useUnicodeFallback even for known keys when set.
        // Also fall back for unknown keys when characters are available.
        if useUnicodeFallback || entry == nil {
            if let chars = characters, !chars.isEmpty {
                return chars.utf16.map { unit in
                    KeyAction(kind: .unicode(unit), down: keyDown)
                }
            }
        }

        if let (scancode, extended) = entry {
            return [KeyAction(kind: .scancode(scancode, extended: extended), down: keyDown)]
        }

        return []
    }

    /// Returns the press-then-release sequence for Ctrl+Alt+Del (PRD FR-8.13).
    /// Intended for use by the dedicated toolbar / menu item.
    public func ctrlAltDelActions() -> [KeyAction] {
        // Left-Ctrl (0x1D), Left-Alt (0x38), forward-Delete (extended 0x53)
        let ctrlSc  = KeyAction(kind: .scancode(0x1D, extended: false), down: true)
        let altSc   = KeyAction(kind: .scancode(0x38, extended: false), down: true)
        let delSc   = KeyAction(kind: .scancode(0x53, extended: true),  down: true)
        let delUp   = KeyAction(kind: .scancode(0x53, extended: true),  down: false)
        let altUp   = KeyAction(kind: .scancode(0x38, extended: false), down: false)
        let ctrlUp  = KeyAction(kind: .scancode(0x1D, extended: false), down: false)
        return [ctrlSc, altSc, delSc, delUp, altUp, ctrlUp]
    }

    // MARK: - Modifier helper (convenience; not part of KeyboardMapper protocol)

    /// Returns the ordered modifier key-down actions for a given modifier flags value.
    ///
    /// In `.cmdAsCtrl` mode both physical Control and Command map to Left-Ctrl (0x1D);
    /// Super is never emitted.  In `.literal` mode Command maps to Left-Super (E0-5B).
    public func modifierDownActions(forModifiers modifiers: UInt) -> [KeyAction] {
        var result: [KeyAction] = []

        if modifiers & Self.maskShift  != 0 {
            result.append(KeyAction(kind: .scancode(0x2A, extended: false), down: true)) // Left-Shift
        }
        if modifiers & Self.maskOption != 0 {
            result.append(KeyAction(kind: .scancode(0x38, extended: false), down: true)) // Left-Alt
        }

        let hasCtrl = modifiers & Self.maskControl != 0
        let hasCmd  = modifiers & Self.maskCommand != 0

        switch modifierMode {
        case .cmdAsCtrl:
            if hasCtrl || hasCmd {
                result.append(KeyAction(kind: .scancode(0x1D, extended: false), down: true)) // Left-Ctrl
            }
        case .literal:
            if hasCtrl {
                result.append(KeyAction(kind: .scancode(0x1D, extended: false), down: true)) // Left-Ctrl
            }
            if hasCmd {
                result.append(KeyAction(kind: .scancode(0x5B, extended: true),  down: true)) // Left-Win/Super
            }
        }

        return result
    }

    /// Key-up counterpart to `modifierDownActions(forModifiers:)`.
    public func modifierUpActions(forModifiers modifiers: UInt) -> [KeyAction] {
        modifierDownActions(forModifiers: modifiers).map {
            KeyAction(kind: $0.kind, down: false)
        }
    }

    // MARK: - PC/AT Set-1 scancode table
    //
    // Key:   macOS NSEvent.keyCode (UInt16, from HIToolbox/Events.h)
    // Value: (Set-1 make code, isExtended)
    //
    // Set-1 make codes are the 1-byte values for normal keys.  Extended (E0-prefix)
    // keys set isExtended = true.  The RDP engine prepends the E0 escape byte when
    // forwarding extended keys over the wire.
    //
    // Sources:
    //   • "USB HID to PS/2 Scan Code Translation Table" (Microsoft, 2000)
    //   • freerdp/libfreerdp/input/keyboard.c  (Set-1 mapping)
    //   • Apple HIToolbox Events.h              (virtual key code assignments)
    private static let scancodeTable: [UInt16: (UInt16, Bool)] = {
        var t: [UInt16: (UInt16, Bool)] = [:]

        // MARK: Letters (ANSI US physical positions — layout-agnostic by design)
        t[0]  = (0x1E, false) // A
        t[1]  = (0x1F, false) // S
        t[2]  = (0x20, false) // D
        t[3]  = (0x21, false) // F
        t[4]  = (0x23, false) // H
        t[5]  = (0x22, false) // G
        t[6]  = (0x2C, false) // Z
        t[7]  = (0x2D, false) // X
        t[8]  = (0x2E, false) // C
        t[9]  = (0x2F, false) // V
        t[10] = (0x56, false) // § / < — ISO key (left of Z on ISO keyboards)
        t[11] = (0x30, false) // B
        t[12] = (0x10, false) // Q
        t[13] = (0x11, false) // W
        t[14] = (0x12, false) // E
        t[15] = (0x13, false) // R
        t[16] = (0x15, false) // Y
        t[17] = (0x14, false) // T
        t[31] = (0x18, false) // O
        t[32] = (0x16, false) // U
        t[34] = (0x17, false) // I
        t[35] = (0x19, false) // P
        t[37] = (0x26, false) // L
        t[38] = (0x24, false) // J
        t[40] = (0x25, false) // K
        t[45] = (0x31, false) // N
        t[46] = (0x32, false) // M

        // MARK: Digit row (main keyboard)
        t[18] = (0x02, false) // 1 / !
        t[19] = (0x03, false) // 2 / @
        t[20] = (0x04, false) // 3 / #
        t[21] = (0x05, false) // 4 / $
        t[22] = (0x07, false) // 6 / ^
        t[23] = (0x06, false) // 5 / %
        t[25] = (0x0A, false) // 9 / (
        t[26] = (0x08, false) // 7 / &
        t[28] = (0x09, false) // 8 / *
        t[29] = (0x0B, false) // 0 / )

        // MARK: Top-row symbols
        t[24] = (0x0D, false) // = / +
        t[27] = (0x0C, false) // - / _

        // MARK: Bracket / quote / punctuation
        t[30] = (0x1B, false) // ] / }
        t[33] = (0x1A, false) // [ / {
        t[39] = (0x28, false) // ' / "
        t[41] = (0x27, false) // ; / :
        t[42] = (0x2B, false) // \ / |
        t[43] = (0x33, false) // , / <
        t[44] = (0x35, false) // / / ?   (forward slash — ANSI keyCode 44)
        t[47] = (0x34, false) // . / >
        t[50] = (0x29, false) // ` / ~  (grave / backtick)

        // MARK: Whitespace & editing
        t[36] = (0x1C, false) // Return / Enter (main keyboard)
        t[48] = (0x0F, false) // Tab
        t[49] = (0x39, false) // Space
        t[51] = (0x0E, false) // Delete / Backspace
        t[53] = (0x01, false) // Escape

        // MARK: Modifier keys (scancodes used in literal mode / direct key events)
        // In .cmdAsCtrl the mapper logic remaps Command to Ctrl; these entries
        // are used when the modifier key itself is the primary key event.
        t[54] = (0x1D, true)  // Right Command → Right-Ctrl (E0-1D); literal: Right-Win (E0-5C)
        t[55] = (0x5B, true)  // Left Command  → Left-Win/Super (E0-5B); cmdAsCtrl → Left-Ctrl below
        t[56] = (0x2A, false) // Left Shift
        t[57] = (0x3A, false) // Caps Lock
        t[58] = (0x38, false) // Left Option / Left-Alt
        t[59] = (0x1D, false) // Left Control
        t[60] = (0x36, false) // Right Shift
        t[61] = (0x38, true)  // Right Option / Right-Alt  (E0-38)
        t[62] = (0x1D, true)  // Right Control             (E0-1D)
        // keyCode 63 = Fn — host-side only, no Windows scancode

        // MARK: Function keys F1–F12
        t[122] = (0x3B, false) // F1
        t[120] = (0x3C, false) // F2
        t[99]  = (0x3D, false) // F3
        t[118] = (0x3E, false) // F4
        t[96]  = (0x3F, false) // F5
        t[97]  = (0x40, false) // F6
        t[98]  = (0x41, false) // F7
        t[100] = (0x42, false) // F8
        t[101] = (0x43, false) // F9
        t[109] = (0x44, false) // F10
        t[103] = (0x57, false) // F11
        t[111] = (0x58, false) // F12
        // F13 (105) = 0x64, F14 (107) = 0x65, F15 (113) = 0x66  (Set-3 extras; uncommon)
        t[105] = (0x64, false) // F13
        t[107] = (0x65, false) // F14
        t[113] = (0x66, false) // F15

        // MARK: Arrow keys (all extended E0)
        t[123] = (0x4B, true)  // Left  (E0-4B)
        t[124] = (0x4D, true)  // Right (E0-4D)
        t[125] = (0x50, true)  // Down  (E0-50)
        t[126] = (0x48, true)  // Up    (E0-48)

        // MARK: Navigation cluster (all extended E0)
        t[114] = (0x52, true)  // Insert       (E0-52) — Fn+Return on MacBooks
        t[117] = (0x53, true)  // Forward Delete (E0-53)
        t[115] = (0x47, true)  // Home         (E0-47)
        t[119] = (0x4F, true)  // End          (E0-4F)
        t[116] = (0x49, true)  // Page Up      (E0-49)
        t[121] = (0x51, true)  // Page Down    (E0-51)

        // MARK: Keypad (numpad)
        // Non-extended unless the key has a dedicated navigation-cluster twin that
        // is extended.  NumLock state (not tracked here) determines num/nav behaviour.
        t[82] = (0x52, false) // KP 0 / Insert
        t[83] = (0x4F, false) // KP 1 / End
        t[84] = (0x50, false) // KP 2 / Down
        t[85] = (0x51, false) // KP 3 / Page Down
        t[86] = (0x4B, false) // KP 4 / Left
        t[87] = (0x4C, false) // KP 5 (no navigation twin)
        t[88] = (0x4D, false) // KP 6 / Right
        t[89] = (0x47, false) // KP 7 / Home
        t[91] = (0x48, false) // KP 8 / Up
        t[92] = (0x49, false) // KP 9 / Page Up
        t[65] = (0x53, false) // KP . / Delete
        t[67] = (0x37, false) // KP *
        t[69] = (0x4E, false) // KP +
        t[71] = (0x45, false) // KP Clear → Num Lock (0x45)
        t[75] = (0x35, true)  // KP /            (E0-35)
        t[76] = (0x1C, true)  // KP Enter        (E0-1C)
        t[78] = (0x4A, false) // KP -
        t[81] = (0x0D, false) // KP = (Mac-only; map to = on main board — 0x0D)

        // MARK: Miscellaneous
        t[52] = (0x1C, true)  // Enter (some Mac keyboards emit 52 for the numpad Enter)
        // Print Screen has no direct macOS key; F13 (keyCode 105) maps to 0x64 above.

        return t
    }()
}

// MARK: - Special key sequences (F-4)

/// Canned one-shot key sequences for the "Send Keys" menu (F-4): keys a Mac keyboard
/// can't produce (Windows key, PrintScreen) or that macOS would intercept (Alt-Tab,
/// Win+L). Chords press downs in order and release in reverse, mirroring
/// `ctrlAltDelActions()`.
///
/// Scancodes are PC/AT Set-1 (same space as the table above); extended (E0) keys per
/// /opt/homebrew/include/freerdp3/freerdp/scancode.h: LWin = E0-5B (RDP_SCANCODE_LWIN),
/// PrintScreen = E0-37 (RDP_SCANCODE_PRINTSCREEN), Tab = 0x0F, Esc = 0x01, L = 0x26,
/// Left-Ctrl = 0x1D, Left-Alt = 0x38.
public enum SpecialKeySequence: String, CaseIterable, Sendable {
    case windowsKey       // tap the Windows/Super key (opens Start)
    case altTab           // one-shot remote app switch: Alt down, Tab tap, Alt up
    case printScreen      // full-desktop screenshot to the remote clipboard
    case altPrintScreen   // active-window screenshot
    case winL             // Win+L: lock the remote session
    case escape
    case ctrlEscape       // Ctrl+Esc: Start menu (works where the Win key is remapped)

    /// The ordered scancode actions: held keys down first, then the tapped key
    /// down+up, then the held keys up in reverse order.
    public var actions: [KeyAction] {
        switch self {
        case .windowsKey:     return Self.tap((0x5B, true))
        case .altTab:         return Self.chord(hold: [(0x38, false)], tap: (0x0F, false))
        case .printScreen:    return Self.tap((0x37, true))
        case .altPrintScreen: return Self.chord(hold: [(0x38, false)], tap: (0x37, true))
        case .winL:           return Self.chord(hold: [(0x5B, true)], tap: (0x26, false))
        case .escape:         return Self.tap((0x01, false))
        case .ctrlEscape:     return Self.chord(hold: [(0x1D, false)], tap: (0x01, false))
        }
    }

    /// F1–F12 tap (1-based). Set-1: F1–F10 = 0x3B–0x44, F11 = 0x57, F12 = 0x58
    /// (matching the mapper's function-key table). Out-of-range returns [].
    public static func functionKey(_ n: Int) -> [KeyAction] {
        let code: UInt16
        switch n {
        case 1...10: code = 0x3B + UInt16(n - 1)
        case 11:     code = 0x57
        case 12:     code = 0x58
        default:     return []
        }
        return tap((code, false))
    }

    private static func tap(_ key: (UInt16, Bool)) -> [KeyAction] {
        [KeyAction(kind: .scancode(key.0, extended: key.1), down: true),
         KeyAction(kind: .scancode(key.0, extended: key.1), down: false)]
    }

    private static func chord(hold: [(UInt16, Bool)], tap key: (UInt16, Bool)) -> [KeyAction] {
        let downs = hold.map { KeyAction(kind: .scancode($0.0, extended: $0.1), down: true) }
        let ups = hold.reversed().map { KeyAction(kind: .scancode($0.0, extended: $0.1), down: false) }
        return downs + tap(key) + ups
    }
}
