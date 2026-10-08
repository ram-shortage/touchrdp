import SwiftUI
import AppKit
import Combine
import TouchRDPCore
import TouchRDPEngine

// MARK: - Detached (tear-off) session windows — F-16

/// Owns the AppKit side of tear-off sessions: one plain `NSWindow` + `NSHostingView`
/// per detached session. Deliberately a *window* manager only — session state stays in
/// exactly ONE place (ContentView's `sessions` dictionary, referenced here by UUID);
/// this class holds window references plus the controller reference it was handed for
/// key-window menu targeting. Every session-lifecycle decision round-trips through the
/// callbacks ContentView registers, so closing a detached window funnels into the SAME
/// `closeSession` path as closing the tab (no forked teardown logic).
///
/// Menu targeting: `@FocusedValue` plumbing is scene-based, and whether it propagates
/// out of an `NSHostingView`-hosted AppKit window cannot be interactively verified in
/// this environment. So the Window/Connection menus do NOT rely on it for detached
/// windows: this manager tracks which detached window is key (`NSWindowDelegate`) and
/// publishes that session; the menu items read it as an explicit fallback
/// (`focusedValue ?? keySession`), which is correct whether or not the bridge exists.
@MainActor
final class DetachedWindowManager: NSObject, ObservableObject {
    static let shared = DetachedWindowManager()

    /// The session shown in the detached window that is currently key, if any.
    /// Nil whenever the main window (or any non-detached window) is key.
    @Published private(set) var keySessionID: UUID?
    @Published private(set) var keySession: SessionController?
    /// Whether the main window currently has an active tab to detach — kept in sync by
    /// ContentView so the Window-menu item enables/disables correctly.
    @Published var canDetachActive = false
    /// Screenshot actions registered by the live `SessionView`s, keyed by connection ID
    /// plus a per-view token (so the nondeterministic appear/disappear ordering while a
    /// session MOVES between windows can't unregister the fresh view's registration).
    /// Consulted by the Connection-menu fallback when a detached window is key.
    @Published private var screenshotActions: [UUID: (token: UUID, action: SessionScreenshotAction)] = [:]

    // Callbacks into ContentView — the single owner of `sessions`/`tabOrder`.
    var onDetachActive: (() -> Void)?
    var onReattach: ((UUID) -> Void)?
    /// User-closed a detached window (red button/⌘W) → same semantics as closing the tab.
    var onWindowClosed: ((UUID) -> Void)?

    private struct Entry {
        let window: NSWindow
        let controller: SessionController
    }
    private var entries: [UUID: Entry] = [:]

    func isDetached(_ id: UUID) -> Bool { entries[id] != nil }

    /// The key detached window's screenshot action (Connection-menu fallback).
    var keyScreenshot: SessionScreenshotAction? {
        keySessionID.flatMap { screenshotActions[$0]?.action }
    }

    // MARK: Screenshot-action registry (SessionView onAppear/onDisappear)

    func registerScreenshot(_ action: SessionScreenshotAction, for id: UUID, token: UUID) {
        screenshotActions[id] = (token, action)
    }

    func unregisterScreenshot(for id: UUID, token: UUID) {
        // Token-gated: only the view that registered may unregister, so a stale
        // onDisappear (old window) can't drop the new window's registration.
        if screenshotActions[id]?.token == token { screenshotActions[id] = nil }
    }

    // MARK: Window lifecycle

