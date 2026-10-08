import SwiftUI
import TouchRDPCore
import TouchRDPEngine

@main
struct TouchRDPApp: App {
    @StateObject private var coordinator: AppCoordinator = {
        let vault = KeychainCredentialVault()
        let store = FileConnectionStore()
        let trustStore = FileCertificateTrustStore()
        return AppCoordinator(vault: vault, store: store, trustStore: trustStore)
    }()

    init() {
        // Sessions use the app's own tab strip, never native window tabs. Without this,
        // macOS adds its own (always-disabled) tab items to the Window menu next to ours.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            AppCommands()
        }

        Settings {
            PreferencesView()
                .environmentObject(coordinator)
        }
    }
}

// MARK: - Menu commands

struct AppCommands: Commands {
    var body: some Commands {
        // F-1: File ▸ Import .rdp File…. The action lives in ContentView (which owns the
        // store selection + editor sheet) and is published via a focused scene value,
        // mirroring the activeSession pattern below.
        CommandGroup(replacing: .importExport) {
            ImportMenuItems()
        }
        CommandGroup(after: .newItem) {
            // Session commands are wired through focused session via
            // FocusedValues — see SessionView for the focused binding
            ConnectMenuItems()
        }
        // F-7: tab switching lives in the Window menu (Safari-style ⌘⇧[/⌘⇧] + ⌘1–⌘9),
        // driven by the tab state ContentView publishes as a focused scene value.
        // F-16: tear-off commands live right below the tab commands.
        CommandGroup(before: .windowArrangement) {
            SessionTabMenuItems()
            TearOffMenuItems()
        }
    }
}

struct SessionTabMenuItems: View {
    @FocusedValue(\.sessionTabs) private var tabs: SessionTabCommands?

    private var count: Int { tabs?.count ?? 0 }

