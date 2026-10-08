import XCTest
@testable import TouchRDPCore

final class ScancodeKeyboardMapperTests: XCTestCase {

    // macOS NSEvent modifier flag bits (from AppKit, reproduced here for testing).
    private static let maskShift:   UInt = 1 << 17
    private static let maskControl: UInt = 1 << 18
    private static let maskOption:  UInt = 1 << 19
    private static let maskCommand: UInt = 1 << 20

    // macOS virtual key codes (HIToolbox/Events.h).
    // kVK_ANSI_A = 0
    private let kVK_ANSI_A: UInt16 = 0
    // A non-existent key code guaranteed to be absent from the table.
    private let kUnknownKeyCode: UInt16 = 0xFFFF

    // MARK: - Basic scancode mapping

    func testKnownKeycodeProducesScancode() {
        let mapper = ScancodeKeyboardMapper()
        let actions = mapper.actions(forKeyCode: kVK_ANSI_A,
                                     characters: "a",
                                     modifiers: 0,
                                     keyDown: true)
        XCTAssertEqual(actions.count, 1)
        if case .scancode(let sc, _) = actions[0].kind {
            XCTAssertEqual(sc, 0x1E, "A should map to Set-1 scancode 0x1E")
        } else {
            XCTFail("Expected .scancode, got \(actions[0].kind)")
        }
    }

    // Full alphanumeric audit. Pins every letter and digit (macOS NSEvent.keyCode →
    // PC/AT Set-1 make code) so a position swap like the original N/M bug — where N and
    // M's scancodes were reversed — can never silently regress. The non-sequential
    // pairs (5/6, G/H) are the easy ones to transpose, so they're covered explicitly.
    func testFullLetterAndDigitScancodeMapping() {
        let mapper = ScancodeKeyboardMapper()
        // (macOS NSEvent.keyCode, expected Set-1 make code, label)
        let cases: [(UInt16, UInt16, String)] = [
            // Letters
            (0, 0x1E, "A"), (11, 0x30, "B"), (8, 0x2E, "C"), (2, 0x20, "D"),
            (14, 0x12, "E"), (3, 0x21, "F"), (5, 0x22, "G"), (4, 0x23, "H"),
            (34, 0x17, "I"), (38, 0x24, "J"), (40, 0x25, "K"), (37, 0x26, "L"),
            (46, 0x32, "M"), (45, 0x31, "N"), (31, 0x18, "O"), (35, 0x19, "P"),
            (12, 0x10, "Q"), (15, 0x13, "R"), (1, 0x1F, "S"), (17, 0x14, "T"),
            (32, 0x16, "U"), (9, 0x2F, "V"), (13, 0x11, "W"), (7, 0x2D, "X"),
            (16, 0x15, "Y"), (6, 0x2C, "Z"),
            // Digit row (note macOS orders 6 before 5; Set-1 is 5=0x06, 6=0x07)
            (18, 0x02, "1"), (19, 0x03, "2"), (20, 0x04, "3"), (21, 0x05, "4"),
            (23, 0x06, "5"), (22, 0x07, "6"), (26, 0x08, "7"), (28, 0x09, "8"),
            (25, 0x0A, "9"), (29, 0x0B, "0"),
        ]
        for (keyCode, expected, name) in cases {
            let actions = mapper.actions(forKeyCode: keyCode, characters: nil,
                                         modifiers: 0, keyDown: true)
            guard case .scancode(let sc, let ext)? = actions.first?.kind else {
                XCTFail("\(name): expected a scancode action"); continue
            }
            XCTAssertEqual(sc, expected,
                           "\(name) (keyCode \(keyCode)) should map to Set-1 0x\(String(expected, radix: 16))")
            XCTAssertFalse(ext, "\(name) should not be an extended key")
        }
    }

    func testKeyDownFlagPreserved() {
        let mapper = ScancodeKeyboardMapper()
        let down = mapper.actions(forKeyCode: kVK_ANSI_A, characters: nil,
                                  modifiers: 0, keyDown: true)
        let up   = mapper.actions(forKeyCode: kVK_ANSI_A, characters: nil,
                                  modifiers: 0, keyDown: false)
        XCTAssertTrue(down.first?.down == true)
        XCTAssertTrue(up.first?.down == false)
    }

    // MARK: - .cmdAsCtrl mode