    /// Open a detached window hosting `controller`. The controller MOVES (same
    /// instance, still owned by ContentView's dictionary) — it is never recreated.
    /// The frame comes from the per-connection detached-frame memory
    /// (`windowFrame.<id>:detached` — the #21 scheme with a distinct suffix) when
    /// available, else a centered default.
    func openWindow(for id: UUID, controller: SessionController, connection: Connection,
                    coordinator: AppCoordinator, actions: SessionActions) {
        if let entry = entries[id] {          // already detached — just focus it
            entry.window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC owns it via `entries`
        window.tabbingMode = .disallowed      // never merges into the main window's tabs
        window.title = connection.name.isEmpty ? connection.host : connection.name
        window.subtitle = connection.host
        window.contentMinSize = NSSize(width: 480, height: 320)
        // The title + subtitle stay visible here because a detached window has no tab
        // strip naming the session, and `.unified` gives them the room to draw.
        window.toolbarStyle = .unified

        let root = DetachedSessionRootView(controller: controller,
                                           connection: connection,
                                           actions: actions)
            .environmentObject(coordinator)
        let hosting = NSHostingView(rootView: AnyView(root))
        // macOS 14: bridge the hosted hierarchy's `.toolbar` into the window's
        // NSToolbar, so the detached session keeps the full session toolbar (Send
        // Keys, Stay Awake, screenshot, quality indicator, cheat sheet).
        hosting.sceneBridgingOptions = [.toolbars]
        window.contentView = hosting
        window.delegate = self

        if let frame = Self.savedFrame(for: id) {
            window.setFrame(frame, display: false)  // off-screen left to AppKit constraining
        } else {
            window.center()
        }
        entries[id] = Entry(window: window, controller: controller)
        window.makeKeyAndOrderFront(nil)
    }

    /// Bring an existing detached session's window to the front (sidebar activation).
    func focusWindow(for id: UUID) {
        entries[id]?.window.makeKeyAndOrderFront(nil)
    }

    /// Take the window down WITHOUT touching the session — used by both the reattach
    /// path and `closeSession` (which owns the actual disconnect+remove teardown).
    /// Removing the entry FIRST makes the subsequent `close()` invisible to
    /// `windowWillClose`, so the teardown callback can never re-enter.
    func dismissWindow(for id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        persistFrame(entry.window, for: id)
        if keySessionID == id { keySessionID = nil; keySession = nil }
        entry.window.delegate = nil
        entry.window.close()
    }

    // MARK: Frame memory (#21 mechanism, ":detached" key suffix)

    private static func frameKey(_ id: UUID) -> String {
        "windowFrame." + id.uuidString + ":detached"
    }

    private static func savedFrame(for id: UUID) -> NSRect? {
        guard let a = UserDefaults.standard.array(forKey: frameKey(id)) as? [Double],
              a.count == 4, a[2] > 200, a[3] > 150 else { return nil }
        return NSRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }

    private func persistFrame(_ window: NSWindow, for id: UUID) {
        let r = window.frame
        UserDefaults.standard.set(
            [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)],
            forKey: Self.frameKey(id))
    }

    private func sessionID(of window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return entries.first(where: { $0.value.window === window })?.key
    }
}

// MARK: NSWindowDelegate

extension DetachedWindowManager: NSWindowDelegate {
    /// Full screen: auto-hide the title/toolbar with the menu bar (same behavior as
    /// the main window's FullScreenToolbarAutoHider).
    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
    ) -> NSApplication.PresentationOptions {
        proposedOptions.union(fullScreenAutoHideOptions)
    }

    func windowWillClose(_ notification: Notification) {
        // Only reachable when the USER closes the window (red button/⌘W): the
        // programmatic paths (reattach, closeSession) remove the entry before close().
        guard let window = notification.object as? NSWindow,
              let id = sessionID(of: window) else { return }
        persistFrame(window, for: id)
        entries[id] = nil
        if keySessionID == id { keySessionID = nil; keySession = nil }
        window.delegate = nil
        // Same semantics as closing the tab — funnels into ContentView.closeSession.
        onWindowClosed?(id)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let id = sessionID(of: notification.object as? NSWindow) else { return }
        keySessionID = id
        keySession = entries[id]?.controller
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let id = sessionID(of: notification.object as? NSWindow),
              keySessionID == id else { return }
        keySessionID = nil
        keySession = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = sessionID(of: window) else { return }
        persistFrame(window, for: id)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = sessionID(of: window) else { return }
        persistFrame(window, for: id)
    }
}

