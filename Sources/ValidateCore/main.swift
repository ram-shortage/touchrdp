// Headless validation harness for the pure-logic core (no UI, no FreeRDP, no Touch ID).
// Run with: swift run ValidateCore   — exits non-zero if any check fails.

import Foundation
import TouchRDPCore

var failures = 0
func check(_ cond: Bool, _ name: String) {
    print(cond ? "  ✓ \(name)" : "  ✗ FAIL: \(name)")
    if !cond { failures += 1 }
}

func sc(_ a: KeyAction) -> (UInt16, Bool, Bool)? {     // (code, extended, down)
    if case let .scancode(code, ext) = a.kind { return (code, ext, a.down) }
    return nil
}

print("== ModifierReconciler (keyboard reliability) ==")
do {
    // Press Shift -> exactly one Shift DOWN (0x2A).
    var r = ModifierReconciler()
    let press = r.reconcile(shift: true, control: false, option: false, command: false, mode: .cmdAsCtrl)
    check(press.count == 1 && sc(press[0])! == (0x2A, false, true), "press Shift => Shift down")

    // Release Shift -> exactly one Shift UP (this is the bug: old code sent DOWN again).
    let release = r.reconcile(shift: false, control: false, option: false, command: false, mode: .cmdAsCtrl)
    check(release.count == 1 && sc(release[0])! == (0x2A, false, false), "release Shift => Shift UP (not another down)")
    check(r.held.isEmpty, "held empty after release")
}
do {
    // Holding Shift across an unrelated reconcile must NOT re-send (no duplicate downs).
    var r = ModifierReconciler()
    _ = r.reconcile(shift: true, control: false, option: false, command: false, mode: .cmdAsCtrl)
    let again = r.reconcile(shift: true, control: false, option: false, command: false, mode: .cmdAsCtrl)
    check(again.isEmpty, "re-reporting Shift held => no duplicate events")
}
do {
    // cmdAsCtrl: Command maps to Left-Ctrl (0x1D).
    var r = ModifierReconciler()
    let cmd = r.reconcile(shift: false, control: false, option: false, command: true, mode: .cmdAsCtrl)
    check(cmd.count == 1 && sc(cmd[0])! == (0x1D, false, true), "cmdAsCtrl: Command => Left-Ctrl down")

    // Adding Control while Command held must NOT send a second Ctrl (deduped).
    let both = r.reconcile(shift: false, control: true, option: false, command: true, mode: .cmdAsCtrl)
    check(both.isEmpty, "cmdAsCtrl: Ctrl+Cmd share one scancode (no double)")

    // Releasing Command while Control still held must KEEP Ctrl down (no premature up).
    let dropCmd = r.reconcile(shift: false, control: true, option: false, command: false, mode: .cmdAsCtrl)
    check(dropCmd.isEmpty && r.held.contains(.init(code: 0x1D, extended: false)),
          "cmdAsCtrl: release Cmd with Ctrl held keeps Ctrl down")
}
do {
    // literal mode: Command => Left-Win (extended 0x5B); Control => Left-Ctrl.
    var r = ModifierReconciler()
    let cmd = r.reconcile(shift: false, control: false, option: false, command: true, mode: .literal)
    check(cmd.count == 1 && sc(cmd[0])! == (0x5B, true, true), "literal: Command => Left-Win (E0 5B) down")
}
do {
    // Focus-loss: releaseAll drops every held modifier with key-UPs.
    var r = ModifierReconciler()
    _ = r.reconcile(shift: true, control: true, option: true, command: false, mode: .cmdAsCtrl)
    let cleared = r.releaseAll(mode: .cmdAsCtrl)
    check(cleared.allSatisfy { $0.down == false } && r.held.isEmpty, "focus loss => all modifiers released")
}

print("== ScancodeKeyboardMapper (sanity) ==")
do {
    let m = ScancodeKeyboardMapper(modifierMode: .cmdAsCtrl)
    // 'a' (keyCode 0) -> Set-1 0x1E, not extended.
    let a = m.actions(forKeyCode: 0, characters: "a", modifiers: 0, keyDown: true)
    check(a.count == 1 && sc(a[0])! == (0x1E, false, true), "keyCode 0 ('a') => 0x1E down")
    // Right arrow (keyCode 124) -> extended 0x4D.
    let right = m.actions(forKeyCode: 124, characters: nil, modifiers: 0, keyDown: true)
    check(right.count == 1 && sc(right[0])! == (0x4D, true, true), "Right arrow => extended 0x4D")
    // Ctrl-Alt-Del sequence: 6 actions, press then release, ends with Ctrl up.
    let cad = m.ctrlAltDelActions()
    check(cad.count == 6 && cad.first?.down == true && cad.last?.down == false, "Ctrl-Alt-Del press/release sequence")
}

print("== SpecialKeySequence (F-4) ==")
do {
    // Chords press downs in order and release in reverse (Alt held around the Tab tap).
    let altTab = SpecialKeySequence.altTab.actions
    check(altTab.count == 4
          && sc(altTab[0])! == (0x38, false, true) && sc(altTab[1])! == (0x0F, false, true)
          && sc(altTab[2])! == (0x0F, false, false) && sc(altTab[3])! == (0x38, false, false),
          "Alt-Tab: Alt down, Tab tap, Alt up")
    let winL = SpecialKeySequence.winL.actions
    check(winL.count == 4 && sc(winL[0])! == (0x5B, true, true) && sc(winL[3])! == (0x5B, true, false),
          "Win+L: Win (E0-5B) held around L")
    check(SpecialKeySequence.printScreen.actions.first.flatMap(sc).map { $0 == (0x37, true, true) } == true,
          "PrintScreen => extended 0x37")
    check(SpecialKeySequence.functionKey(12).first.flatMap(sc)?.0 == 0x58, "F12 => 0x58")
    check(SpecialKeySequence.functionKey(13).isEmpty, "F13 out of range => no-op")
}

print("== Per-connection modifier override (F-10) ==")
do {
    // Back-compat: a legacy profile JSON saved before the field existed decodes with
    // the default .useGlobal (no schemaVersion bump — the field is simply optional).
    let legacy = #"{"name":"old","host":"h","port":3389,"username":"u"}"#.data(using: .utf8)!
    let conn = try? JSONDecoder().decode(Connection.self, from: legacy)
    check(conn != nil && conn?.modifierOverride == .useGlobal,
          "legacy connection JSON (no field) => .useGlobal")

    // Resolution: an explicit per-connection override wins; .useGlobal defers.
    check(ModifierModeOverride.useGlobal.resolved(global: .literal) == .literal,
          ".useGlobal resolves to the global mode")
    check(ModifierModeOverride.cmdAsCtrl.resolved(global: .literal) == .cmdAsCtrl,
          ".cmdAsCtrl override beats a .literal global")
    check(ModifierModeOverride.literal.resolved(global: .cmdAsCtrl) == .literal,
          ".literal override beats a .cmdAsCtrl global")

    // An explicit override survives an encode/decode round-trip.
    var c = Connection(name: "n", host: "h", username: "u")
    c.modifierOverride = .literal
    let back = (try? JSONEncoder().encode(c))
        .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    check(back?.modifierOverride == .literal, "explicit override round-trips")
}