    func testCmdAsCtrlModeCommandMapsToCtrl() {
        let mapper = ScancodeKeyboardMapper(modifierMode: .cmdAsCtrl)
        let actions = mapper.modifierDownActions(forModifiers: Self.maskCommand)
        // Must produce exactly Left-Ctrl (0x1D, extended:false).
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0], KeyAction(kind: .scancode(0x1D, extended: false), down: true))
    }

    func testCmdAsCtrlModeCommandDoesNotEmitSuper() {
        let mapper = ScancodeKeyboardMapper(modifierMode: .cmdAsCtrl)
        let actions = mapper.modifierDownActions(forModifiers: Self.maskCommand)
        let hasSuper = actions.contains { action in
            if case .scancode(0x5B, extended: true) = action.kind { return true }
            return false
        }
        XCTAssertFalse(hasSuper, "Super key must NOT be emitted in .cmdAsCtrl mode")
    }

    func testCmdAsCtrlModeControlMapsToCtrl() {
        let mapper = ScancodeKeyboardMapper(modifierMode: .cmdAsCtrl)
        let actions = mapper.modifierDownActions(forModifiers: Self.maskControl)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0], KeyAction(kind: .scancode(0x1D, extended: false), down: true))
    }

    func testCmdAsCtrlModeBothCtrlAndCmdProduceSingleCtrl() {
        let mapper = ScancodeKeyboardMapper(modifierMode: .cmdAsCtrl)
        let both = Self.maskControl | Self.maskCommand
        let actions = mapper.modifierDownActions(forModifiers: both)
        // Only one Left-Ctrl should be emitted (not two).
        let ctrlCount = actions.filter { action in
            if case .scancode(0x1D, extended: false) = action.kind { return true }
            return false
        }.count
        XCTAssertEqual(ctrlCount, 1)
    }

    // MARK: - .literal mode

    func testLiteralModeCommandMapsToSuper() {
        let mapper = ScancodeKeyboardMapper(modifierMode: .literal)
        let actions = mapper.modifierDownActions(forModifiers: Self.maskCommand)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0], KeyAction(kind: .scancode(0x5B, extended: true), down: true))
    }

    func testLiteralModeControlMapsToCtrl() {
        let mapper = ScancodeKeyboardMapper(modifierMode: .literal)
        let actions = mapper.modifierDownActions(forModifiers: Self.maskControl)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0], KeyAction(kind: .scancode(0x1D, extended: false), down: true))
    }

    // MARK: - ctrlAltDelActions

    func testCtrlAltDelActionsCount() {
        let mapper = ScancodeKeyboardMapper()
        let actions = mapper.ctrlAltDelActions()
        // 3 down + 3 up = 6
        XCTAssertEqual(actions.count, 6)
    }

    func testCtrlAltDelActionsSequence() {
        let mapper = ScancodeKeyboardMapper()
        let actions = mapper.ctrlAltDelActions()

        // Expected: Ctrl↓, Alt↓, Del↓, Del↑, Alt↑, Ctrl↑
        let expected: [KeyAction] = [
            KeyAction(kind: .scancode(0x1D, extended: false), down: true),   // Ctrl down
            KeyAction(kind: .scancode(0x38, extended: false), down: true),   // Alt down
            KeyAction(kind: .scancode(0x53, extended: true),  down: true),   // Del down
            KeyAction(kind: .scancode(0x53, extended: true),  down: false),  // Del up
            KeyAction(kind: .scancode(0x38, extended: false), down: false),  // Alt up
            KeyAction(kind: .scancode(0x1D, extended: false), down: false),  // Ctrl up
        ]
        XCTAssertEqual(actions, expected)
    }

    // MARK: - Unicode fallback

    func testUnicodeFallbackWhenFlagSet() {
        let mapper = ScancodeKeyboardMapper(useUnicodeFallback: true)
        // Even for a known key code, characters should be emitted as unicode.
        let actions = mapper.actions(forKeyCode: kVK_ANSI_A,
                                     characters: "a",
                                     modifiers: 0,
                                     keyDown: true)
        XCTAssertEqual(actions.count, 1)
        if case .unicode(let unit) = actions[0].kind {
            XCTAssertEqual(unit, UInt16(("a" as Unicode.Scalar).value))
        } else {
            XCTFail("Expected .unicode action, got \(actions[0].kind)")
        }
    }

    func testUnicodeFallbackForUnknownKey() {
        let mapper = ScancodeKeyboardMapper(useUnicodeFallback: false)
        // Unknown key code with a character string should fall back to unicode.
        let actions = mapper.actions(forKeyCode: kUnknownKeyCode,
                                     characters: "€",
                                     modifiers: 0,
                                     keyDown: true)
        XCTAssertFalse(actions.isEmpty, "Unknown key with characters should produce unicode actions")
        for action in actions {
            if case .unicode(_) = action.kind { /* ok */ } else {
                XCTFail("Expected all actions to be .unicode for unknown key code")
            }
        }
    }

    func testUnknownKeyWithNoCharactersProducesEmpty() {
        let mapper = ScancodeKeyboardMapper(useUnicodeFallback: false)
        let actions = mapper.actions(forKeyCode: kUnknownKeyCode,
                                     characters: nil,
                                     modifiers: 0,
                                     keyDown: true)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Modifier up actions mirror down actions

    func testModifierUpActionsAreDownFlipped() {
        let mapper = ScancodeKeyboardMapper(modifierMode: .literal)
        let mods: UInt = Self.maskShift | Self.maskCommand | Self.maskOption
        let downActions = mapper.modifierDownActions(forModifiers: mods)
        let upActions   = mapper.modifierUpActions(forModifiers: mods)

        XCTAssertEqual(downActions.count, upActions.count)
        for (d, u) in zip(downActions, upActions) {
            XCTAssertEqual(d.kind, u.kind)
            XCTAssertTrue(d.down)
            XCTAssertFalse(u.down)
        }
    }
}