// MARK: - Detached window root view

/// Root SwiftUI content of a detached window: exactly the same `SessionView` the main
/// window's tab area hosts (the SessionController instance MOVES between windows — it
/// is never recreated), plus the same focused-value publication the main window makes.
/// The focused value may or may not bridge out of an NSHostingView-hosted window; the
/// menus fall back to `DetachedWindowManager`'s key-window tracking either way.
/// Clipboard focus gating (`controlActiveState`) and keyboard capture/first-responder
/// handling key off THIS window via the view's own environment/`window`, unchanged.
struct DetachedSessionRootView: View {
    @ObservedObject var controller: SessionController
    let connection: Connection
    let actions: SessionActions

    var body: some View {
        SessionView(controller: controller, connection: connection, actions: actions)
            .focusedSceneValue(\.activeSession, controller)
            .frame(minWidth: 480, minHeight: 320)
    }
}

// MARK: - Per-display session windows — #22

/// Presents ONE spanned multi-monitor session as one window per Mac display, each
/// window showing that display's crop (viewport) of the single spanned framebuffer.
/// PRESENTATION ONLY: the RDP session (monitor declaration, framebuffer, the one
/// SessionController) is untouched — this class owns AppKit windows and nothing else,
/// mirroring `DetachedWindowManager`'s division of responsibility (F-16).
///
/// Lifecycle: `attach` is called at connect time (ContentView.startSession). The
/// presenter subscribes to the controller's state: reaching `.connected` opens the
/// window group (recomputing viewports against the CURRENT screens — a changed
/// arrangement falls back to the single spanned canvas, reported via the status line);
/// leaving `.connected` closes the group (the main-window placeholder shows the
/// reconnect/failure overlays); reconnecting re-presents. Closing ANY group window
/// (red button/⌘W) tears the WHOLE session down through the same
/// `ContentView.closeSession` funnel as a tab close (F-16 pattern via `onWindowClosed`).
@MainActor
final class PerDisplayWindowPresenter: NSObject, ObservableObject {
    static let shared = PerDisplayWindowPresenter()

    /// Sessions currently attached (drives the main window's placeholder pane).
    @Published private(set) var attachedIDs: Set<UUID> = []
    /// Sessions whose per-display presentation fell back to the single spanned canvas
    /// (screen count changed between connect and present). Cleared on detach.
    @Published private(set) var fallbackIDs: Set<UUID> = []
    /// The session whose per-display window (any of the group) is key, if any. The
    /// clipboard focus gate accepts this alongside the normal key-window check.
    @Published private(set) var keySessionID: UUID?

    /// User closed one of the group's windows → same semantics as closing the tab.
    /// Registered by ContentView (funnels into `closeSession`).
    var onWindowClosed: ((UUID) -> Void)?

    private struct Attachment {
        let controller: SessionController
        let connection: Connection
        let coordinator: AppCoordinator
        let actions: SessionActions
        var stateSub: AnyCancellable?
        var windows: [NSWindow] = []       // [0] is the primary (toolbar) window
    }
    private var attachments: [UUID: Attachment] = [:]

    func isAttached(_ id: UUID) -> Bool { attachments[id] != nil }

    /// True when the main-window pane should show the placeholder instead of a canvas:
    /// attached and not fallen back.
    func isPresenting(_ id: UUID) -> Bool {
        attachedIDs.contains(id) && !fallbackIDs.contains(id)
    }

    // MARK: Attach / detach

    /// Register a per-display session at connect time. Replaces any previous
    /// attachment for the same id (reconnect with a fresh controller).
    func attach(sessionID: UUID, controller: SessionController, connection: Connection,
                coordinator: AppCoordinator, actions: SessionActions) {
        detach(sessionID)
        var attachment = Attachment(controller: controller, connection: connection,
                                    coordinator: coordinator, actions: actions)
        // @Published emits on willSet — use the PAYLOAD, never controller.state here.
        attachment.stateSub = controller.$state.sink { [weak self] state in
            // Re-dispatch so the handler never mutates state mid-publish.
            Task { @MainActor [weak self] in self?.handleState(state, for: sessionID) }
        }
        attachments[sessionID] = attachment
        attachedIDs.insert(sessionID)
    }