    var body: some View {
        Button("Show Previous Tab") { tabs?.selectPrevious() }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(count < 2)
        Button("Show Next Tab") { tabs?.selectNext() }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(count < 2)
        if count > 0 {
            Divider()
            // ⌘1–⌘9 jump straight to the Nth tab; only as many entries as open tabs
            // (capped at 9 — SessionTabCommands is count-equatable so this list tracks
            // opens/closes).
            ForEach(0..<min(count, 9), id: \.self) { i in
                Button("Session Tab \(i + 1)") { tabs?.select(i) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
    }
}

// F-16: tear-off window commands. Targeting is EXPLICIT — `DetachedWindowManager`
// tracks which detached window is key via NSWindowDelegate — so these work regardless
// of whether FocusedValues bridge out of the AppKit-hosted secondary windows (which
// cannot be interactively verified in this environment).
struct TearOffMenuItems: View {
    @ObservedObject private var manager: DetachedWindowManager = .shared

    var body: some View {
        Divider()
        // Detaches the MAIN window's active tab; disabled while a detached window is
        // key (its session is already in its own window).
        Button("Move Session to New Window") { manager.onDetachActive?() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!manager.canDetachActive || manager.keySessionID != nil)
        // Reattaches the KEY detached window's session at the end of the main tab order.
        Button("Move Back to Main Window") {
            if let id = manager.keySessionID { manager.onReattach?(id) }
        }
        .disabled(manager.keySessionID == nil)
    }
}

struct ImportMenuItems: View {
    @FocusedValue(\.importRDPFiles) private var importAction: ImportRDPAction?

    var body: some View {
        Button("Import .rdp File…") {
            importAction?.begin()
        }
        .disabled(importAction == nil)
    }
}

struct ConnectMenuItems: View {
    @FocusedValue(\.activeSession) private var focusedSession: SessionController?
    @FocusedValue(\.sessionScreenshot) private var focusedScreenshot: SessionScreenshotAction?
    // F-16: when a detached (AppKit-hosted) window is key, the scene-focused values may
    // not resolve — fall back to the manager's explicit key-window tracking so
    // Disconnect / Send / screenshot always target the key window's session.
    @ObservedObject private var detached: DetachedWindowManager = .shared

    private var activeSession: SessionController? { focusedSession ?? detached.keySession }
    private var screenshot: SessionScreenshotAction? { focusedScreenshot ?? detached.keyScreenshot }

    var body: some View {
        Button("Disconnect") {
            activeSession?.disconnect()
        }
        .keyboardShortcut("w", modifiers: [.command, .shift])
        .disabled(activeSession == nil)

        // F-4: full special-keys submenu (absorbs the old "Send Ctrl-Alt-Del" item).
        // Shares SendKeysMenuItems with the session toolbar's Send Keys menu.
        Menu("Send") {
            if let session = activeSession {
                SendKeysMenuItems(controller: session)
            }
        }
        .disabled(activeSession?.state != .connected)

        Divider()

        // F-13: capture the current remote framebuffer (full remote resolution).
        // Two explicit items rather than an ⌥-modifier variant: Save runs an
        // NSSavePanel, Copy targets the general pasteboard. Explicit user action only.
        Button("Save Screenshot…") { screenshot?.save() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(screenshot == nil)
        Button("Copy Screenshot") { screenshot?.copy() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(screenshot == nil)

        Divider()

        Button("Enter Full Screen") {
            NSApplication.shared.mainWindow?.toggleFullScreen(nil)
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
    }
}

// MARK: - FocusedValues extension for active session

struct ActiveSessionKey: FocusedValueKey {
    typealias Value = SessionController
}

extension FocusedValues {
    var activeSession: SessionController? {
        get { self[ActiveSessionKey.self] }
        set { self[ActiveSessionKey.self] = newValue }
    }
}

// MARK: - FocusedValues extension for .rdp import (F-1)

/// Wraps the "show the import open panel" action published by `ContentView`. Equatable
/// (always-equal) so `.focusedSceneValue` doesn't republish on every render — the closure
/// only flips ContentView's stable `@State` storage, so a retained instance stays valid.
struct ImportRDPAction: Equatable {
    let begin: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

struct ImportRDPKey: FocusedValueKey {
    typealias Value = ImportRDPAction
}

extension FocusedValues {
    var importRDPFiles: ImportRDPAction? {
        get { self[ImportRDPKey.self] }
        set { self[ImportRDPKey.self] = newValue }
    }
}

// MARK: - FocusedValues extension for tab switching (F-7)

/// Tab-switch actions + the open-tab count, published by `ContentView`. Equatable on
/// `count` only, so the focused value republishes when tabs open/close (the ⌘1–⌘9 menu
/// list tracks it) without thrashing on every render — the closures read ContentView's
/// stable `@State` storage, so a retained instance stays valid.
struct SessionTabCommands: Equatable {
    let count: Int
    let selectPrevious: () -> Void
    let selectNext: () -> Void
    let select: (Int) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.count == rhs.count }
}

struct SessionTabsKey: FocusedValueKey {
    typealias Value = SessionTabCommands
}

extension FocusedValues {
    var sessionTabs: SessionTabCommands? {
        get { self[SessionTabsKey.self] }
        set { self[SessionTabsKey.self] = newValue }
    }
}

// MARK: - FocusedValues extension for session screenshots (F-13)

/// Save/Copy screenshot actions published by the active `SessionView` (so the menu
/// items are enabled exactly while a session is showing). Always-equal Equatable,
/// mirroring `ImportRDPAction`: the closures capture the session's stable controller
/// reference and `@State` storage.
struct SessionScreenshotAction: Equatable {
    let save: () -> Void
    let copy: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

struct SessionScreenshotKey: FocusedValueKey {
    typealias Value = SessionScreenshotAction
}

extension FocusedValues {
    var sessionScreenshot: SessionScreenshotAction? {
        get { self[SessionScreenshotKey.self] }
        set { self[SessionScreenshotKey.self] = newValue }
    }
}
