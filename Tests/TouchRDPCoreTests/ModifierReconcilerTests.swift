import XCTest
@testable import TouchRDPCore

final class ModifierReconcilerTests: XCTestCase {

    private let leftShift = ModifierReconciler.Mod(code: 0x2A, extended: false)
    private let leftCtrl  = ModifierReconciler.Mod(code: 0x1D, extended: false)

    // Holding then releasing Shift must emit a key-DOWN then a key-UP (the original
    // stuck-modifier bug re-sent down on release).
    func testShiftDownThenUp() {
        var r = ModifierReconciler()
        let down = r.reconcile(shift: true, control: false, option: false, command: false, mode: .cmdAsCtrl)
        XCTAssertEqual(down, [KeyAction(kind: .scancode(0x2A, extended: false), down: true)])
        let up = r.reconcile(shift: false, control: false, option: false, command: false, mode: .cmdAsCtrl)
        XCTAssertEqual(up, [KeyAction(kind: .scancode(0x2A, extended: false), down: false)])
    }

    // Steady state must be idempotent: re-asserting the same held set emits nothing.
    func testNoDiffWhenUnchanged() {
        var r = ModifierReconciler()
        _ = r.reconcile(shift: true, control: false, option: false, command: false, mode: .cmdAsCtrl)
        let again = r.reconcile(shift: true, control: false, option: false, command: false, mode: .cmdAsCtrl)
        XCTAssertTrue(again.isEmpty, "Re-asserting an unchanged modifier set should be a no-op")
    }

    // After an RDP synchronize event (which resets the server's modifiers), markAllReleased
    // must drop the held set WITHOUT emitting key-ups, and the next reconcile must RE-PRESS
    // a still-held modifier. This is what makes Shift survive a focus-in / Caps Lock sync,
    // and is the core of the Shift+click multi-select fix.
    func testMarkAllReleasedForcesReassert() {
        var r = ModifierReconciler()
        _ = r.reconcile(shift: true, control: false, option: false, command: false, mode: .cmdAsCtrl)
        XCTAssertEqual(r.held, [leftShift])

        r.markAllReleased()
        XCTAssertTrue(r.held.isEmpty, "markAllReleased must clear the held set")

        // Shift is still physically down; the next reconcile must press it again, because
        // the synchronize event released it server-side.
        let reassert = r.reconcile(shift: true, control: false, option: false, command: false, mode: .cmdAsCtrl)
        XCTAssertEqual(reassert, [KeyAction(kind: .scancode(0x2A, extended: false), down: true)],
                       "After a synchronize reset, a still-held Shift must be re-pressed")
    }

    // cmdAsCtrl: Command alone maps to Left-Ctrl (so Cmd-click becomes Ctrl-click
    // multi-select on the remote).
    func testCommandMapsToCtrlForMultiSelect() {
        var r = ModifierReconciler()
        let actions = r.reconcile(shift: false, control: false, option: false, command: true, mode: .cmdAsCtrl)
        XCTAssertEqual(actions, [KeyAction(kind: .scancode(0x1D, extended: false), down: true)])
        XCTAssertEqual(r.held, [leftCtrl])
    }
}