    /// Tear the presentation down entirely (session close / controller replacement).
    /// Never touches the session itself.
    func detach(_ id: UUID) {
        guard var attachment = attachments[id] else {
            fallbackIDs.remove(id)
            attachedIDs.remove(id)
            return
        }
        attachment.stateSub?.cancel()
        attachments[id] = nil
        closeWindows(&attachment)
        attachedIDs.remove(id)
        fallbackIDs.remove(id)
        if keySessionID == id { keySessionID = nil }
    }

    /// Bring the group to the front, primary window key (placeholder button, sidebar).
    func focus(_ id: UUID) {
        guard let windows = attachments[id]?.windows, let primary = windows.first else { return }
        for window in windows.dropFirst() { window.orderFront(nil) }
        primary.makeKeyAndOrderFront(nil)
    }

    // MARK: State-driven window lifecycle

    private func handleState(_ state: ConnectionState, for id: UUID) {
        guard attachments[id] != nil else { return }
        if case .connected = state {
            presentWindowsIfNeeded(for: id)
        } else {
            // Drop/reconnect/failure: the group comes down; the main-window placeholder
            // shows the overlays. A later reconnect re-presents (state → .connected).
            if var attachment = attachments[id], !attachment.windows.isEmpty {
                closeWindows(&attachment)
                attachments[id] = attachment
                if keySessionID == id { keySessionID = nil }
            }
        }
    }