print("\n== Keyboard layout presets + key overrides (F-15) ==")
do {
    // Back-compat: legacy connection JSON (neither field) decodes to .auto layout and
    // an empty override list (no schema bump).
    let legacy = #"{"name":"old","host":"h","port":3389,"username":"u"}"#.data(using: .utf8)!
    let conn = try? JSONDecoder().decode(Connection.self, from: legacy)
    check(conn?.keyboardLayout == .auto, "legacy connection JSON (no field) => .auto layout")
    check(conn?.keyOverrides.isEmpty == true, "legacy connection JSON (no field) => no overrides")

    // An unknown layout raw string (newer build / hand-edited store) degrades to .auto
    // instead of failing the whole load.
    let unknown = #"{"name":"n","host":"h","port":3389,"username":"u","keyboardLayout":"klingon"}"#
        .data(using: .utf8)!
    check((try? JSONDecoder().decode(Connection.self, from: unknown))?.keyboardLayout == .auto,
          "unknown layout raw value degrades to .auto (load survives)")

    // Layout raw KBD_* ids match /opt/homebrew/include/freerdp3/freerdp/locale/keyboard.h.
    check(KeyboardLayoutPreset.auto.kbdID == 0, ".auto => 0 (bridge leaves the setting unset)")
    let expected: [(KeyboardLayoutPreset, UInt32, String)] = [
        (.us, 0x409, "KBD_US"), (.usInternational, 0x20409, "KBD_UNITED_STATES_INTERNATIONAL"),
        (.uk, 0x809, "KBD_UNITED_KINGDOM"), (.german, 0x407, "KBD_GERMAN"),
        (.french, 0x40C, "KBD_FRENCH"), (.spanish, 0x40A, "KBD_SPANISH"),
        (.italian, 0x410, "KBD_ITALIAN"), (.swissGerman, 0x807, "KBD_SWISS_GERMAN"),
        (.swissFrench, 0x100C, "KBD_SWISS_FRENCH"), (.danish, 0x406, "KBD_DANISH"),
        (.swedish, 0x41D, "KBD_SWEDISH"), (.norwegian, 0x414, "KBD_NORWEGIAN"),
        (.dutch, 0x413, "KBD_DUTCH"), (.belgianFrench, 0x80C, "KBD_BELGIAN_FRENCH"),
        (.portuguese, 0x816, "KBD_PORTUGUESE"),
        (.brazilian, 0x416, "KBD_PORTUGUESE_BRAZILIAN_ABNT"),
        (.japanese, 0x411, "KBD_JAPANESE"), (.korean, 0x412, "KBD_KOREAN"),
        (.canadianFrench, 0x1009, "KBD_CANADIAN_FRENCH")
    ]
    check(expected.allSatisfy { $0.0.kbdID == $0.1 },
          "all 19 non-auto layout ids match the FreeRDP header KBD_* constants")
    check(Set(KeyboardLayoutPreset.allCases).count == expected.count + 1,
          "preset list is exactly .auto + the 19 checked layouts")
    check(KeyboardLayoutPreset.pickerOrder.first == .auto
          && Set(KeyboardLayoutPreset.pickerOrder) == Set(KeyboardLayoutPreset.allCases),
          "picker order puts Automatic first and includes every preset once")

    // Explicit layout + overrides survive an encode/decode round-trip.
    var c = Connection(name: "n", host: "h", username: "u")
    c.keyboardLayout = .german
    c.keyOverrides = [KeyOverride(macKeyCode: 10, scancode: 0x29, extended: false)]
    let back = (try? JSONEncoder().encode(c))
        .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    check(back?.keyboardLayout == .german && back?.keyOverrides == c.keyOverrides,
          "explicit layout + override list round-trip")

    // The 32-entry cap is enforced in the MODEL: on init and on decode.
    let many = (0..<40).map { KeyOverride(macKeyCode: UInt16($0), scancode: 0x1E) }
    let capped = Connection(name: "n", host: "h", username: "u", keyOverrides: many)
    check(capped.keyOverrides.count == Connection.maxKeyOverrides,
          "init clamps the override list to \(Connection.maxKeyOverrides)")
    let entries = (0..<40).map { #"{"macKeyCode":\#($0),"scancode":30,"extended":false}"# }
        .joined(separator: ",")
    let bigJSON = #"{"name":"n","host":"h","port":3389,"username":"u","keyOverrides":[\#(entries)]}"#
        .data(using: .utf8)!
    check((try? JSONDecoder().decode(Connection.self, from: bigJSON))?.keyOverrides.count
          == Connection.maxKeyOverrides,
          "decode clamps a hand-edited 40-entry override list to \(Connection.maxKeyOverrides)")

    // Mapper: an override wins over the standard table for ITS keycode only — the
    // classic ISO remap: § (keyCode 10, normally 0x56) → backtick 0x29.
    let mapper = ScancodeKeyboardMapper(modifierMode: .cmdAsCtrl,
                                        keyOverrides: [KeyOverride(macKeyCode: 10, scancode: 0x29)])
    let ovDown = mapper.actions(forKeyCode: 10, characters: "§", modifiers: 0, keyDown: true)
    check(ovDown.count == 1 && sc(ovDown[0])! == (0x29, false, true),
          "override wins over the standard table (§ key => 0x29 down)")
    let ovUp = mapper.actions(forKeyCode: 10, characters: "§", modifiers: 0, keyDown: false)
    check(ovUp.count == 1 && sc(ovUp[0])! == (0x29, false, false), "override key-up mirrors down")
    let aKey = mapper.actions(forKeyCode: 0, characters: "a", modifiers: 0, keyDown: true)
    check(aKey.count == 1 && sc(aKey[0])! == (0x1E, false, true),
          "non-overridden keys fall through to the standard table (A => 0x1E)")

    // An explicit override also beats the unicode fallback, and extended flags carry.
    mapper.useUnicodeFallback = true
    let ovUni = mapper.actions(forKeyCode: 10, characters: "§", modifiers: 0, keyDown: true)
    check(ovUni.count == 1 && sc(ovUni[0])! == (0x29, false, true),
          "override beats the unicode fallback")
    mapper.useUnicodeFallback = false
    mapper.setKeyOverrides([KeyOverride(macKeyCode: 0, scancode: 0x5B, extended: true)])
    let ext = mapper.actions(forKeyCode: 0, characters: "a", modifiers: 0, keyDown: true)
    check(ext.count == 1 && sc(ext[0])! == (0x5B, true, true),
          "extended flag carries through an override (A => E0-5B)")
    let iso = mapper.actions(forKeyCode: 10, characters: "§", modifiers: 0, keyDown: true)
    check(iso.count == 1 && sc(iso[0])! == (0x56, false, true),
          "setKeyOverrides replaces the previous list (§ back to standard 0x56)")
}

print("== ReconnectPolicy (F-20) ==")
do {
    // Back-compat: legacy connection JSON (no reconnectPolicy) decodes to the default
    // policy — enabled, 1 attempt, 5 s — i.e. exactly today's global behavior.
    let legacy = #"{"name":"old","host":"h","port":3389,"username":"u"}"#.data(using: .utf8)!
    let conn = try? JSONDecoder().decode(Connection.self, from: legacy)
    check(conn?.reconnectPolicy == ReconnectPolicy(enabled: true, maxAttempts: 1, minDelaySeconds: 5),
          "legacy connection JSON (no field) => default policy (enabled, 1 attempt, 5 s)")

    // Clamping on init: attempts 99 -> 5, delay 1 -> 5 (the LIFE-3 floor can be raised,
    // never lowered), delay 999 -> 60.
    let wild = ReconnectPolicy(enabled: true, maxAttempts: 99, minDelaySeconds: 1)
    check(wild.maxAttempts == 5, "init clamp: attempts 99 => 5")
    check(wild.minDelaySeconds == 5, "init clamp: delay 1 => 5 (floor is never lowered)")
    check(ReconnectPolicy(minDelaySeconds: 999).minDelaySeconds == 60, "init clamp: delay 999 => 60")

    // Clamping on decode too, so a hand-edited store can't exceed the bounds.
    let editedJSON = #"{"name":"n","host":"h","port":3389,"username":"u","reconnectPolicy":{"enabled":true,"maxAttempts":99,"minDelaySeconds":1}}"#.data(using: .utf8)!
    let edited = try? JSONDecoder().decode(Connection.self, from: editedJSON)
    check(edited?.reconnectPolicy.maxAttempts == 5 && edited?.reconnectPolicy.minDelaySeconds == 5,
          "decode clamp: attempts 99 => 5, delay 1 => 5")

    // 0 attempts == disabled, regardless of the toggle.
    check(ReconnectPolicy(enabled: true, maxAttempts: 0).effectiveMaxAttempts == 0,
          "maxAttempts 0 => effective budget 0 (disabled)")
    check(ReconnectPolicy(enabled: false, maxAttempts: 3).effectiveMaxAttempts == 0,
          "enabled == false => effective budget 0")

    // An explicit policy survives an encode/decode round-trip.
    var c = Connection(name: "n", host: "h", username: "u")
    c.reconnectPolicy = ReconnectPolicy(enabled: true, maxAttempts: 3, minDelaySeconds: 20)
    let back = (try? JSONEncoder().encode(c))
        .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    check(back?.reconnectPolicy == ReconnectPolicy(enabled: true, maxAttempts: 3, minDelaySeconds: 20),
          "explicit policy round-trips")

    // Backoff curve honors the policy floor: raised floor lifts every delay AND the cap
    // (max(16, floor)); the default floor keeps the original 5,5,5,8,16 curve.
    check((1...5).map { ReconnectDecider.backoffDelaySeconds(forAttempt: $0) } == [5, 5, 5, 8, 16],
          "default curve stays 5,5,5,8,16")
    check((1...5).map { ReconnectDecider.backoffDelaySeconds(forAttempt: $0, minDelaySeconds: 10) }
            == [10, 10, 10, 10, 16],
          "floor 10 => 10,10,10,10,16")
    check(ReconnectDecider.backoffDelaySeconds(forAttempt: 1, minDelaySeconds: 30) == 30
          && ReconnectDecider.backoffDelaySeconds(forAttempt: 5, minDelaySeconds: 30) == 30,
          "floor 30 (> 16 cap) => flat 30")
    check(ReconnectDecider.backoffDelaySeconds(forAttempt: 1, minDelaySeconds: 1) == 5,
          "floor below 5 is ignored (LIFE-3: never under 5 s)")
}

print("== Stay awake (F-26) ==")
do {
    // Cap clamp on init: 60...3600 s (the cap is what keeps the feature from being an
    // indefinite lock-policy bypass, so it can never be configured away).
    check(Connection(name: "n", host: "h", username: "u", stayAwakeCapSeconds: 30)
            .stayAwakeCapSeconds == 60,
          "init clamp: cap 30 => 60 (1 min floor)")
    check(Connection(name: "n", host: "h", username: "u", stayAwakeCapSeconds: 99999)
            .stayAwakeCapSeconds == 3600,
          "init clamp: cap 99999 => 3600 (1 h ceiling)")
    check(Connection(name: "n", host: "h", username: "u").stayAwakeCapSeconds == 300,
          "default cap is 300 s (5 min)")

    // Back-compat: legacy connection JSON (no field) decodes to the 300 s default.
    let legacy = #"{"name":"old","host":"h","port":3389,"username":"u"}"#.data(using: .utf8)!
    check((try? JSONDecoder().decode(Connection.self, from: legacy))?.stayAwakeCapSeconds == 300,
          "legacy connection JSON (no field) => 300 s default")

    // Clamp on decode too, so a hand-edited store can't stretch the cap.
    let edited = #"{"name":"n","host":"h","port":3389,"username":"u","stayAwakeCapSeconds":99999}"#.data(using: .utf8)!
    check((try? JSONDecoder().decode(Connection.self, from: edited))?.stayAwakeCapSeconds == 3600,
          "decode clamp: cap 99999 => 3600")

    // An explicit cap survives an encode/decode round-trip.
    var c = Connection(name: "n", host: "h", username: "u")
    c.stayAwakeCapSeconds = 600
    let back = (try? JSONEncoder().encode(c))
        .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    check(back?.stayAwakeCapSeconds == 600, "explicit cap round-trips")

    // Tick-decision truth table (SEC invariant: injection ONLY when armed, with time
    // remaining, connected, and the user idle >= the tick interval).
    func inject(armed: Bool = true, remaining: Double = 120, connected: Bool = true,
                idle: Double = 45) -> Bool {
        StayAwake.shouldInjectKeepAlive(armed: armed, remainingSeconds: remaining,
                                        connected: connected, secondsSinceRealInput: idle,
                                        tickIntervalSeconds: 45)
    }
    check(inject(), "armed + remaining + connected + idle >= interval => inject")
    check(!inject(armed: false), "disarmed => never inject")
    check(!inject(remaining: 0), "cap expired (remaining 0) => never inject")
    check(!inject(remaining: -5), "cap past due => never inject")
    check(!inject(connected: false), "disconnected => never inject")
    check(!inject(idle: 10), "real input 10 s ago (< interval) => never inject (no splice into typing)")
    check(inject(idle: 45), "idle exactly the interval => inject (boundary)")
    check(!inject(idle: 44.9), "idle just under the interval => no inject (boundary)")
    check(StayAwake.tickIntervalSeconds == 45, "tick interval is 45 s (30-60 s per design note)")
}

print("== ExperienceSettings (F-2 / F-17 low-bandwidth) ==")
do {
    // Back-compat: legacy connection JSON (no field) decodes to profile .auto…
    let legacy = #"{"name":"old","host":"h","port":3389,"username":"u"}"#.data(using: .utf8)!
    let conn = try? JSONDecoder().decode(Connection.self, from: legacy)
    check(conn?.experience == .default && conn?.experience.profile == .auto,
          "legacy connection JSON (no field) => .auto profile")
    // …and .auto resolves to nil == "override nothing at the bridge" (the guarantee
    // that pre-F-2 profiles connect with bit-for-bit the same settings as before).
    check(ExperienceSettings.default.resolved() == nil,
          ".auto resolved() == nil (no override; legacy behavior preserved)")

    // Preset resolution table. lowBandwidth: everything off + 16-bit + BROADBAND_LOW.
    let low = ExperienceSettings(profile: .lowBandwidth).resolved()
    check(low != nil && low!.showWallpaper == false && low!.fontSmoothing == false
          && low!.fullWindowDrag == false && low!.menuAnimations == false
          && low!.themes == false && low!.colorDepth == .depth16
          && low!.connectionType == .broadbandLow,
          ".lowBandwidth => all off + 16-bit + CONNECTION_TYPE_BROADBAND_LOW")
    // lan: everything on + 32-bit + LAN.
    let lan = ExperienceSettings(profile: .lan).resolved()
    check(lan != nil && lan!.showWallpaper && lan!.fontSmoothing && lan!.fullWindowDrag
          && lan!.menuAnimations && lan!.themes && lan!.colorDepth == .depth32
          && lan!.connectionType == .lan,
          ".lan => all on + 32-bit + CONNECTION_TYPE_LAN")
    // broadband: middle ground — wallpaper/drag/anims off, smoothing/themes on, 32-bit.
    let bb = ExperienceSettings(profile: .broadband).resolved()
    check(bb != nil && bb!.showWallpaper == false && bb!.fontSmoothing
          && bb!.fullWindowDrag == false && bb!.menuAnimations == false && bb!.themes
          && bb!.colorDepth == .depth32 && bb!.connectionType == .broadbandHigh,
          ".broadband => wallpaper off, smoothing+themes on, 32-bit, BROADBAND_HIGH")
    // Custom resolves to exactly the stored knobs (connection type stays autodetect).
    let custom = ExperienceSettings(profile: .custom, showWallpaper: true,
                                    fontSmoothing: false, fullWindowDrag: true,
                                    menuAnimations: false, themes: true,
                                    colorDepth: .depth24).resolved()
    check(custom != nil && custom!.showWallpaper && !custom!.fontSmoothing
          && custom!.fullWindowDrag && !custom!.menuAnimations && custom!.themes
          && custom!.colorDepth == .depth24 && custom!.connectionType == .autodetect,
          ".custom => stored knobs verbatim + AUTODETECT connection type")
    // Presets never disable network autodetect (keeps quality-indicator RTT/bandwidth).
    check([low, lan, bb, custom].allSatisfy { $0?.networkAutoDetect == true },
          "every profile keeps NetworkAutoDetect on (quality stats preserved)")

    // Custom knobs survive an encode/decode round-trip on Connection.
    var c = Connection(name: "n", host: "h", username: "u")
    c.experience = ExperienceSettings(profile: .custom, showWallpaper: true,
                                      fontSmoothing: true, fullWindowDrag: false,
                                      menuAnimations: true, themes: false,
                                      colorDepth: .depth16)
    let back = (try? JSONEncoder().encode(c))
        .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    check(back?.experience == c.experience, "custom knobs round-trip")

    // Tolerant decode: an unknown profile string or bogus color depth from a
    // hand-edited store degrades to the safe defaults instead of failing the load.
    let edited = #"{"name":"n","host":"h","port":3389,"username":"u","experience":{"profile":"warp9","colorDepth":15}}"#.data(using: .utf8)!
    let ec = try? JSONDecoder().decode(Connection.self, from: edited)
    check(ec?.experience.profile == .auto && ec?.experience.colorDepth == .depth32,
          "hand-edited garbage (profile/depth) => .auto / 32-bit, load succeeds")
}

print("== ReconnectDecider (LIFE-4) ==")
do {
    let d = ReconnectDecider()

    // A link that flaps WITHOUT ever reaching .connected counts up to the cap, then stops.
    var attempt = 0
    var iterations = 0
    while case let .retryNow(n) = d.decide(attempt: attempt, max: 5,
                                           connectedSinceReset: false, cause: nil,
                                           pendingCert: false), iterations < 100 {
        attempt = n; iterations += 1
    }
    check(attempt == 5 && iterations == 5, "flap-without-connect counts to cap (5) then...")
    check(d.decide(attempt: 5, max: 5, connectedSinceReset: false, cause: nil, pendingCert: false) == .stop,
          "...stops at the cap (no unbounded flap)")

    // A session that reconnected re-earns a fresh budget exactly once.
    check(d.decide(attempt: 5, max: 5, connectedSinceReset: true, cause: nil, pendingCert: false)
            == .retryNow(newAttempt: 1),
          "connect-then-drop re-earns budget (attempt resets to 1)")

    // Non-retryable causes always stop, regardless of budget.
    check(d.decide(attempt: 0, max: 5, connectedSinceReset: true, cause: .certificateRejected, pendingCert: false) == .stop,
          "cert-rejected cause stops")
    check(d.decide(attempt: 0, max: 5, connectedSinceReset: true, cause: .authenticationFailed, pendingCert: false) == .stop,
          "auth-failed cause stops")
    check(d.decide(attempt: 0, max: 5, connectedSinceReset: true, cause: .mfaRequired, pendingCert: false) == .stop,
          "mfa-required cause stops")

    // A pending cert review never auto-retries (LIFE-5 defense-in-depth).
    check(d.decide(attempt: 0, max: 5, connectedSinceReset: false, cause: nil, pendingCert: true) == .stop,
          "pending cert review stops")

    // A plain network drop (nil cause) with budget remaining retries.
    check(d.decide(attempt: 1, max: 5, connectedSinceReset: false, cause: nil, pendingCert: false)
            == .retryNow(newAttempt: 2),
          "network drop with budget => retry")

    // Default policy cap is ONE automatic retry: a drop yields a single auto retry,
    // then stops so the manual "Reconnect" takes over.
    check(d.decide(attempt: 0, max: 1, connectedSinceReset: false, cause: nil, pendingCert: false)
            == .retryNow(newAttempt: 1),
          "max=1: first drop => one automatic retry")
    check(d.decide(attempt: 1, max: 1, connectedSinceReset: false, cause: nil, pendingCert: false) == .stop,
          "max=1: after the single retry => stop (then manual)")

    // F-20: the decider honors a per-connection budget — 3 drops with budget 3 retry,
    // the 4th stops.
    var att = 0
    var retries = 0
    for _ in 1...3 {
        if case let .retryNow(n) = d.decide(attempt: att, max: 3, connectedSinceReset: false,
                                            cause: nil, pendingCert: false) {
            att = n; retries += 1
        }
    }
    check(retries == 3 && att == 3, "max=3: three drops => three retries")
    check(d.decide(attempt: att, max: 3, connectedSinceReset: false, cause: nil, pendingCert: false) == .stop,
          "max=3: fourth drop => stop")
    // Policy disabled (effective budget 0) => never retries.
    check(d.decide(attempt: 0, max: 0, connectedSinceReset: false, cause: nil, pendingCert: false) == .stop,
          "max=0 (policy disabled) => stop immediately")
}

print("== Proactive one-shot budget (F-24) ==")
do {
    let d = ReconnectDecider()

    // Blind budget exhausted + network-return => ONE proactive attempt…
    check(d.decideProactive(proactiveUsedThisEpisode: false, policyMaxAttempts: 1,
                            cause: nil, pendingCert: false) == .retry,
          "blind budget exhausted + network-return => one proactive attempt")
    // …but a second network-return in the SAME episode gets nothing.
    check(d.decideProactive(proactiveUsedThisEpisode: true, policyMaxAttempts: 1,
                            cause: nil, pendingCert: false) == .stop,
          "second network-return in the same episode => none")
    // A successful connect resets the episode (flag cleared) => the shot is re-earned.
    check(d.decideProactive(proactiveUsedThisEpisode: false, policyMaxAttempts: 1,
                            cause: nil, pendingCert: false) == .retry,
          "successful connect resets the episode => shot re-earned")
    // Same LIFE-3/LIFE-5 rules as the blind path: cert-cause failures and pending
    // reviews never fire, and a disabled policy gets no proactive attempt either.
    check(d.decideProactive(proactiveUsedThisEpisode: false, policyMaxAttempts: 1,
                            cause: .certificateRejected, pendingCert: false) == .stop,
          "cert-cause failure => no proactive attempt")
    check(d.decideProactive(proactiveUsedThisEpisode: false, policyMaxAttempts: 1,
                            cause: .authenticationFailed, pendingCert: false) == .stop,
          "auth-failed cause => no proactive attempt")
    check(d.decideProactive(proactiveUsedThisEpisode: false, policyMaxAttempts: 1,
                            cause: nil, pendingCert: true) == .stop,
          "pending cert review => no proactive attempt")
    check(d.decideProactive(proactiveUsedThisEpisode: false, policyMaxAttempts: 0,
                            cause: nil, pendingCert: false) == .stop,
          "policy disabled (0 attempts) => no proactive attempt")
}

print("== authDirective mapping (LIFE-3, relaxed: one biometric-free auto retry) ==")
do {
    // biometricEveryConnect: user-initiated prompts every time (forceFresh) but SEEDS a
    // reusable context; the single automatic reconnect reuses it with no new prompt.
    let userEC = CredentialPolicy.biometricEveryConnect.authDirective(for: .userInitiated)
    check(userEC.reuseSeconds == KeychainCredentialVault.maxReuseSeconds && userEC.forceFreshPrompt,
          ".biometricEveryConnect/userInitiated => seed reusable context + force fresh prompt")
    let autoEC = CredentialPolicy.biometricEveryConnect.authDirective(for: .automaticReconnect)
    check(autoEC.reuseSeconds == KeychainCredentialVault.maxReuseSeconds && !autoEC.forceFreshPrompt,
          ".biometricEveryConnect/automaticReconnect => reuse cached context (no fresh prompt)")
    // biometricReuse / savedNoBiometric reuse within window for both reasons.
    let brU = CredentialPolicy.biometricReuse(seconds: 45).authDirective(for: .userInitiated)
    check(brU.reuseSeconds == 45 && !brU.forceFreshPrompt, ".biometricReuse(45)/userInitiated => (45, reuse)")
    let brA = CredentialPolicy.biometricReuse(seconds: 45).authDirective(for: .automaticReconnect)
    check(brA.reuseSeconds == 45 && !brA.forceFreshPrompt, ".biometricReuse(45)/automaticReconnect => (45, reuse)")
    let snb = CredentialPolicy.savedNoBiometric.authDirective(for: .automaticReconnect)
    check(snb.reuseSeconds == KeychainCredentialVault.maxReuseSeconds && !snb.forceFreshPrompt,
          ".savedNoBiometric => (maxReuseSeconds, reuse)")
}

print("== RDPError code mapping (LIFE-5) ==")
do {
    check(RDPError.from(code: 0x0002000C, rawMessage: "").cause == .protocolError,
          "0x0002000C => .protocolError (FreeRDP security negotiation failure)")
    check(RDPError.from(code: 0x0002000D, rawMessage: "").cause == .connectionFailed,
          "0x0002000D => .connectionFailed (FreeRDP transport failure)")
    check(RDPError.from(code: RDPError.bridgeCertRejectedCode, rawMessage: "").cause == .certificateRejected,
          "bridge-private cert rejection => .certificateRejected")
    check(RDPError.from(code: RDPError.bridgeIncompleteCredentialsCode, rawMessage: "").cause == .credentialsIncomplete,
          "bridge-private missing username => .credentialsIncomplete")
    check(ReconnectDecider.isRetryable(.certificateRejected) == false,
          "shouldAutoRetry excludes .certificateRejected")
    check(ReconnectDecider.isRetryable(.credentialsIncomplete) == false,
          "shouldAutoRetry excludes incomplete credentials")
}

print("== FileConnectionStore persistence (DATA-1 / DATA-2) ==")
do {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidateCore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // DATA-2: a v1 envelope loads.
    do {
        let dir = tempDir()
        try? #"{"schemaVersion":1,"connections":[]}"#
            .data(using: .utf8)!.write(to: dir.appendingPathComponent("connections.json"))
        let store = FileConnectionStore(directory: dir)
        check(store.connections.isEmpty && store.lastError == nil, "DATA-2: v1 envelope loads (no error)")
    }

    // DATA-2: a legacy bare array loads and is rewritten as an envelope.
    do {
        let dir = tempDir()
        let url = dir.appendingPathComponent("connections.json")
        try? "[]".data(using: .utf8)!.write(to: url)
        let store = FileConnectionStore(directory: dir)
        let rewritten = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(store.lastError == nil && rewritten.contains("schemaVersion"),
              "DATA-2: legacy array loads + rewrites as versioned envelope")
    }

    // DATA-1: garbage => empty + .loadCorrupt + a sidecar holding the original bytes.
    do {
        let dir = tempDir()
        let url = dir.appendingPathComponent("connections.json")
        try? "}{ not json".data(using: .utf8)!.write(to: url)
        let store = FileConnectionStore(directory: dir)
        var backupOK = false
        if case let .loadCorrupt(backupURL) = store.lastError, let b = backupURL {
            let bytes = (try? String(contentsOf: b, encoding: .utf8)) ?? ""
            backupOK = bytes == "}{ not json"
        }
        check(store.connections.isEmpty && backupOK,
              "DATA-1: garbage => empty + .loadCorrupt + sidecar holds original bytes")
    }
}

print("== FileCertificateTrustStore persistence (DATA-1 / DATA-2) ==")
do {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidateCore-trust-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    let sample = CertInfo(host: "h", port: 3389, commonName: "cn", subject: "s", issuer: "i",
                          fingerprintSHA256: "AA", hostMismatch: false, changed: false)

    // DATA-2: legacy bare dictionary loads + rewrites as an envelope.
    do {
        let dir = tempDir()
        let url = dir.appendingPathComponent("trust.json")
        try? #"{"h:3389":"AA"}"#.data(using: .utf8)!.write(to: url)
        let store = FileCertificateTrustStore(directory: dir)
        let rewritten = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(store.evaluate(sample) == .trusted && rewritten.contains("version"),
              "DATA-2: legacy trust dict loads + rewrites as versioned envelope")
    }

    // DATA-2: a versioned envelope loads.
    do {
        let dir = tempDir()
        try? #"{"version":1,"pins":{"h:3389":"AA"}}"#
            .data(using: .utf8)!.write(to: dir.appendingPathComponent("trust.json"))
        let store = FileCertificateTrustStore(directory: dir)
        check(store.evaluate(sample) == .trusted, "DATA-2: v1 trust envelope loads")
    }

    // DATA-1: garbage => empty + .loadCorrupt + sidecar.
    do {
        let dir = tempDir()
        try? "}{ nope".data(using: .utf8)!.write(to: dir.appendingPathComponent("trust.json"))
        let store = FileCertificateTrustStore(directory: dir)
        var corrupt = false
        if case .loadCorrupt = store.lastError { corrupt = true }
        check(store.evaluate(sample) == .unknown && corrupt,
              "DATA-1: garbage trust file => empty + .loadCorrupt")
    }
}

print("== Gateway credential key scheme (F-6) ==")
do {
    // Pure key derivation — no vault instance (instantiating would probe the Keychain).
    let a = UUID(), b = UUID()
    let priA = KeychainCredentialVault.keychainAccount(for: a, kind: .primary)
    let gwA  = KeychainCredentialVault.keychainAccount(for: a, kind: .gateway)
    let priB = KeychainCredentialVault.keychainAccount(for: b, kind: .primary)
    let gwB  = KeychainCredentialVault.keychainAccount(for: b, kind: .gateway)

    check(priA == a.uuidString, "primary account == bare UUID (pre-F-6 items keep loading)")
    check(gwA != priA, "gateway key for A != primary key for A")
    check(gwA != gwB, "gateway key for A != gateway key for B")
    check(gwA != priB && gwB != priA, "gateway key never collides with another connection's primary key")
    check(UUID(uuidString: gwA) == nil,
          "a gateway account can never parse as a UUID (no primary/gateway ambiguity)")
    check(gwA == a.uuidString + ":gateway", "gateway key derivation is stable (uuid + \":gateway\")")
}

print("== GatewaySettings back-compat (F-6) ==")
do {
    // Legacy connection JSON with a gateway but NO flag decodes to
    // useSeparateCredentials == false — today's behavior (gateway uses main creds).
    let legacy = #"{"name":"old","host":"h","port":3389,"username":"u","gateway":{"hostname":"gw.example.com","port":443,"username":"gwuser"}}"#
        .data(using: .utf8)!
    let conn = try? JSONDecoder().decode(Connection.self, from: legacy)
    check(conn?.gateway?.useSeparateCredentials == false,
          "legacy gateway JSON (no flag) => useSeparateCredentials false")
    check(conn?.gateway?.hostname == "gw.example.com" && conn?.gateway?.username == "gwuser",
          "legacy gateway fields still decode intact")

    // The flag round-trips when set.
    var c = Connection(name: "n", host: "h", username: "u")
    c.gateway = GatewaySettings(hostname: "gw", port: 4443, username: "g",
                                useSeparateCredentials: true)
    let back = (try? JSONEncoder().encode(c))
        .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    check(back?.gateway?.useSeparateCredentials == true && back?.gateway?.port == 4443,
          "useSeparateCredentials round-trips")
}

print("== Trust-store pin records (F-11) ==")
do {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidateCore-pins-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    let rich = CertInfo(host: "h", port: 3389, commonName: "cn", subject: "CN=srv, O=Corp",
                        issuer: "CN=CA, O=Corp", fingerprintSHA256: "BB",
                        hostMismatch: false, changed: false)

    // Back-compat: a v1 pin (fingerprint-only) loads; the record surfaces the
    // fingerprint with nil context fields (old pins never fail the load).
    do {
        let dir = tempDir()
        try? #"{"version":1,"pins":{"h:3389":"AA"}}"#
            .data(using: .utf8)!.write(to: dir.appendingPathComponent("trust.json"))
        let store = FileCertificateTrustStore(directory: dir)
        let rec = store.pinnedRecord(host: "h", port: 3389)
        check(rec?.fingerprintSHA256 == "AA" && rec?.subject == nil && rec?.issuer == nil,
              "v1 pin (no context fields) loads; fingerprint kept, context nil")
        check(store.evaluate(rich) == .changed(previousFingerprint: "AA"),
              "changed-detection still works against a migrated v1 pin")
    }

    // A new pin persists the richer record and round-trips through a store reload.
    do {
        let dir = tempDir()
        FileCertificateTrustStore(directory: dir).pin(rich)
        let reloaded = FileCertificateTrustStore(directory: dir)
        let rec = reloaded.pinnedRecord(host: "h", port: 3389)
        check(rec?.fingerprintSHA256 == "BB" && rec?.subject == "CN=srv, O=Corp"
              && rec?.issuer == "CN=CA, O=Corp" && rec?.commonName == "cn"
              && rec?.pinnedAt != nil,
              "new pin round-trips fingerprint + subject/issuer/CN/pinnedAt")
        check(reloaded.evaluate(rich) == .trusted, "richer pin still evaluates .trusted")
    }

    // Legacy bare dictionary still migrates (pre-versioning format, unchanged check).
    do {
        let dir = tempDir()
        try? #"{"h:3389":"AA"}"#.data(using: .utf8)!
            .write(to: dir.appendingPathComponent("trust.json"))
        let store = FileCertificateTrustStore(directory: dir)
        check(store.pinnedRecord(host: "h", port: 3389)?.fingerprintSHA256 == "AA",
              "pre-versioning bare dict migrates to a pin record")
    }

    // "Forget saved certificate" (editor Security section): removing a pin must return
    // the host to first-use review AND survive a reload — a pin that comes back after a
    // restart would silently re-trust a certificate the user explicitly revoked.
    do {
        let dir = tempDir()
        let store = FileCertificateTrustStore(directory: dir)
        store.pin(rich)
        check(store.evaluate(rich) == .trusted, "pin before forget => .trusted")
        store.remove(host: "h", port: 3389)
        check(store.evaluate(rich) == .unknown,
              "forget => .unknown (next connect re-runs first-use review)")
        check(store.pinnedRecord(host: "h", port: 3389) == nil,
              "forget clears the record the editor reads")
        check(FileCertificateTrustStore(directory: dir).evaluate(rich) == .unknown,
              "forget persists across a store reload")
    }

    // Forgetting one host must not disturb another's pin (the store is keyed host:port).
    do {
        let dir = tempDir()
        let other = CertInfo(host: "other", port: 3389, commonName: "cn", subject: "s",
                             issuer: "i", fingerprintSHA256: "CC", hostMismatch: false,
                             changed: false)
        let store = FileCertificateTrustStore(directory: dir)
        store.pin(rich)
        store.pin(other)
        store.remove(host: "h", port: 3389)
        check(store.evaluate(rich) == .unknown && store.evaluate(other) == .trusted,
              "forget is scoped to one host:port")
    }
}

print("\n== SessionTabOrder (F-7 tab strip ordering) ==")
do {
    let a = "A", b = "B", c = "C", d = "D"
    var order = [String]()
    order = SessionTabOrder.appending(a, to: order)
    order = SessionTabOrder.appending(b, to: order)
    order = SessionTabOrder.appending(c, to: order)
    check(order == [a, b, c], "new sessions append at the end")
    check(SessionTabOrder.appending(b, to: order) == [a, b, c],
          "re-adding (reconnect) keeps the tab's slot — no duplicate")

    check(SessionTabOrder.moving(a, toSlotOf: c, in: [a, b, c, d]) == [b, c, a, d],
          "drag right: A takes C's slot")
    check(SessionTabOrder.moving(d, toSlotOf: b, in: [a, b, c, d]) == [a, d, b, c],
          "drag left: D takes B's slot")
    check(SessionTabOrder.moving(a, toSlotOf: a, in: order) == order,
          "drop on itself is a no-op")
    check(SessionTabOrder.moving("X", toSlotOf: b, in: order) == order,
          "unknown dragged id is a no-op")
    check(SessionTabOrder.moving(a, toSlotOf: "X", in: order) == order,
          "unknown target id is a no-op")

    check(SessionTabOrder.removing(b, from: [a, b, c]) == [a, c],
          "closing a tab keeps the remaining order")
    check(SessionTabOrder.removing("X", from: [a, b, c]) == [a, b, c],
          "removing an unknown id changes nothing")

    check(SessionTabOrder.selectionAfterClosing(b, in: [a, b, c]) == c,
          "closing the active tab selects its right-hand neighbour")
    check(SessionTabOrder.selectionAfterClosing(c, in: [a, b, c]) == b,
          "closing the last tab selects the new last tab")
    check(SessionTabOrder.selectionAfterClosing(a, in: [a]) == nil,
          "closing the only tab selects nothing")

    // F-16: tear-off (detach/reattach) semantics.
    let det1 = SessionTabOrder.detaching(b, from: [a, b, c], active: b)
    check(det1.order == [a, c] && det1.active == c,
          "detaching the active tab removes it and selects its right-hand neighbour")
    let det2 = SessionTabOrder.detaching(c, from: [a, b, c], active: c)
    check(det2.order == [a, b] && det2.active == b,
          "detaching the active last tab selects the new last tab")
    let det3 = SessionTabOrder.detaching(a, from: [a, b, c], active: c)
    check(det3.order == [b, c] && det3.active == c,
          "detaching an inactive tab keeps the current selection")
    let det4 = SessionTabOrder.detaching(a, from: [a], active: a)
    check(det4.order.isEmpty && det4.active == nil,
          "detaching the only tab leaves no order and no selection")
    check(SessionTabOrder.reattaching(b, to: [a, c]) == [a, c, b],
          "reattaching appends at the END of the main tab order")
    check(SessionTabOrder.reattaching(b, to: [a, b, c]) == [a, b, c],
          "reattaching an id already present keeps the order (no duplicate)")
}

print("\n== ScreenshotNaming (F-13 filename sanitization) ==")
do {
    check(ScreenshotNaming.sanitized("Office PC") == "Office PC", "clean name passes through")
    check(ScreenshotNaming.sanitized("srv/prod:eu\\1") == "srv prod eu 1",
          "slashes, colons, and backslashes stripped")
    check(ScreenshotNaming.sanitized("a\u{0}b\nc") == "a b c",
          "control chars and newlines stripped, whitespace collapsed")
    check(ScreenshotNaming.sanitized("//::") == "Session", "all-hostile name falls back to Session")
    check(ScreenshotNaming.sanitized("   ") == "Session", "blank name falls back to Session")

    let name = ScreenshotNaming.defaultFileName(connectionName: "My: PC",
                                                date: Date(timeIntervalSince1970: 0))
    check(name.hasPrefix("TouchRDP My PC ") && name.hasSuffix(".png"),
          "default file name is 'TouchRDP <sanitized name> <timestamp>.png'")
    check(!name.contains(":") && !name.contains("/") && !name.contains("\\"),
          "default file name contains no path separators (timestamp uses periods)")
}

print("\n== FileClipboardOffer (F-8 Mac→Windows file offer) ==")
do {
    typealias FCO = FileClipboardOffer

    // --- Filename sanitization (FILEDESCRIPTORW rules) ---
    check(FCO.sanitizedFileName("report.txt") == "report.txt", "clean filename passes through")
    check(FCO.sanitizedFileName("re/port:20\\26|q?.txt") == "re port 20 26 q .txt",
          "path separators and reserved chars become spaces")
    check(FCO.sanitizedFileName("a\u{0}b\nc.pdf") == "a b c.pdf",
          "control chars stripped, whitespace collapsed")
    check(FCO.sanitizedFileName("///:::") == "file", "all-hostile name falls back to 'file'")
    check(FCO.sanitizedFileName("..") == "file", "dot-only name falls back to 'file'")
    check(FCO.sanitizedFileName("name...") == "name", "trailing dots trimmed (Windows rule)")

    // 260-char truncation preserving the extension (259 usable UTF-16 units).
    let long = String(repeating: "a", count: 300) + ".txt"
    let cut = FCO.sanitizedFileName(long)
    check(cut.utf16.count == 259 && cut.hasSuffix(".txt"),
          "300-char name truncates to 259 UTF-16 units keeping .txt")
    // Surrogate-pair safety: emoji are 2 UTF-16 units; truncation must never split one.
    let emoji = String(repeating: "🎉", count: 200) + ".dat"   // 400 units + 4
    let ecut = FCO.sanitizedFileName(emoji)
    check(ecut.utf16.count <= 259 && ecut.hasSuffix(".dat")
          && String(decoding: Array(ecut.utf16), as: UTF16.self) == ecut,
          "emoji name truncates on grapheme boundaries (no half surrogate)")
    let noExt = String(repeating: "b", count: 400)
    check(FCO.sanitizedFileName(noExt).utf16.count == 259,
          "extension-less long name truncates to 259 units")

    // --- Limit enforcement ---
    func regular(_ i: Int, size: UInt64 = 1) -> FCO.Candidate {
        FCO.Candidate(path: "/tmp/f\(i)", name: "f\(i).bin", size: size,
                      isRegularFile: true, isSymlink: false)
    }
    let ok64 = FCO.validate((0..<64).map { regular($0) })
    check(ok64.offerBlocked == nil && ok64.staged.count == 64 && ok64.totalBytes == 64,
          "64 files stage OK")
    let over65 = FCO.validate((0..<65).map { regular($0) })
    check(over65.offerBlocked != nil && over65.staged.isEmpty,
          "65 files reject the WHOLE offer")
    let big = FCO.validate([regular(0, size: 200 << 20), regular(1, size: 100 << 20)])
    check(big.offerBlocked != nil && big.staged.isEmpty,
          "300 MiB total rejects the whole offer (256 MiB cap)")
    let atCap = FCO.validate([regular(0, size: FCO.maxTotalBytes)])
    check(atCap.offerBlocked == nil && atCap.staged.count == 1,
          "exactly 256 MiB is allowed")

    // Per-file eligibility: directories and symlinks are rejected (not followed),
    // the rest still stages.
    let mixed = FCO.validate([
        regular(0),
        FCO.Candidate(path: "/tmp/dir", name: "dir", size: 0,
                      isRegularFile: false, isSymlink: false),
        FCO.Candidate(path: "/tmp/link", name: "link.txt", size: 5,
                      isRegularFile: false, isSymlink: true),
    ])
    check(mixed.staged.count == 1 && mixed.rejections.count == 2 && mixed.offerBlocked == nil,
          "directory + symlink rejected per-file; regular file still offered")

    // Duplicate names (same basename from different folders) are uniquified —
    // Windows can't paste two files of one name into one folder.
    let dupes = FCO.validate([
        FCO.Candidate(path: "/a/r.txt", name: "r.txt", size: 1, isRegularFile: true, isSymlink: false),
        FCO.Candidate(path: "/b/r.txt", name: "r.txt", size: 1, isRegularFile: true, isSymlink: false),
    ])
    check(dupes.staged.count == 2 && dupes.staged[0].name != dupes.staged[1].name
          && dupes.staged[1].name.hasSuffix(".txt"),
          "duplicate basenames uniquified, extension kept")

    // --- FILEGROUPDESCRIPTORW size math (mirrors the C bridge _Static_assert) ---
    check(FCO.fileDescriptorWireSize == 592,
          "FILEDESCRIPTORW wire size is 592 (verified against winpr/shell.h)")
    check(FCO.descriptorBlobSize(fileCount: 1) == 596 &&
          FCO.descriptorBlobSize(fileCount: 64) == 4 + 64 * 592,
          "FILEGROUPDESCRIPTORW blob is 4 + n*592 bytes")

    // Back-compat: legacy profile JSON (no field) decodes with the offer OFF.
    let legacy = #"{"name":"old","host":"h","port":3389,"username":"u"}"#.data(using: .utf8)!
    let conn = try? JSONDecoder().decode(Connection.self, from: legacy)
    check(conn?.fileClipboardEnabled == false,
          "legacy connection JSON (no field) => file offer disabled")
    var c = Connection(name: "n", host: "h", username: "u")
    c.fileClipboardEnabled = true
    let back = (try? JSONEncoder().encode(c))
        .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    check(back?.fileClipboardEnabled == true, "explicit opt-in round-trips")
}

print("\n== RemoteFileClipboard (#25 remote→Mac file paste) ==")
do {
    typealias RFC = RemoteFileClipboard

    // Synthetic FILEGROUPDESCRIPTORW builder mirroring the wire layout the C bridge
    // hands over: 4-byte LE count + n × 592-byte descriptors (dwFlags@0, attrs@36,
    // sizeHigh@64, sizeLow@68, UTF-16LE name@72).
    func write32(_ d: inout Data, _ offset: Int, _ v: UInt32) {
        d[offset] = UInt8(v & 0xFF); d[offset + 1] = UInt8((v >> 8) & 0xFF)
        d[offset + 2] = UInt8((v >> 16) & 0xFF); d[offset + 3] = UInt8((v >> 24) & 0xFF)
    }
    func descriptor(name: String, size: UInt64?, attributes: UInt32 = 0x80) -> Data {
        var d = Data(count: 592)
        var flags: UInt32 = 0x04                       // FD_ATTRIBUTES
        if size != nil { flags |= 0x40 }               // FD_FILESIZE
        write32(&d, 0, flags)
        write32(&d, 36, attributes)
        if let s = size {
            write32(&d, 64, UInt32(truncatingIfNeeded: s >> 32))
            write32(&d, 68, UInt32(truncatingIfNeeded: s))
        }
        for (i, u) in name.utf16.prefix(259).enumerated() {
            d[72 + 2 * i] = UInt8(u & 0xFF)
            d[72 + 2 * i + 1] = UInt8(u >> 8)
        }
        return d
    }
    func blob(count: UInt32, _ descriptors: [Data]) -> Data {
        var b = Data(count: 4)
        write32(&b, 0, count)
        for d in descriptors { b.append(d) }
        return b
    }

    // Stride/size math shared with the F-8 offer (and the C _Static_assert).
    check(RFC.descriptorStride == 592, "descriptor stride is the 592-byte wire size")
    check(RFC.maxFiles == (4 * 1024 * 1024 - 4) / 592,
          "descriptor count cap derives from the 4 MiB blob cap (~7084 files)")

    // Round trip: 2 entries, names + hi/lo size split + attributes survive parsing.
    let big = UInt64(5) << 32 | 42                     // exercises the high dword
    let two = RFC.parse(blob(count: 2, [descriptor(name: "report.txt", size: 1234),
                                        descriptor(name: "видео.mp4", size: big)]))
    check(two?.count == 2, "2-entry blob parses to 2 descriptors")
    check(two?[0].name == "report.txt" && two?[0].size == 1234 && two?[0].listIndex == 0,
          "entry 0 round-trips name/size/listIndex")
    check(two?[1].name == "видео.mp4" && two?[1].size == big && two?[1].attributes == 0x80,
          "entry 1 reassembles nFileSizeHigh/Low into a 64-bit size (UTF-16 name intact)")

    // Structural rejection: truncated / lying blobs die without a crash.
    check(RFC.parse(Data()) == nil, "empty blob rejected")
    check(RFC.parse(Data([1, 0, 0])) == nil, "sub-4-byte blob rejected")
    check(RFC.parse(blob(count: 0, [])) == nil, "count of 0 rejected")
    check(RFC.parse(blob(count: 2, [descriptor(name: "a.txt", size: 1)])) == nil,
          "count promising more descriptors than the blob carries is rejected")
    check(RFC.parse(blob(count: 1, [descriptor(name: "a.txt", size: 1).dropLast(10)])) == nil,
          "truncated descriptor rejected")
    check(RFC.parse(blob(count: UInt32(RFC.maxFiles + 1), [])) == nil,
          "count over the ~7000-file cap rejected outright")

    // Hostile names can never steer the write outside the destination folder.
    let hostile = RFC.parse(blob(count: 2, [descriptor(name: "..\\..\\evil.exe", size: 1),
                                            descriptor(name: "../../etc/passwd", size: 1)]))
    check(hostile?.count == 2
          && !(hostile![0].name.contains("\\") || hostile![0].name.contains("/"))
          && !(hostile![1].name.contains("\\") || hostile![1].name.contains("/")),
          "path separators stripped from hostile names (\"..\\evil\" defanged)")

    // FD_FILESIZE absent => size unknown (the puller falls back to FILECONTENTS_SIZE).
    let noSize = RFC.parse(blob(count: 1, [descriptor(name: "n.bin", size: nil)]))
    check(noSize?.first?.size == nil, "descriptor without FD_FILESIZE parses with nil size")

    // Directory entries are skipped but the survivors keep the SERVER's list indices.
    let withDir = RFC.parse(blob(count: 3, [descriptor(name: "a.txt", size: 1),
                                            descriptor(name: "folder", size: nil,
                                                       attributes: 0x10),
                                            descriptor(name: "b.txt", size: 2)]))
    check(withDir?.count == 2 && withDir?[0].listIndex == 0 && withDir?[1].listIndex == 2,
          "directory entry skipped; remaining descriptors keep server list indices")

    // Duplicate names are de-duplicated so one Finder paste can't overwrite itself.
    let dupes = RFC.parse(blob(count: 2, [descriptor(name: "r.txt", size: 1),
                                          descriptor(name: "R.TXT", size: 1)]))
    check(dupes?.count == 2 && dupes?[0].name.lowercased() != dupes?[1].name.lowercased(),
          "case-insensitive duplicate names uniquified within one announcement")

    // Chunk math: 0-byte file => zero RANGE pulls; exact multiple; remainder chunk.
    let chunk: UInt32 = 4 * 1024 * 1024
    check(RFC.chunkLength(at: 0, totalSize: 0, chunkSize: chunk) == 0,
          "0-byte file needs zero RANGE pulls")
    check(RFC.chunkLength(at: 0, totalSize: UInt64(2 * chunk), chunkSize: chunk) == chunk
          && RFC.chunkLength(at: UInt64(chunk), totalSize: UInt64(2 * chunk),
                             chunkSize: chunk) == chunk
          && RFC.chunkLength(at: UInt64(2 * chunk), totalSize: UInt64(2 * chunk),
                             chunkSize: chunk) == 0,
          "exact-multiple file: two full chunks then done (no zero-length request)")
    check(RFC.chunkLength(at: UInt64(chunk), totalSize: UInt64(chunk) + 5,
                          chunkSize: chunk) == 5,
          "remainder chunk is the exact tail length")

    // streamId allocation: monotonic, and 0 is never handed out (wraparound skips it).
    var ids = RFC.StreamIdAllocator()
    let a = ids.allocate(), b2 = ids.allocate(), c2 = ids.allocate()
    check(a == 1 && b2 == 2 && c2 == 3, "streamIds are monotonic from 1")
    var wrap = RFC.StreamIdAllocator(startingAt: UInt32.max)
    check(wrap.allocate() == UInt32.max && wrap.allocate() == 1,
          "wraparound skips 0 (reserved as 'no stream')")
}

print("\n== Printer redirection (F-17) ==")
do {
    // Off by default in the model initializer.
    let fresh = Connection(name: "n", host: "h", username: "u")
    check(fresh.printerRedirectionEnabled == false, "new connection defaults to printers OFF")

    // Back-compat: legacy profile JSON (no field) decodes with redirection OFF.
    let legacy = #"{"name":"old","host":"h","port":3389,"username":"u"}"#.data(using: .utf8)!
    let conn = try? JSONDecoder().decode(Connection.self, from: legacy)
    check(conn?.printerRedirectionEnabled == false,
          "legacy connection JSON (no field) => printer redirection disabled")

    // An explicit opt-in survives an encode/decode round-trip.
    var c = Connection(name: "n", host: "h", username: "u")
    c.printerRedirectionEnabled = true
    let back = (try? JSONEncoder().encode(c))
        .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    check(back?.printerRedirectionEnabled == true, "explicit opt-in round-trips")

    // …and reaches the engine config (fresh connect + reconnect both build here).
    check(RDPConnectionConfig(from: c).printerRedirectionEnabled == true,
          "RDPConnectionConfig(from:) carries the opt-in")
    check(RDPConnectionConfig(from: fresh).printerRedirectionEnabled == false,
          "RDPConnectionConfig(from:) keeps the default off")
}

print("\n== VideoDecodingSettings (PERF-9 — per-connection AVC444 / hardware decode) ==")
do {
    let fresh = Connection(name: "n", host: "h", username: "u")
    check(fresh.videoDecoding == .default
              && fresh.videoDecoding.avc444Enabled && fresh.videoDecoding.hardwareDecodeEnabled,
          "new connection defaults to AVC444 on + hardware decode on (pre-PERF-9 behaviour)")

    // Back-compat: legacy profile JSON (no field) decodes to both on.
    let legacy = #"{"name":"old","host":"h","port":3389,"username":"u"}"#.data(using: .utf8)!
    let conn = try? JSONDecoder().decode(Connection.self, from: legacy)
    check(conn?.videoDecoding == .default, "legacy connection JSON (no field) => both on")

    // A partial object (e.g. from a hand-edited store) defaults the missing key.
    let partial = #"{"name":"o","host":"h","port":3389,"username":"u","videoDecoding":{"avc444Enabled":false}}"#
        .data(using: .utf8)!
    let p = try? JSONDecoder().decode(Connection.self, from: partial)
    check(p?.videoDecoding.avc444Enabled == false && p?.videoDecoding.hardwareDecodeEnabled == true,
          "partial videoDecoding JSON defaults the missing key")

    // Explicit opt-outs survive an encode/decode round-trip…
    var c = fresh
    c.videoDecoding = VideoDecodingSettings(avc444Enabled: false, hardwareDecodeEnabled: false)
    let back = (try? JSONEncoder().encode(c))
        .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    check(back?.videoDecoding == c.videoDecoding, "explicit opt-outs round-trip")

    // …and reach the engine config (fresh connect + reconnect both build here).
    let cfg = RDPConnectionConfig(from: c)
    check(!cfg.videoDecoding.avc444Enabled && !cfg.videoDecoding.hardwareDecodeEnabled,
          "RDPConnectionConfig(from:) carries both opt-outs")
    check(RDPConnectionConfig(from: fresh).videoDecoding == .default,
          "RDPConnectionConfig(from:) keeps the defaults")
}

print("\n== Password typing (F-27 — type the vaulted password into a live session) ==")
do {
    let fresh = Connection(name: "n", host: "h", username: "u")
    check(fresh.passwordTypingEnabled == false,
          "new connection defaults to OFF (a secret-typing feature never arrives armed)")

    // Back-compat: a profile saved before the field existed must decode to OFF, not on.
    let legacy = #"{"name":"old","host":"h","port":3389,"username":"u"}"#.data(using: .utf8)!
    let conn = try? JSONDecoder().decode(Connection.self, from: legacy)
    check(conn?.passwordTypingEnabled == false, "legacy connection JSON (no field) => off")

    // An explicit opt-in survives a round-trip.
    var c = fresh
    c.passwordTypingEnabled = true
    let back = (try? JSONEncoder().encode(c))
        .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    check(back?.passwordTypingEnabled == true, "explicit opt-in round-trips")

    // The credential directive for this path is fixed regardless of the connection's
    // policy: always a fresh biometric, never seeding a reusable context. A reuse window
    // here would let one Touch ID type the password repeatedly at an unverified target.
    for policy in [CredentialPolicy.biometricEveryConnect,
                   .biometricReuse(seconds: 45),
                   .savedNoBiometric] {
        let d = policy.authDirective(for: .inSessionTyping)
        check(d.forceFreshPrompt && d.reuseSeconds == nil,
              "authDirective(.inSessionTyping) forces a fresh prompt and seeds no reuse for \(policy)")
    }

    // The other reasons are untouched by F-27.
    check(CredentialPolicy.biometricReuse(seconds: 45)
            .authDirective(for: .automaticReconnect).reuseSeconds == 45,
          "reconnect reuse window is unchanged")
}

print("\n== MonitorLayout (#22 — per-display viewports of the spanned session) ==")
do {
    // Two equal Retina displays side by side (primary left, at AppKit origin).
    // Points: (0,0,1512,982) + (1512,0,1512,982) at scale 2 → pixel rects tile 6048×1964.
    let frames2 = [CGRect(x: 0, y: 0, width: 1512, height: 982),
                   CGRect(x: 1512, y: 0, width: 1512, height: 982)]
    let mons2 = MonitorLayout.makeMonitors(screenFramesPoints: frames2, scale: 2)
    check(mons2.count == 2, "2-display: two monitors")
    check(mons2[0] == MonitorDef(x: 0, y: 0, width: 3024, height: 1964,
                                 isPrimary: true, scaleFactor: 200),
          "2-display: primary at pixel origin, 2× scale, sf 200")
    check(mons2[1] == MonitorDef(x: 3024, y: 0, width: 3024, height: 1964,
                                 isPrimary: false, scaleFactor: 200),
          "2-display: secondary abuts primary in pixel space")
    let span2 = MonitorLayout.spannedFrameSize(of: mons2)
    check(span2 == CGSize(width: 6048, height: 1964), "2-display: spanned frame is the union")

    // Viewports: rects tile the spanned frame exactly (union == frame, no overlap).
    if case .perDisplay(let vps2) = MonitorLayout.viewports(monitors: mons2, screenCount: 2) {
        check(vps2.count == 2 && vps2[0].screenIndex == 0 && vps2[1].screenIndex == 1,
              "2-display: viewport↔screen mapping is index-aligned")
        check(vps2[0].isPrimary && !vps2[1].isPrimary, "2-display: primary flag follows monitor 0")
        check(vps2[0].remotePixelRect.union(vps2[1].remotePixelRect)
                == CGRect(origin: .zero, size: span2),
              "2-display: viewport union == spanned frame")
        check(vps2[0].remotePixelRect.intersection(vps2[1].remotePixelRect).isEmpty,
              "2-display: viewports do not overlap")

        // contentsRect normalization: right half of the frame → (0.5, 0, 0.5, 1).
        let cr = MonitorLayout.contentsRect(viewport: vps2[1].remotePixelRect, frameSize: span2)
        check(cr == CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
              "contentsRect: right-half viewport → (0.5,0,0.5,1)")
    } else {
        check(false, "2-display: viewports produced")
    }
    // Flip helper converts between top-left and bottom-left unit conventions and is
    // its own inverse (used when the canvas layer is not geometry-flipped).
    let top = CGRect(x: 0.25, y: 0.0, width: 0.5, height: 0.25)
    let flipped = MonitorLayout.verticallyFlippedUnitRect(top)
    check(flipped == CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.25),
          "verticallyFlippedUnitRect: top strip → bottom strip")
    check(MonitorLayout.verticallyFlippedUnitRect(flipped) == top,
          "verticallyFlippedUnitRect is an involution")
}
do {
    // Three displays with negative AppKit origins (secondary LEFT of primary) and a
    // vertically offset third — normalization must land at (0,0) with no negatives.
    let frames3 = [CGRect(x: 0, y: 0, width: 1920, height: 1080),        // primary
                   CGRect(x: -1920, y: 0, width: 1920, height: 1080),    // left of it
                   CGRect(x: 1920, y: 200, width: 1440, height: 900)]    // right, raised
    let mons3 = MonitorLayout.makeMonitors(screenFramesPoints: frames3, scale: 1)
    check(mons3.count == 3, "3-display: three monitors")
    check(mons3.allSatisfy { $0.x >= 0 && $0.y >= 0 }, "3-display: normalized non-negative origins")
    check(mons3.allSatisfy { $0.x % 2 == 0 && $0.y % 2 == 0 && $0.width % 2 == 0 && $0.height % 2 == 0 },
          "3-display: all dimensions even (RDP requirement)")
    check(mons3[1].x == 0 && mons3[0].x == 1920 && mons3[2].x == 3840,
          "3-display: left/primary/right order preserved in pixel space")
    // Union top = 1100 points; primary/left maxY 1080 → y 20; right maxY 1100 → y 0.
    check(mons3[0].y == 20 && mons3[1].y == 20 && mons3[2].y == 0,
          "3-display: Y flipped against the union top")
    check(mons3[0].isPrimary && !mons3[1].isPrimary && !mons3[2].isPrimary,
          "3-display: primary = the screen at AppKit origin")
    check(mons3.allSatisfy { $0.scaleFactor == 100 }, "3-display: scale 1 → sf 100")

    if case .perDisplay(let vps3) = MonitorLayout.viewports(monitors: mons3, screenCount: 3) {
        // Pairwise non-overlap and containment in the spanned frame.
        let span3 = MonitorLayout.spannedFrameSize(of: mons3)
        let frame3 = CGRect(origin: .zero, size: span3)
        var overlapFree = true
        for i in 0..<vps3.count {
            for j in (i + 1)..<vps3.count
            where !vps3[i].remotePixelRect.intersection(vps3[j].remotePixelRect).isEmpty {
                overlapFree = false
            }
        }
        check(overlapFree, "3-display: no viewport overlap")
        check(vps3.allSatisfy { frame3.contains($0.remotePixelRect) },
              "3-display: every viewport inside the spanned frame")

        // Input round-trip: an interior view point in window k maps to a remote pixel
        // inside k's rect (aspect-fit letterboxing included), never a neighbour's.
        let viewSize = CGSize(width: 1600, height: 1000)   // letterboxes every viewport
        for (k, vp) in vps3.enumerated() {
            let p = MonitorLayout.remotePixel(viewPoint: CGPoint(x: 800, y: 500),
                                              viewSize: viewSize, viewport: vp.remotePixelRect)
            check(vp.remotePixelRect.contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))),
                  "input: window \(k) center → pixel inside monitor \(k)")
        }
        // The view center maps to the viewport center (within integer truncation)…
        let vp0 = vps3[0].remotePixelRect
        let center = MonitorLayout.remotePixel(viewPoint: CGPoint(x: 800, y: 500),
                                               viewSize: viewSize, viewport: vp0)
        check(abs(CGFloat(center.x) - vp0.midX) <= 1 && abs(CGFloat(center.y) - vp0.midY) <= 1,
              "input: view center → viewport center")
        // …and letterbox/out-of-window points clamp INTO the viewport (an off-display
        // click can never reach another display's monitor).
        let corner = MonitorLayout.remotePixel(viewPoint: CGPoint(x: -50, y: 4000),
                                               viewSize: viewSize, viewport: vp0)
        check(CGFloat(corner.x) == vp0.minX && CGFloat(corner.y) == vp0.maxY - 1,
              "input: out-of-bounds points clamp inside the viewport")
    } else {
        check(false, "3-display: viewports produced")
    }

    // Count-mismatch fallback is signaled, never a partial/misassigned split.
    if case .fallback = MonitorLayout.viewports(monitors: mons3, screenCount: 2) {
        check(true, "screen-count mismatch → explicit fallback")
    } else {
        check(false, "screen-count mismatch → explicit fallback")
    }
    if case .fallback = MonitorLayout.viewports(monitors: [], screenCount: 0) {
        check(true, "empty layout → explicit fallback")
    } else {
        check(false, "empty layout → explicit fallback")
    }
}

print("\n== DisplaySettings.perDisplayWindows (#22 — model back-compat) ==")
do {
    check(DisplaySettings().perDisplayWindows == false, "defaults to OFF")
    // Legacy JSON (no key) decodes to OFF — no schema bump.
    let legacy = #"{"width":1280,"height":800,"useHiDPI":true,"scaleMode":"dynamic","scaleFactor":100,"useAllDisplays":true}"#
        .data(using: .utf8)!
    let decoded = try? JSONDecoder().decode(DisplaySettings.self, from: legacy)
    check(decoded?.perDisplayWindows == false && decoded?.useAllDisplays == true,
          "legacy display JSON (no key) → per-display OFF, spanning preserved")
    // An explicit opt-in round-trips.
    var d = DisplaySettings(useAllDisplays: true)
    d.perDisplayWindows = true
    let back = (try? JSONEncoder().encode(d))
        .flatMap { try? JSONDecoder().decode(DisplaySettings.self, from: $0) }
    check(back?.perDisplayWindows == true, "explicit opt-in round-trips")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