    private func presentWindowsIfNeeded(for id: UUID) {
        guard let attachment = attachments[id], attachment.windows.isEmpty,
              !fallbackIDs.contains(id) else { return }
        let controller = attachment.controller
        let screens = NSScreen.screens
        // The monitors were derived index-aligned from NSScreen.screens at connect;
        // any drift means the arrangement changed — fall back, never guess.
        switch MonitorLayout.viewports(monitors: controller.monitors, screenCount: screens.count) {
        case .fallback(let reason):
            fallbackIDs.insert(id)
            controller.noteUIStatus("Per-display windows unavailable — \(reason). Showing the spanned desktop in one window.")
            return
        case .perDisplay(let viewports):
            // Primary (main remote monitor) window first so windows[0] is the toolbar
            // window and gets key focus.
            let ordered = viewports.sorted { $0.isPrimary && !$1.isPrimary }
            var windows: [NSWindow] = []
            for viewport in ordered {
                guard screens.indices.contains(viewport.screenIndex) else { continue }
                let screen = screens[viewport.screenIndex]
                let window = makeWindow(for: viewport, on: screen, attachment: attachment,
                                        displayNumber: viewport.screenIndex + 1)
                windows.append(window)
            }
            guard !windows.isEmpty else { return }
            var updated = attachment
            updated.windows = windows
            attachments[id] = updated
            for window in windows.dropFirst() { window.orderFront(nil) }
            windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    private func makeWindow(for viewport: MonitorLayout.Viewport, on screen: NSScreen,
                            attachment: Attachment, displayNumber: Int) -> NSWindow {
        let connection = attachment.connection
        let window = NSWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC owns it via `attachments`
        window.tabbingMode = .disallowed
        let name = connection.name.isEmpty ? connection.host : connection.name
        window.title = "\(name) — Display \(displayNumber)"
        window.subtitle = connection.host
        window.contentMinSize = NSSize(width: 320, height: 240)
        window.delegate = self

        let sinkID = UUID()
        let root: AnyView
        if viewport.isPrimary {
            // The primary window carries the full session toolbar (same NSToolbar
            // bridging as F-16's detached windows) + overlays/clipboard/stats via
            // SessionView, cropped to its viewport.
            // The title + subtitle stay visible here because a detached window has no tab
        // strip naming the session, and `.unified` gives them the room to draw.
        window.toolbarStyle = .unified
            root = AnyView(PerDisplayPrimaryRootView(
                controller: attachment.controller, connection: connection,
                actions: attachment.actions,
                viewport: viewport.remotePixelRect, sinkID: sinkID)
                .environmentObject(attachment.coordinator))
        } else {
            // Secondary windows are a bare canvas: full input (its own keyboard
            // capture per F-16's per-window semantics), no toolbar.
            root = AnyView(PerDisplaySecondaryRootView(
                controller: attachment.controller, connection: connection,
                viewport: viewport.remotePixelRect, sinkID: sinkID))
        }
        let hosting = NSHostingView(rootView: root)
        if viewport.isPrimary { hosting.sceneBridgingOptions = [.toolbars] }
        window.contentView = hosting
        window.setFrame(screen.visibleFrame, display: false)
        return window
    }

    /// Close every window of the group WITHOUT touching the session. Delegates are
    /// cleared first so `windowWillClose` can never re-enter for a programmatic close.
    private func closeWindows(_ attachment: inout Attachment) {
        let windows = attachment.windows
        attachment.windows = []
        for window in windows {
            window.delegate = nil
            window.close()
        }
    }

    private func sessionID(of window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return attachments.first(where: { $0.value.windows.contains(where: { $0 === window }) })?.key
    }
}

// MARK: NSWindowDelegate (per-display group)

extension PerDisplayWindowPresenter: NSWindowDelegate {
    /// Full screen: auto-hide the title/toolbar with the menu bar.
    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
    ) -> NSApplication.PresentationOptions {
        proposedOptions.union(fullScreenAutoHideOptions)
    }

    func windowWillClose(_ notification: Notification) {
        // Only reachable for a USER close (red button/⌘W) — programmatic paths clear
        // the delegate before close(). The GROUP closes as one: take the session down
        // through the same funnel as closing its tab.
        guard let window = notification.object as? NSWindow,
              let id = sessionID(of: window) else { return }
        if var attachment = attachments[id] {
            attachment.windows.removeAll { $0 === window }   // this one is already closing
            closeWindows(&attachment)                        // siblings, delegate-cleared
            attachment.stateSub?.cancel()
            attachments[id] = nil
        }
        attachedIDs.remove(id)
        fallbackIDs.remove(id)
        if keySessionID == id { keySessionID = nil }
        window.delegate = nil
        onWindowClosed?(id)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let id = sessionID(of: notification.object as? NSWindow) else { return }
        keySessionID = id
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let id = sessionID(of: notification.object as? NSWindow),
              keySessionID == id else { return }
        keySessionID = nil
    }
}

// MARK: - Per-display window root views (#22)

/// Root of the PRIMARY per-display window: the full SessionView (toolbar, overlays,
/// clipboard sync, stats — all the single-session machinery) cropped to the main
/// monitor's viewport. Its canvas registers a keyed multicast sink so the secondary
/// canvases receive frames too.
struct PerDisplayPrimaryRootView: View {
    @ObservedObject var controller: SessionController
    let connection: Connection
    let actions: SessionActions
    let viewport: CGRect
    let sinkID: UUID

    var body: some View {
        SessionView(controller: controller, connection: connection, actions: actions,
                    viewportRect: viewport, canvasSinkID: sinkID)
            .focusedSceneValue(\.activeSession, controller)
            .frame(minWidth: 320, minHeight: 240)
    }
}

/// Root of a SECONDARY per-display window: a bare cropped canvas. Input (pointer +
/// per-window keyboard capture) works exactly like any session canvas; clipboard,
/// overlays, and the toolbar live on the primary window / main-window placeholder.
struct PerDisplaySecondaryRootView: View {
    @ObservedObject var controller: SessionController
    let connection: Connection
    let viewport: CGRect
    let sinkID: UUID
    @State private var inputCaptured = false
    // Fixed: a viewport canvas is always aspect-fit (POL-4 — the layout is fixed at
    // connect; the toolbar scale picker is disabled for multimon anyway).
    @State private var scaleMode: DisplaySettings.ScaleMode = .fitToWindow
    @AppStorage("defaultModifierMode") private var modifierModeRaw: String = ModifierMode.cmdAsCtrl.rawValue

    private var isConnected: Bool {
        if case .connected = controller.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            RDPCanvasView(
                controller: controller,
                inputCaptured: $inputCaptured,
                scaleMode: $scaleMode,
                modifierMode: connection.modifierOverride.resolved(
                    global: ModifierMode(rawValue: modifierModeRaw) ?? .cmdAsCtrl),
                keyOverrides: connection.keyOverrides,
                useHiDPI: connection.display.useHiDPI,
                multiMonitor: true,
                viewportRect: viewport,
                sinkID: sinkID
            )
            // Same blackout rule as SessionView: never show a stale framebuffer for a
            // dead session (the group closes on state change, but not synchronously).
            if !isConnected {
                Color.black.ignoresSafeArea()
            }
        }
        .frame(minWidth: 320, minHeight: 240)
    }
}

/// What the MAIN window's tab pane shows for a session presented across display
/// windows (#22): a pointer to the windows while connected, and the full recovery
/// overlays (reusing SessionView's overlay components + cert review sheet) whenever
/// the session isn't live — so connect/reconnect/failure UX is never lost while the
/// canvas lives elsewhere.
struct PerDisplaySessionPlaceholderView: View {
    @ObservedObject var controller: SessionController
    let connection: Connection
    let actions: SessionActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayCount: Int { controller.monitors.count }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            stateContent
        }
        // First-connect certificate review must be reachable here — the per-display
        // windows (and their SessionView) exist only AFTER a successful connect.
        .sheet(item: $controller.pendingCertReview) { review in
            CertReviewSheet(review: review) {
                controller.acceptPendingCertAndReconnect()
            } onCancel: {
                controller.declinePendingCert()
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch controller.state {
        case .idle:
            EmptyView()
        case .connecting:
            ConnectionProgressOverlay(message: "Connecting…", detail: connection.host,
                                      showSpinner: true, reduceMotion: reduceMotion)
        case .authenticating:
            ConnectionProgressOverlay(message: "Authenticating…",
                                      detail: "Touch ID will prompt momentarily",
                                      showSpinner: true, reduceMotion: reduceMotion)
        case .negotiating:
            ConnectionProgressOverlay(message: "Negotiating…",
                                      detail: "Setting up secure channel",
                                      showSpinner: true, reduceMotion: reduceMotion)
        case .reconnecting(let attempt):
            ReconnectingOverlay(attempt: attempt,
                                maxAttempts: controller.maxReconnectAttempts,
                                delaySeconds: Int(controller.reconnectDelaySeconds(forAttempt: attempt).rounded()),
                                onCancel: { controller.disconnect() },
                                reduceMotion: reduceMotion)
        case .failed(let error):
            FailedOverlay(error: error, reduceMotion: reduceMotion) { perform($0) }
        case .disconnected(let reason):
            DisconnectedOverlay(reason: reason) { perform($0) }
        case .connected:
            connectedPlaceholder
        }
    }

    private var connectedPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Session is presented across \(displayCount) display windows")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Each Mac display shows its portion of the remote desktop. Closing any of the windows disconnects the session.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                PerDisplayWindowPresenter.shared.focus(connection.id)
            } label: {
                Label("Focus Display Windows", systemImage: "macwindow.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Bring the session's display windows to the front")
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    /// Same dispatch as `SessionView.perform` (the overlays are shared components).
    private func perform(_ action: RecoveryAction) {
        switch action {
        case .reviewCertificate:
            controller.reviewLastCertificate()
        case .retry, .reconnect:
            controller.retry()
        case .updatePassword, .editConnection:
            actions.editConnection()
        case .closeTab:
            actions.closeTab()
        }
    }
}
