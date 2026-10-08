import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TouchRDPCore
import TouchRDPEngine

// MARK: - Session actions (ContentView-owned callbacks)

/// Recovery callbacks that live in `ContentView` (which owns `closeSession` and the
/// editor context) but are invoked from overlays inside `SessionView`. Threaded down so
/// the failed/disconnected overlays can drive the *proven* close-tab and edit-connection
/// paths instead of the old dead `NotificationCenter` shim.
struct SessionActions {
    let closeTab: () -> Void
    let editConnection: () -> Void
}

// MARK: - SessionView

struct SessionView: View {
    @ObservedObject var controller: SessionController
    let connection: Connection
    let actions: SessionActions
    // #22: when this SessionView is the PRIMARY per-display window of a spanned
    // session, it renders only its display's crop of the spanned framebuffer
    // (remote-pixel rect) and registers its canvas frame/cursor sink under
    // `canvasSinkID` (multicast) instead of the exclusive `onFrame`. Both nil in the
    // ordinary single-canvas modes — zero behavior change there.
    let viewportRect: CGRect?
    let canvasSinkID: UUID?

    @State private var inputCaptured = false
    // F-5: session-shortcut cheat-sheet popover, anchored to the "?" toolbar item.
    @State private var showCheatSheet = false
    // F-14: "Log Off Remote Session…" confirmation + the post-CAD on-canvas hint.
    // RDP has no client→server logoff PDU (FreeRDP 3.x exposes only transport-level
    // disconnects), so the action sends Ctrl-Alt-Del and guides the user to Sign out.
    @State private var showLogOffConfirm = false
    @State private var showSignOutHint = false
    // Last NSPasteboard.changeCount we've seen/sent (−1 forces an initial push on connect).
    @State private var lastClipboardChange = -1
    // F-13: transient "Screenshot saved/copied" confirmation. The generation counter
    // gives the HUD a fresh identity (and timer) when the same message fires twice.
    @State private var screenshotToast: String?
    @State private var screenshotToastGeneration = 0
    // F-8: transient "Offering N files…" / rejection HUD (same pill as the screenshot
    // toast, clipboard icon).
    @State private var fileOfferToast: String?
    @State private var fileOfferToastGeneration = 0
    // F-16: identity token for this view's screenshot-action registration with
    // DetachedWindowManager (menu fallback when a detached window is key). Token-gated
    // so the nondeterministic appear/disappear ordering while a session MOVES between
    // windows can't drop the fresh view's registration.
    @State private var screenshotRegistrationToken = UUID()
    @State private var scaleMode: DisplaySettings.ScaleMode
    @AppStorage("defaultModifierMode") private var modifierModeRaw: String = ModifierMode.cmdAsCtrl.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Reflects whether THIS session's window is the key (focused) window. The
    // local→remote clipboard push is gated on this so the Mac clipboard is only ever
    // sent to the remote while the user is actively working in the session — not in the
    // background, which would silently exfiltrate anything copied anywhere on the Mac.
    @Environment(\.controlActiveState) private var controlActiveState

    init(controller: SessionController, connection: Connection, actions: SessionActions,
         viewportRect: CGRect? = nil, canvasSinkID: UUID? = nil) {
        self.controller = controller
        self.connection = connection
        self.actions = actions
        self.viewportRect = viewportRect
        self.canvasSinkID = canvasSinkID
        self._scaleMode = State(initialValue: connection.display.scaleMode)
    }

    /// True only while the session is live. Drives the `.task(id:)` timer loops
    /// (POL-5) so SwiftUI starts them on connect and cancels them on disconnect.
    private var isConnected: Bool {
        if case .connected = controller.state { return true }
        return false
    }

    /// F-10: the effective modifier mode for THIS session — the connection's
    /// per-host override when set, otherwise the app-wide preference. Everything
    /// downstream (canvas key handling, cheat sheet) uses this resolved value.
    private var resolvedModifierMode: ModifierMode {
        connection.modifierOverride.resolved(
            global: ModifierMode(rawValue: modifierModeRaw) ?? .cmdAsCtrl)
    }

    var body: some View {
        ZStack {
            canvasArea
            // When the session isn't live, cover the (retained) last frame with solid
            // black so the disconnect/reconnect overlay sits on a clean black screen
            // instead of a greyed-out snapshot of the old session.
            if showsBlackout {
                Color.black.ignoresSafeArea()
            }
            stateOverlay
            // UX-6: on-canvas hint that the keyboard is trapped, so a first-time user
            // isn't stuck wondering why ⌘-shortcuts stopped working.
            if inputCaptured, case .connected = controller.state {
                KeyboardCaptureHUD(reduceMotion: reduceMotion)
            }
            // F-14: after "Log Off Remote Session…" sends Ctrl-Alt-Del, point the user at
            // the security screen's Sign out entry (there is no protocol-level logoff).
            if showSignOutHint, case .connected = controller.state {
                SignOutHintHUD(reduceMotion: reduceMotion) { showSignOutHint = false }
            }
            // F-13: brief confirmation after Save/Copy Screenshot.
            if let toast = screenshotToast {
                ScreenshotToastHUD(message: toast, reduceMotion: reduceMotion) {
                    screenshotToast = nil
                }
                .id(screenshotToastGeneration)
            }
            // F-8: file-offer status ("Offering N files…" + per-file rejections).
            if let toast = fileOfferToast {
                ScreenshotToastHUD(message: toast, icon: "doc.on.clipboard",
                                   reduceMotion: reduceMotion) {
                    fileOfferToast = nil
                }
                .id(fileOfferToastGeneration)
            }
        }
        // F-8: drop files from Finder onto the session canvas → offer them to the
        // remote clipboard (the user then pastes in Explorer). Only accepted while
        // connected AND the per-connection "Send files" toggle is on.
        .dropDestination(for: URL.self) { urls, _ in
            handleFileDrop(urls)
        }
        // F-13: publish Save/Copy Screenshot for the Connection menu (see ConnectMenuItems).
        .focusedSceneValue(\.sessionScreenshot, SessionScreenshotAction(
            save: { captureScreenshot(toPasteboard: false) },
            copy: { captureScreenshot(toPasteboard: true) }))
        // F-16: also register the same actions with the tear-off manager, so the
        // Connection-menu items keep working when this session lives in a detached
        // AppKit window (where the focused scene value may not bridge).
        .onAppear {
            DetachedWindowManager.shared.registerScreenshot(
                SessionScreenshotAction(save: { captureScreenshot(toPasteboard: false) },
                                        copy: { captureScreenshot(toPasteboard: true) }),
                for: connection.id, token: screenshotRegistrationToken)
        }
        .onDisappear {
            DetachedWindowManager.shared.unregisterScreenshot(
                for: connection.id, token: screenshotRegistrationToken)
        }
        // F-14: destructive confirmation before touching the remote session's programs.
        .confirmationDialog(
            "Log off the remote Windows session?",
            isPresented: $showLogOffConfirm,
            titleVisibility: .visible
        ) {
            Button("Send Ctrl-Alt-Del to Sign Out", role: .destructive) {
                controller.sendCtrlAltDel()
                showSignOutHint = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out the remote Windows session, closing its programs. TouchRDP opens the remote security screen — choose “Sign out” there to finish.")
        }
        .toolbar {
            sessionToolbar
        }
        // Drive the cert review directly off the pending item so it presents reliably
        // whenever a certificate needs review — including a first-use TOFU rejection, where
        // the failed-state overlay swaps in during the same update tick.
        .sheet(item: $controller.pendingCertReview) { review in
            CertReviewSheet(review: review) {
                controller.acceptPendingCertAndReconnect()
            } onCancel: {
                controller.declinePendingCert()
            }
        }
        // Clipboard sync (both directions). Closures are kept thin (delegating to methods)
        // so the body stays type-checkable.
        .onReceive(NotificationCenter.default.publisher(for: .touchRDPRemoteClipboard)) { note in
            receiveRemoteClipboardText(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .touchRDPRemoteClipboardImage)) { note in
            receiveRemoteClipboardImage(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .touchRDPRemoteClipboardFiles)) { note in
            receiveRemoteClipboardFiles(note)
        }
        // POL-5: local→remote clipboard poll (~600 ms) driven by a task tied to the
        // connected state. SwiftUI starts it on connect and cancels it on disconnect —
        // no wall-clock timers firing while the session is idle/failed/reconnecting.
        .task(id: isConnected) {
            guard isConnected else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled { break }
                pollLocalClipboard()
            }
        }
        // POL-5: quality-indicator stats sampled ~1 Hz, same connected-only lifecycle.
        .task(id: isConnected) {
            guard isConnected else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                controller.sampleStats()
            }
        }
    }

    // MARK: - Clipboard sync

    private var clipboardActive: Bool {
        if case .connected = controller.state { return connection.clipboardEnabled }
        return false
    }

    /// Remote → local (text). Mirror the remote text into the Mac pasteboard.
    private func receiveRemoteClipboardText(_ note: Notification) {
        guard clipboardActive,
              let text = controller.clipboardPayload(from: note, as: String.self) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastClipboardChange = pb.changeCount   // record our own write so we don't echo it back
    }

    /// Remote → local (image). Gated on the per-connection image toggle (off by default).
    private func receiveRemoteClipboardImage(_ note: Notification) {
        guard clipboardActive, connection.imageClipboardEnabled,
              let cg = controller.clipboardPayload(from: note, as: CGImage.self) else { return }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        lastClipboardChange = pb.changeCount   // suppress the echo back to the remote
    }

    /// #25 remote → local (FILES). The server's clipboard holds files: stage one file
    /// PROMISE per descriptor on the Mac pasteboard. No bytes move here — pasting/
    /// dropping in Finder fulfills each promise by pulling contents over cliprdr (see
    /// `RemoteFilePromiseCoordinator` / `RemoteFilePuller`). Precedence: files REPLACE
    /// any text/image for this clipboard generation (`pb.clearContents()`), mirroring
    /// Windows Explorer semantics — the bridge only requests ONE format per remote
    /// announcement anyway (files preferred). Gated on the same per-connection file
    /// toggle as the F-8 outbound offer, which now governs BOTH directions.
    private func receiveRemoteClipboardFiles(_ note: Notification) {
        guard clipboardActive, connection.fileClipboardEnabled,
              let announcement = controller.clipboardPayload(from: note, as: RemoteFileAnnouncement.self),
              !announcement.descriptors.isEmpty else { return }
        let coordinator = RemoteFilePromiseCoordinator(announcement: announcement,
                                                       puller: controller.filePuller)
        let providers = coordinator.makeProviders()
        guard !providers.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(providers)
        lastClipboardChange = pb.changeCount   // suppress the echo back to the remote
    }

    /// Local → remote. macOS has no pasteboard-change notification, so poll the
    /// changeCount while connected and push new content — but ONLY while this session's
    /// window is focused (controlActiveState == .key). The focus check comes BEFORE the
    /// change-marker so we do NOT consume clipboard changes made while unfocused: the
    /// common workflow is to copy in another Mac app, then switch to the session to paste.
    /// Bringing the session to the front is the user's implicit consent to share the
    /// clipboard with that host, so on refocus we push whatever is currently there. Nothing
    /// is ever pushed while the session is in the background.
    /// Precedence (F-8): FILE URLs first (only when the per-connection file toggle is
    /// on — a Finder ⌘C also puts the file NAME on the pasteboard as a string, so files
    /// must be checked before text or the poll would push just the name), then the
    /// shipped text-before-image order, unchanged. With the file toggle off, behavior
    /// is bit-identical to before (a copied file still pushes its name as text).
    /// Focus gate for the local→remote push. Ordinarily "this view's window is key";
    /// #22: a per-display session is ONE session shown across several windows, so any
    /// of its group's windows being key counts as the user actively working in it
    /// (mirrors how a detached window's own key state gates its SessionView).
    private var sessionWindowIsKey: Bool {
        controlActiveState == .key
            || PerDisplayWindowPresenter.shared.keySessionID == connection.id
    }

    private func pollLocalClipboard() {
        guard clipboardActive, sessionWindowIsKey else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastClipboardChange else { return }
        // #23: read BEFORE consuming the change-marker. Some writers (browsers,
        // clipboard managers) bump changeCount and fulfil the data lazily via
        // pasteboard promises, so a poll tick can land on a changed-but-not-yet-
        // readable pasteboard. Consuming the marker up front turned that timing into
        // a silently swallowed copy — the marker now advances only once something was
        // actually pushed, so an unreadable tick just retries on the next 600 ms poll.
        if connection.fileClipboardEnabled, let files = Self.pasteboardFileURLs(pb) {
            lastClipboardChange = pb.changeCount
            if let outcome = controller.offerFiles(urls: files) {
                showFileOfferToast(for: outcome)
            }
        } else if let text = Self.pasteboardText(pb) {
            lastClipboardChange = pb.changeCount
            controller.setClipboardText(text)
        } else if connection.imageClipboardEnabled, let cg = Self.pasteboardImage(pb) {
            lastClipboardChange = pb.changeCount
            controller.setClipboardImage(cg)
        }
    }

    /// #23: the pasteboard's best text representation. Plain string first, then a
    /// URL-only pasteboard — some apps' "Copy Link" writes public.url with no
    /// plain-text sibling, which used to read as "nothing to push" and the copied
    /// link never reached the remote.
    private static func pasteboardText(_ pb: NSPasteboard) -> String? {
        if let s = pb.string(forType: .string), !s.isEmpty { return s }
        if let s = pb.string(forType: .URL), !s.isEmpty { return s }
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first,
           !url.isFileURL {
            return url.absoluteString
        }
        return nil
    }

    /// F-8: file URLs currently on the pasteboard (Finder ⌘C), or nil when none.
    private static func pasteboardFileURLs(_ pb: NSPasteboard) -> [URL]? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard pb.canReadObject(forClasses: [NSURL.self], options: opts),
              let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
              !urls.isEmpty else { return nil }
        return urls
    }

    /// F-8: Finder → canvas drop. Returns false (drop rejected) when the feature is
    /// off/disconnected so the system shows the "not allowed" cursor instead of
    /// silently swallowing the files.
    private func handleFileDrop(_ urls: [URL]) -> Bool {
        guard clipboardActive, connection.fileClipboardEnabled else { return false }
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty,
              let outcome = controller.offerFiles(urls: fileURLs) else { return false }
        showFileOfferToast(for: outcome)
        return outcome.offeredCount > 0
    }

    private func showFileOfferToast(for outcome: SessionController.FileOfferOutcome) {
        var parts: [String] = []
        if outcome.offeredCount > 0 {
            let mb = Double(outcome.totalBytes) / (1024 * 1024)
            parts.append(String(format: "Offering %d file%@ to remote clipboard (%.1f MB) — paste in Explorer",
                                outcome.offeredCount, outcome.offeredCount == 1 ? "" : "s", mb))
        }
        parts.append(contentsOf: outcome.notes)
        guard !parts.isEmpty else { return }
        fileOfferToast = parts.joined(separator: " · ")
        fileOfferToastGeneration += 1
    }

    /// Read a bitmap from the pasteboard as a CGImage (nil if there isn't one). Used for
    /// the local→remote image push; only called when image sync is enabled.
    private static func pasteboardImage(_ pb: NSPasteboard) -> CGImage? {
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil),
              let img = NSImage(pasteboard: pb) else { return nil }
        var rect = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // Black out the stale framebuffer for every state except a live connection.
    private var showsBlackout: Bool {
        if case .connected = controller.state { return false }
        return true
    }

    // MARK: - Session screenshot (F-13)

    /// Capture the CURRENT remote framebuffer at full remote resolution (the raw
    /// CGImage, not the scaled view rendering). A spanned multi-monitor session captures
    /// its single spanned frame. SECURITY (F-13 invariant): this is the remote desktop's
    /// own content, and it is written ONLY on explicit user action — to a user-chosen
    /// file via NSSavePanel or to the general pasteboard — never auto-saved anywhere.
    private func captureScreenshot(toPasteboard: Bool) {
        guard case .connected = controller.state,
              let cg = controller.currentFrame?.makeCGImage() else {
            NSSound.beep()   // no live frame to capture (menu raced a disconnect)
            return
        }
        if toPasteboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([NSImage(cgImage: cg,
                                     size: NSSize(width: cg.width, height: cg.height))])
            // Record our own write so the local→remote clipboard poll doesn't echo the
            // screenshot straight back to the host it came from.
            lastClipboardChange = pb.changeCount
            showScreenshotToast("Screenshot copied")
        } else {
            saveScreenshot(cg)
        }
    }

    /// Save the frame as PNG via an NSSavePanel (sheet on the session window when
    /// possible). Default name: "TouchRDP <connection> <timestamp>.png", sanitized.
    private func saveScreenshot(_ cg: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ScreenshotNaming.defaultFileName(
            connectionName: connection.name.isEmpty ? connection.host : connection.name)
        let finish: (URL?) -> Void = { url in
            guard let url else { return }   // user cancelled
            guard let data = Self.pngData(cg) else {
                showScreenshotToast("Couldn't encode screenshot")
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                showScreenshotToast("Screenshot saved")
            } catch {
                showScreenshotToast("Couldn't save screenshot")
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { finish($0 == .OK ? panel.url : nil) }
        } else {
            finish(panel.runModal() == .OK ? panel.url : nil)
        }
    }

    /// Full-fidelity PNG encode of the raw framebuffer (no re-scaling).
    private static func pngData(_ cg: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private func showScreenshotToast(_ message: String) {
        screenshotToast = message
        screenshotToastGeneration += 1
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasArea: some View {
        // #22: a viewport crop is always presented aspect-fit in its window (the layout
        // is fixed at connect — POL-4), so the 1:1 scroll container applies only to the
        // whole-frame modes.
        if scaleMode == .oneToOne && viewportRect == nil {
            ScrollView([.horizontal, .vertical]) {
                sessionCanvas
                    .frame(
                        width: controller.remoteSize.width > 0 ? controller.remoteSize.width : nil,
                        height: controller.remoteSize.height > 0 ? controller.remoteSize.height : nil
                    )
            }
        } else {
            sessionCanvas
        }
    }

    private var sessionCanvas: some View {
        RDPCanvasView(
            controller: controller,
            inputCaptured: $inputCaptured,
            scaleMode: $scaleMode,
            modifierMode: resolvedModifierMode,
            keyOverrides: connection.keyOverrides,
            useHiDPI: connection.display.useHiDPI,
            multiMonitor: connection.display.useAllDisplays,
            viewportRect: viewportRect,
            sinkID: canvasSinkID
        )
    }

    // MARK: - State overlays

    @ViewBuilder
    private var stateOverlay: some View {
        switch controller.state {
        case .idle:
            EmptyView()

        case .connecting:
            ConnectionProgressOverlay(
                message: "Connecting…",
                detail: connection.host,
                showSpinner: true,
                reduceMotion: reduceMotion
            )

        case .authenticating:
            ConnectionProgressOverlay(
                message: "Authenticating…",
                detail: "Touch ID will prompt momentarily",
                showSpinner: true,
                reduceMotion: reduceMotion
            )

        case .negotiating:
            ConnectionProgressOverlay(
                message: "Negotiating…",
                detail: "Setting up secure channel",
                showSpinner: true,
                reduceMotion: reduceMotion
            )

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
            EmptyView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var sessionToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if case .connected = controller.state {
                QualityIndicator(controller: controller)
            }
        }

        // F-26: "Stay awake" toggle — bounded remote-lock deferral. OFF on every new
        // connection (runtime-only state); shown only while connected so the control
        // can never arm a dead session.
        ToolbarItem(placement: .primaryAction) {
            if case .connected = controller.state {
                StayAwakeButton(controller: controller)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("Scale", selection: $scaleMode) {
                ForEach(DisplaySettings.ScaleMode.allCases, id: \.self) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            // POL-4: scale/pinch are inert in multi-monitor mode (the layout is fixed at
            // connect), so disable the control rather than let it silently do nothing.
            .disabled(connection.display.useAllDisplays)
            .help(connection.display.useAllDisplays
                  ? "Scaling is fixed while spanning all displays (multi-monitor)"
                  : "Display scale mode")
            .accessibilityLabel("Display scale mode")
        }

        ToolbarItem(placement: .primaryAction) {
            Button(inputCaptured ? "Release Keyboard" : "Capture Keyboard") {
                inputCaptured.toggle()
            }
            .help(inputCaptured ? "Release keyboard — Cmd+Esc" : "Capture keyboard input")
            .accessibilityLabel(inputCaptured ? "Release keyboard capture" : "Capture keyboard input")
        }

        // F-4: Send Keys menu — special keys a Mac keyboard can't produce or that macOS
        // would intercept. Absorbs the old dedicated Ctrl-Alt-Del button (first item).
        ToolbarItem(placement: .primaryAction) {
            Menu("Send Keys") {
                SendKeysMenuItems(controller: controller)
                Divider()
                // F-14: graceful sign-out lives with the other remote-key actions. It is
                // Ctrl-Alt-Del + guidance (no client-initiated logoff PDU exists in RDP),
                // gated behind a confirmation dialog owned by the view.
                Button("Log Off Remote Session…") { showLogOffConfirm = true }
            }
            .disabled(controller.state != .connected)
            .help("Send special keys to the remote (Ctrl-Alt-Del, Windows key, PrintScreen…)")
            .accessibilityLabel("Send special keys to remote")
        }

        // F-27: type the vaulted password into the LIVE session (the remote lock screen).
        // A DEDICATED control on purpose — never folded into the Send Keys menu and
        // never attached to a reconnect/retry affordance. Nothing in RDP reports lock
        // state, so the client cannot verify what has focus on the remote side; using
        // this has to be a conscious act, and the Touch ID prompt it raises is the
        // confirmation step. Hidden entirely unless the connection opts in.
        ToolbarItem(placement: .primaryAction) {
            if connection.passwordTypingEnabled, case .connected = controller.state {
                Button(action: { controller.typePasswordIntoSession() }) {
                    Label("Type Password", systemImage: "key.fill")
                }
                .disabled(controller.isTypingPassword)
                .help("Touch ID, then type this connection's password into the remote lock screen and press Return.")
                .accessibilityLabel("Type the saved password into the remote session")
            }
        }

        // F-13: session screenshot — the raw full-resolution framebuffer, saved as PNG
        // (NSSavePanel) or copied to the pasteboard. Two explicit items instead of an
        // ⌥-modifier variant; also in the Connection menu (⇧⌘S / ⇧⌘C).
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Save Screenshot…") { captureScreenshot(toPasteboard: false) }
                Button("Copy Screenshot") { captureScreenshot(toPasteboard: true) }
            } label: {
                Image(systemName: "camera")
            }
            .disabled(controller.state != .connected)
            .help("Capture the remote screen — save as PNG or copy")
            .accessibilityLabel("Capture a screenshot of the remote screen")
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: { NSApplication.shared.mainWindow?.toggleFullScreen(nil) }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Toggle full screen")
            .accessibilityLabel("Toggle full screen")
        }

        // F-5: session-shortcut cheat sheet ("?").
        ToolbarItem(placement: .primaryAction) {
            Button(action: { showCheatSheet.toggle() }) {
                Image(systemName: "questionmark.circle")
            }
            .help("Session shortcuts")
            .accessibilityLabel("Show session shortcuts")
            .popover(isPresented: $showCheatSheet, arrowEdge: .bottom) {
                SessionCheatSheet(
                    modifierMode: resolvedModifierMode,   // F-10: reflect the per-host override
                    multiMonitor: connection.display.useAllDisplays
                )
            }
        }

        ToolbarItem(placement: .destructiveAction) {
            Button(action: { controller.disconnect() }) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .help("Disconnect session")
            .accessibilityLabel("Disconnect from remote")
        }
    }
}

extension DisplaySettings.ScaleMode {
    var shortLabel: String {
        switch self {
        case .dynamic: return "Auto"
        case .fitToWindow: return "Fit"
        case .oneToOne: return "1:1"
        }
    }
}

// MARK: - Stay awake toggle (F-26)

/// Toolbar toggle for the bounded remote-lock deferral. OFF: plain moon icon. ON:
/// filled+tinted icon plus the remaining awake time ("4:12", monospaced digits) so the
/// feature is never silently deferring a lock policy. Runtime-only — always starts off.
struct StayAwakeButton: View {
    @ObservedObject var controller: SessionController

    private var capMinutes: Int { Int(controller.stayAwakeCapSeconds / 60) }

    var body: some View {
        let remaining = controller.stayAwakeRemainingSeconds
        Button(action: { controller.toggleStayAwake() }) {
            HStack(spacing: 4) {
                Image(systemName: remaining != nil ? "moon.zzz.fill" : "moon.zzz")
                if let remaining {
                    Text(Self.timeString(remaining))
                        .font(.callout.monospacedDigit())
                }
            }
            .foregroundStyle(remaining != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .help(remaining != nil
              ? "Stay awake is on — the remote won't lock for up to \(capMinutes) min after your last activity. Click to turn off."
              : "Keep remote session awake (up to \(capMinutes) min)")
        .accessibilityLabel(remaining.map {
            "Stay awake on, \(Self.timeString($0)) remaining. Turn off."
        } ?? "Keep remote session awake, up to \(capMinutes) minutes")
    }

    /// "4:12"-style m:ss (hours roll into minutes; the cap maxes at 60 min).
    static func timeString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Quality indicator

/// Compact live session-quality readout for the toolbar: frame rate, throughput, and
/// (when the server reports network autodetect) round-trip latency, with a latency dot.
struct QualityIndicator: View {
    @ObservedObject var controller: SessionController

    private var throughputText: String {
        let kbps = controller.throughputKBps
        if kbps >= 1024 { return String(format: "%.1f MB/s", kbps / 1024) }
        return String(format: "%.0f KB/s", max(0, kbps))
    }

    private var latencyColor: Color {
        let ms = controller.rttMs
        if ms == 0 { return .secondary }   // unknown (server didn't report it)
        if ms < 60 { return .green }
        if ms < 150 { return .yellow }
        return .red
    }

    private var summary: String {
        var parts = ["\(Int(controller.fps.rounded())) fps", throughputText]
        if controller.rttMs > 0 { parts.append("\(controller.rttMs) ms") }
        // PERF-8/9: HW when this build decodes H.264 on VideoToolbox AND this connection
        // opted in; SW when the build could but the connection turned it off. A
        // software-only (Homebrew) build shows neither — the help text says why.
        if controller.hardwareH264DecodeAvailable {
            parts.append(hardwareDecodeOnForConnection ? "HW" : "SW")
        }
        return parts.joined(separator: " · ")
    }

    private var hardwareDecodeOnForConnection: Bool {
        controller.connection?.videoDecoding.hardwareDecodeEnabled ?? true
    }

    private var decodeHelp: String {
        guard controller.hardwareH264DecodeAvailable else {
            return "; H.264 decoded in software (FreeRDP built without VideoToolbox)"
        }
        return hardwareDecodeOnForConnection
            ? "; H.264 hardware decode (VideoToolbox) on for this connection"
            : "; H.264 decoded in software (hardware decode off for this connection)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(latencyColor).frame(width: 7, height: 7)
            Text(summary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // Reserve room and never compress: without this the toolbar truncates the readout
        // and it overlaps the next item. fixedSize keeps it at its natural width; the
        // padding adds breathing space before the neighbouring control.
        .fixedSize()
        .padding(.trailing, 8)
        .help("Live quality — frame rate, throughput" +
              (controller.rttMs > 0 ? ", round-trip latency" : " (latency unavailable)") +
              decodeHelp)
        .accessibilityLabel("Connection quality: \(summary)")
    }
}

// MARK: - RDPCanvasView (NSViewRepresentable)

struct RDPCanvasView: NSViewRepresentable {
    @ObservedObject var controller: SessionController
    @Binding var inputCaptured: Bool
    // A binding so the pinch-to-zoom trackpad gesture can drive the scale mode (and keep
    // the toolbar picker in sync).
    @Binding var scaleMode: DisplaySettings.ScaleMode
    let modifierMode: ModifierMode
    // F-15: per-connection scancode overrides for the mapper (applied before the
    // standard table). The connection is immutable for the life of a session view,
    // so this is effectively fixed at session setup.
    let keyOverrides: [KeyOverride]
    let useHiDPI: Bool
    // POL-4: when the session spans all displays the remote monitor layout is fixed at
    // connect, so live scale/pinch/window-follow resize are suppressed downstream.
    let multiMonitor: Bool
    // #22: remote-pixel crop of the spanned framebuffer this canvas shows (nil = whole
    // frame — the unchanged single-canvas behavior).
    var viewportRect: CGRect? = nil
    // #22: when set, this canvas registers a KEYED multicast frame/cursor sink
    // (several per-display canvases render the same session) instead of taking the
    // exclusive `onFrame`/`onCursor`. nil = the unchanged exclusive binding.
    var sinkID: UUID? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, inputCapturedBinding: $inputCaptured,
                    modifierMode: modifierMode, keyOverrides: keyOverrides, sinkID: sinkID)
    }

    /// Bind the frame/cursor delivery for this canvas: keyed multicast sink when
    /// `sinkID` is set (#22 per-display canvases), else the exclusive single-canvas
    /// closures — bit-identical to the pre-#22 wiring.
    private func bindSinks(to view: RDPNSView?) {
        if let sinkID {
            controller.setFrameSink({ [weak view] image in view?.currentFrame = image }, for: sinkID)
            controller.setCursorSink({ [weak view] update in view?.applyRemoteCursor(update) }, for: sinkID)
        } else {
            controller.onFrame = { [weak view] image in view?.currentFrame = image }
            controller.onCursor = { [weak view] update in view?.applyRemoteCursor(update) }
        }
    }

    func makeNSView(context: Context) -> RDPNSView {
        let view = RDPNSView(coordinator: context.coordinator)
        context.coordinator.canvasView = view
        // Seed the first frame, then receive subsequent frames directly (off the
        // SwiftUI invalidation path) so video-rate updates don't re-render the tree.
        view.viewportRect = viewportRect
        view.currentFrame = controller.currentFrame
        view.applyRemoteCursor(controller.currentCursor)
        bindSinks(to: view)
        // Pinch-to-zoom: toggle between Fit and 1:1 (there is no continuous local zoom).
        let pinch = NSMagnificationGestureRecognizer(target: view,
                                                     action: #selector(RDPNSView.handleMagnify(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }

    // #22: a keyed sink must be removed when SwiftUI tears the canvas down, or the
    // controller would retain a dead closure per closed window.
    static func dismantleNSView(_ nsView: RDPNSView, coordinator: Coordinator) {
        if let sinkID = coordinator.sinkID {
            coordinator.controller.setFrameSink(nil, for: sinkID)
            coordinator.controller.setCursorSink(nil, for: sinkID)
        }
    }

    func updateNSView(_ nsView: RDPNSView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.modifierMode = modifierMode
        context.coordinator.keyOverrides = keyOverrides
        // Re-bind the frame + cursor sinks in case the view/controller pairing changed.
        bindSinks(to: nsView)
        nsView.viewportRect = viewportRect
        nsView.scaleMode = scaleMode
        nsView.useHiDPI = useHiDPI
        nsView.multiMonitor = multiMonitor
        nsView.remoteSize = controller.remoteSize
        // POL-1: reconcile the canvas's first-responder status to the capture toggle so
        // the toolbar "Capture/Release Keyboard" button (and Cmd-Esc) actually take or
        // return the keyboard — becomeFirstResponder resyncs the keyboard baseline, and
        // resignFirstResponder releases held modifiers. Guarded by an isFR check so we
        // never re-set the responder we already have (which would thrash focus every
        // SwiftUI update).
        let isFR = (nsView.window?.firstResponder === nsView)
        if inputCaptured, !isFR {
            nsView.window?.makeFirstResponder(nsView)
        } else if !inputCaptured, isFR {
            nsView.window?.makeFirstResponder(nil)
        }
        // Pinch zoom toggles Fit ↔ 1:1. Capture the binding so the gesture updates the
        // shared scale-mode state (and the toolbar picker) too.
        let scaleBinding = $scaleMode
        context.coordinator.onZoom = { zoomIn in
            if zoomIn {
                if scaleBinding.wrappedValue != .oneToOne { scaleBinding.wrappedValue = .oneToOne }
            } else if scaleBinding.wrappedValue == .oneToOne {
                scaleBinding.wrappedValue = .fitToWindow
            }
        }
        // Push the keyboard baseline (Caps Lock + a stuck-modifier-clearing synchronize)
        // once when the session reaches `.connected`, since focus-in may have happened
        // before the session was ready.
        nsView.syncBaselineIfNewlyConnected(state: controller.state)
        // PERF-4: no unconditional redisplay here — every input that actually affects
        // the layer (currentFrame, scaleMode, viewportRect, useHiDPI, multiMonitor,
        // remoteSize, frame size, backing scale) marks needsDisplay from its own
        // change-guarded didSet/override, so a SwiftUI pass that changed nothing
        // (toolbar state, key focus) no longer forces an updateLayer() transaction.
        // Dynamic mode follows the window. This runs whenever SwiftUI updates the view —
        // crucially when the state flips to `.connected` — so the remote is matched to
        // the window automatically after connect. Deduped downstream (identical sizes
        // are dropped); skipped during a live drag, which is handled at drag end.
        if scaleMode == .dynamic, !nsView.inLiveResize {
            nsView.requestDynamicResize()
        }
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator {
        var controller: SessionController
        // F-10: updated by updateNSView with the RESOLVED (per-connection else global)
        // mode; keep the mapper in lockstep so literal-mode key events stay correct.
        var modifierMode: ModifierMode {
            didSet { keyboardMapper.modifierMode = modifierMode }
        }
        // F-15: per-connection overrides — rebuild the mapper's lookup dict only when
        // the list actually changes (never per keypress).
        var keyOverrides: [KeyOverride] {
            didSet {
                if keyOverrides != oldValue { keyboardMapper.setKeyOverrides(keyOverrides) }
            }
        }
        weak var canvasView: RDPNSView?
        private var inputCapturedBinding: Binding<Bool>
        let keyboardMapper: ScancodeKeyboardMapper
        /// #22: this canvas's keyed sink token (nil = exclusive single-canvas binding).
        /// Held here so `dismantleNSView` can unregister exactly this canvas's sinks.
        let sinkID: UUID?
        /// Set by `updateNSView`; invoked by the pinch gesture. `zoomIn == true` means
        /// pinch-out (toward 1:1), `false` means pinch-in (toward Fit).
        var onZoom: ((Bool) -> Void)?

        init(controller: SessionController, inputCapturedBinding: Binding<Bool>,
             modifierMode: ModifierMode, keyOverrides: [KeyOverride] = [],
             sinkID: UUID? = nil) {
            self.controller = controller
            self.inputCapturedBinding = inputCapturedBinding
            self.modifierMode = modifierMode
            self.keyOverrides = keyOverrides
            self.sinkID = sinkID
            self.keyboardMapper = ScancodeKeyboardMapper(modifierMode: modifierMode,
                                                         keyOverrides: keyOverrides)
        }

        var inputCaptured: Bool {
            get { inputCapturedBinding.wrappedValue }
            set { inputCapturedBinding.wrappedValue = newValue }
        }

        func handleKeyActions(_ actions: [KeyAction]) {
            for action in actions {
                switch action.kind {
                case .scancode(let code, let extended):
                    controller.sendScancode(code, down: action.down, extended: extended)
                case .unicode(let code):
                    controller.sendUnicode(code, down: action.down)
                }
            }
        }

        // MARK: Modifier state reconciliation

        // Pure, unit-tested diff logic lives in TouchRDPCore.ModifierReconciler.
        private var modReconciler = ModifierReconciler()

        /// Drive the remote modifier state to match `flags`, sending only the diffs
        /// (key-up for released, key-down for newly pressed). Fixes stuck modifiers and
        /// self-heals missed events; pass `[]` to release everything on focus loss.
        func syncModifiers(to flags: NSEvent.ModifierFlags) {
            let actions = modReconciler.reconcile(
                shift: flags.contains(.shift),
                control: flags.contains(.control),
                option: flags.contains(.option),
                command: flags.contains(.command),
                mode: modifierMode)
            handleKeyActions(actions)
        }

        /// Re-establish the remote keyboard baseline: push the toggle-key (Caps Lock)
        /// state via an RDP synchronize event, then re-assert any currently-held
        /// modifiers. The synchronize event also resets the server's Shift/Ctrl/Alt to
        /// UP, so we clear the reconciler's held set (no key-ups needed — the server
        /// already released them) and re-press what's actually down now.
        ///
        /// Call this ONLY on focus-in and Caps Lock changes — NEVER on every click. A
        /// synchronize event per click would reset modifiers right before the click,
        /// breaking Shift/Ctrl-click multi-select (the reconciler would think the
        /// modifier was still held and never re-send it).
        func resyncKeyboardBaseline(capsLock: Bool, modifiers: NSEvent.ModifierFlags) {
            controller.sendKeyboardSync(capsLock: capsLock, numLock: true, scrollLock: false)
            modReconciler.markAllReleased()
            syncModifiers(to: modifiers)
        }
    }
}

// MARK: - RDPNSView

@MainActor
final class RDPNSView: NSView {
    weak var coordinator: RDPCanvasView.Coordinator?
    // PERF-5: an IOSurface-backed frame; `updateLayer()` hands the surface itself to
    // the content layer, so displaying a frame never copies the framebuffer again.
    var currentFrame: RemoteFrame? {
        didSet {
            needsDisplay = true
            // Re-scale the remote cursor only when the framebuffer's pixel size changes (a
            // remote re-resolution) — its scale is derived from the frame size (#26). Cheap:
            // this skips the per-frame video updates where the size is unchanged.
            let dims = currentFrame.map { ($0.width, $0.height) }
            if dims?.0 != lastFrameDimensions?.0 || dims?.1 != lastFrameDimensions?.1 {
                lastFrameDimensions = dims
                rebuildRemoteCursor()
            }
        }
    }
    private var lastFrameDimensions: (Int, Int)?
    var scaleMode: DisplaySettings.ScaleMode = .dynamic {
        didSet {
            guard scaleMode != oldValue else { return }  // updateNSView reassigns every pass
            needsDisplay = true
            // Switching to Dynamic should immediately match the remote to the window.
            if scaleMode == .dynamic { requestDynamicResize() }
        }
    }
    // Retina toggle: when on, Auto requests 2× (backing-pixel) resolution; off = 1×.
    var useHiDPI: Bool = true {
        didSet { if useHiDPI != oldValue { needsDisplay = true } }
    }
    // POL-4: multi-monitor sessions have a fixed remote layout — suppress pinch-zoom and
    // dynamic window-follow resize, which would otherwise fight the spanned layout.
    var multiMonitor: Bool = false {
        didSet { if multiMonitor != oldValue { needsDisplay = true } }
    }
    // #22: the remote-pixel sub-rect of the spanned framebuffer this canvas displays
    // (one Mac display's monitor). nil = whole frame (unchanged single-canvas path).
    // The crop is applied via the layer's normalized `contentsRect` (no pixel copies);
    // fit scale, cursor sizing, and input mapping all key off this rect.
    var viewportRect: CGRect? {
        didSet {
            guard viewportRect != oldValue else { return }
            needsDisplay = true
            rebuildRemoteCursor()   // cursor size derives from the fit scale (#26)
        }
    }
    var remoteSize: CGSize = .zero {
        didSet { if remoteSize != oldValue { needsDisplay = true } }
    }
    // One-shot guard so the keyboard baseline is pushed once per connected session.
    private var didBaselineForConnection = false

    // Fractional wheel-delta accumulators (RDP wheel units). macOS delivers sub-unit
    // precise-scroll deltas that Int() truncation used to silently drop; we accumulate the
    // remainder across events so slow scrolls still register.
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    // Cumulative pinch magnification since the last zoom step (reset as steps fire).
    private var pinchAccum: CGFloat = 0

    // The cursor the remote host wants displayed (mirrors the remote pointer shape).
    private var remoteCursor: NSCursor = .arrow
    // The last raw cursor update from the host, retained so the NSCursor can be rebuilt at
    // the correct physical size when the window moves between displays of different backing
    // scale (Retina <-> non-Retina). Rebuilt in viewDidChangeBackingProperties() (#26).
    private var lastCursorUpdate: CursorUpdate = .arrow
    // Whether the mouse is currently over this view, so a cursor update that arrives
    // while the pointer is stationary can be applied immediately (and we never stomp the
    // cursor while the pointer is over the toolbar / elsewhere).
    private var pointerInside = false
    // A fully transparent cursor used for the remote "hide pointer" request — safer than
    // NSCursor.hide()/unhide(), which must be balanced app-wide.
    private static let hiddenCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))   // empty → nothing drawn
        return NSCursor(image: img, hotSpot: .zero)
    }()

    // The framebuffer is rendered by a dedicated sublayer whose frame WE compute
    // (displayedContentRect) instead of letting `contentsGravity = .resizeAspect`
    // stretch it into the view. That lets Dynamic mode place the frame pixel-exact:
    // the protocol's even-dimension rule means the delivered framebuffer can be 1px
    // smaller than the backing store, and a gravity-stretch of that mismatch linear-
    // resamples the whole image at ~1.0006x — softening every edge (the "blurry Auto"
    // bug). A <=1px letterbox is invisible; a whole-frame resample is not.
    private let contentLayer = CALayer()

    init(coordinator: RDPCanvasView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        wantsLayer = true
        // Render the framebuffer on the GPU: the image is handed to the layer as
        // `contents` and Core Animation scales/composites it, instead of CPU-scaling a
        // multi-megapixel image in draw(_:) on the main thread every frame.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.black.cgColor
        // The snapped content frame can exceed bounds by a subpixel (grid rounding) or
        // transiently during a re-resolution — never paint outside the canvas.
        layer?.masksToBounds = true
        contentLayer.contentsGravity = .resize      // fill the frame updateLayer computes
        // PERF-7: linear, not trilinear. Trilinear makes Core Animation regenerate a
        // full mipmap chain for the (multi-megapixel) texture on every contents change;
        // the canvas only ever downscales mildly (Fit mode), where linear is
        // indistinguishable and costs nothing per frame.
        contentLayer.minificationFilter = .linear
        contentLayer.magnificationFilter = .linear
        layer?.addSublayer(contentLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // Flipped = top-left origin, matching the RDP desktop's coordinate space and
    // giving natural top-anchored scrolling for 1:1 inside an NSScrollView.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // Match the layer's pixel density to the display so the image renders crisp.
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
            contentLayer.contentsScale = scale
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Moved to a display with a different backing scale (Retina <-> non-Retina): re-match
        // the layer density so the framebuffer stays crisp.
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
            contentLayer.contentsScale = scale
        }
        // The pixel-snap layout keys off contentsScale — re-run updateLayer() with it.
        needsDisplay = true
        // F-21: the cursor's bitmap reps are rendered per backing scale, so rebuild them
        // for the new display density. The cursor's SIZE is fit-derived and thus
        // display-independent (#26) — this only refreshes its pixel density.
        rebuildRemoteCursor()
        // The new display's density changes both the backing-pixel size and the DPI a
        // Dynamic session should render at — re-negotiate so the remote isn't left at
        // the old display's geometry (stale framebuffer + stale Windows scaling).
        if !inLiveResize { requestDynamicResize() }
    }

    /// Push the keyboard baseline once when the session first reaches `.connected`
    /// (focus-in may have fired before the session was ready). Resets on disconnect so a
    /// reconnect re-syncs.
    func syncBaselineIfNewlyConnected(state: ConnectionState) {
        if case .connected = state {
            guard !didBaselineForConnection else { return }
            didBaselineForConnection = true
            coordinator?.resyncKeyboardBaseline(capsLock: NSEvent.modifierFlags.contains(.capsLock),
                                                modifiers: NSEvent.modifierFlags)
        } else {
            didBaselineForConnection = false
        }
    }

    // Gaining first responder (focus-in) is the right time — and the ONLY time — to
    // push a keyboard synchronize event: it clears any modifiers the server thinks are
    // stuck and aligns Caps Lock, then re-asserts what's actually held now.
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            coordinator?.resyncKeyboardBaseline(capsLock: NSEvent.modifierFlags.contains(.capsLock),
                                                modifiers: NSEvent.modifierFlags)
        }
        return ok
    }

    // Releasing first responder (Cmd+Tab away, clicking toolbar/other UI) returns the
    // keyboard to macOS so system shortcuts aren't swallowed by the session.
    override func resignFirstResponder() -> Bool {
        coordinator?.inputCaptured = false
        // Release any held modifiers so they don't stick on the remote when focus leaves.
        coordinator?.syncModifiers(to: [])
        return super.resignFirstResponder()
    }

    // GPU path: AppKit calls updateLayer() (not draw(_:)) because wantsUpdateLayer is
    // true. We just assign the framebuffer as the layer's contents.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        contentLayer.contentsScale = layer.contentsScale
        contentLayer.magnificationFilter = magnificationFilterForCurrentScale()
        // Disable the implicit fade/resize animations CA would otherwise run on every
        // contents or frame change — those would smear motion and add latency.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // PERF-5: the IOSurface goes in directly. CA shares it with the render server
        // instead of copying a CGImage's pixels into its own backing on every commit.
        contentLayer.contents = currentFrame?.surface
        contentLayer.contentsRect = currentContentsRect(for: contentLayer)
        contentLayer.frame = displayedContentRect()
        CATransaction.commit()
        logSnapTransitionIfNeeded()
    }

    // Diagnostic breadcrumb for the Auto-blur work: logs only when Dynamic mode's
    // pixel-snap engages or disengages, with the numbers needed to see why. "snap=off"
    // while the window is idle means the delivered framebuffer doesn't match the
    // backing store — i.e. the blur is a genuine geometry mismatch, not filtering.
    private var lastLoggedSnapState: Bool?
    private func logSnapTransitionIfNeeded() {
        guard scaleMode == .dynamic, let frame = currentFrame else { return }
        let snapped = dynamicSnapRect() != nil
        guard snapped != lastLoggedSnapState else { return }
        lastLoggedSnapState = snapped
        let cs = layer?.contentsScale ?? 1
        NSLog("[geo] dynamic snap=%@ frame=%dx%d canvas=%.1fx%.1f px (scale %.0fx)",
              snapped ? "ON" : "off", frame.width, frame.height,
              bounds.width * cs, bounds.height * cs, cs)
    }

    /// #22: the layer's normalized [0,1] crop box. Whole frame (the identity rect —
    /// CALayer's default) unless a viewport is set, in which case the pure crop math
    /// lives in `MonitorLayout.contentsRect` (top-left-origin unit space) and is
    /// re-oriented for the layer's actual contents orientation: AppKit flips this
    /// view's backing layer (isFlipped canvas), where the unit-space origin is the
    /// image's top-left; an unflipped layer interprets it bottom-left-up.
    private func currentContentsRect(for layer: CALayer) -> CGRect {
        guard let vp = viewportRect, let frame = currentFrame,
              frame.width > 0, frame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let topLeft = MonitorLayout.contentsRect(
            viewport: vp, frameSize: CGSize(width: frame.width, height: frame.height))
        return layer.contentsAreFlipped()
            ? topLeft
            : MonitorLayout.verticallyFlippedUnitRect(topLeft)
    }

    /// #22: the pixel size of what this canvas actually shows — the viewport crop when
    /// set, else the whole framebuffer. All fit/scale math keys off this so the
    /// single-canvas modes are bit-identical to before (nil viewport == frame size).
    private var contentPixelSize: CGSize {
        if let vp = viewportRect { return vp.size }
        guard let frame = currentFrame else { return .zero }
        return CGSize(width: frame.width, height: frame.height)
    }

    /// Where the framebuffer is drawn, in view points (the content sublayer's frame).
    ///
    /// - **1:1**: one point per remote pixel at the origin (the scroll canvas is sized
    ///   to match, so this fills it).
    /// - **Fit** (and any viewport crop): aspect-fit into the view — same geometry the
    ///   old `contentsGravity = .resizeAspect` produced.
    /// - **Dynamic**: pixel-exact when the framebuffer matches the backing store within
    ///   the protocol's even-dimension tolerance — the frame is placed at its native
    ///   pixel size, centered on the backing grid, letterboxing the <=1px remainder
    ///   instead of resampling the whole image over it. Falls back to aspect-fit during
    ///   transients (live resize, re-negotiation lag) where the sizes genuinely differ.
    private func displayedContentRect() -> CGRect {
        let content = contentPixelSize
        guard content.width > 0, content.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        if viewportRect != nil { return aspectFit(content, in: bounds) }
        switch scaleMode {
        case .oneToOne:
            return CGRect(origin: .zero, size: content)
        case .fitToWindow:
            return aspectFit(content, in: bounds)
        case .dynamic:
            return dynamicSnapRect() ?? aspectFit(content, in: bounds)
        }
    }

    /// The pixel-exact placement for a Dynamic-mode frame, or nil when the framebuffer
    /// doesn't (yet) match the backing store. Matching tolerance is 2px per axis: the
    /// even-dimension floor costs at most 1px, plus <=0.5px of request rounding.
    private func dynamicSnapRect() -> CGRect? {
        let content = contentPixelSize
        guard content.width > 0, content.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let cs = layer?.contentsScale ?? window?.backingScaleFactor ?? 2
        guard cs > 0,
              abs(bounds.width * cs - content.width) <= 2,
              abs(bounds.height * cs - content.height) <= 2 else { return nil }
        let size = CGSize(width: content.width / cs, height: content.height / cs)
        // Center, rounded onto the backing-pixel grid so texels map 1:1 to pixels.
        let x = ((bounds.width - size.width) / 2 * cs).rounded() / cs
        let y = ((bounds.height - size.height) / 2 * cs).rounded() / cs
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Choose the layer's magnification filter.
    ///
    /// The Fit/1:1 framebuffer is rendered at the connection's logical resolution, so on
    /// a Retina display it is always *upscaled* to fill the backing store. A linear
    /// filter softens that upscale — the "blurry Fit" effect. So:
    /// - **1:1** always uses `.nearest` (crisp pixel doubling).
    /// - **Fit** uses `.nearest` *only* when the framebuffer lands on a (near-)integer
    ///   pixel scale, where nearest is exact and crisp; otherwise it falls back to
    ///   `.linear`, since nearest at a fractional scale produces uneven, shimmering pixels.
    /// - **Dynamic** uses `.nearest` when pixel-snapped (exact by construction, and any
    ///   residual subpixel offset stays crisp); `.linear` during stretch transients.
    private func magnificationFilterForCurrentScale() -> CALayerContentsFilter {
        switch scaleMode {
        case .oneToOne:
            return .nearest
        case .dynamic:
            return dynamicSnapRect() != nil ? .nearest : .linear
        case .fitToWindow:
            let content = contentPixelSize
            guard content.width > 0, content.height > 0,
                  bounds.width > 0, bounds.height > 0 else { return .linear }
            let contentsScale = layer?.contentsScale ?? window?.backingScaleFactor ?? 2
            // resizeAspect scales the image uniformly to fit the view bounds (points);
            // multiply by contentsScale to get the on-screen scale in backing pixels.
            let fit = min(bounds.width / content.width,
                          bounds.height / content.height)
            let pixelScale = fit * contentsScale
            let rounded = pixelScale.rounded()
            return (rounded >= 1 && abs(pixelScale - rounded) < 0.02) ? .nearest : .linear
        }
    }

    private func aspectFit(_ size: CGSize, in rect: NSRect) -> CGRect {
        guard size.width > 0 && size.height > 0 else { return rect }
        let wScale = rect.width / size.width
        let hScale = rect.height / size.height
        let scale = min(wScale, hScale)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: - Coordinate mapping

    /// Map a view point to remote pixel coordinates based on the currently displayed frame rect.
    private func remotePoint(from viewPoint: NSPoint) -> (x: Int, y: Int) {
        // #22: a viewport canvas is always aspect-fit (the layout is fixed at connect),
        // and its input maps into ITS monitor's remote rect: view point → viewport-
        // relative pixel → + viewport origin, clamped inside the viewport. Pure math in
        // MonitorLayout (ValidateCore-checked).
        if let vp = viewportRect {
            return MonitorLayout.remotePixel(viewPoint: CGPoint(x: viewPoint.x, y: viewPoint.y),
                                             viewSize: bounds.size, viewport: vp)
        }
        guard let frame = currentFrame else { return (0, 0) }
        // Same geometry the frame is rendered with (incl. the Dynamic pixel-snap), so
        // pointer coordinates always map into what's actually on screen.
        let displayRect = displayedContentRect()
        guard displayRect.width > 0 && displayRect.height > 0 else { return (0, 0) }
        // The view is flipped (top-left origin), so viewPoint is already top-left.
        let relX = (viewPoint.x - displayRect.minX) / displayRect.width
        let relY = (viewPoint.y - displayRect.minY) / displayRect.height
        let rx = Int(relX * CGFloat(frame.width))
        let ry = Int(relY * CGFloat(frame.height))
        return (max(0, min(rx, frame.width - 1)), max(0, min(ry, frame.height - 1)))
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        cancelPendingMove()
        // Clicking into the remote desktop captures the keyboard so typing "just
        // works" — matching standard RDP/VNC behavior. Release with Cmd+Esc, the
        // toolbar toggle, or by switching away from the window (see resignFirstResponder).
        // makeFirstResponder triggers becomeFirstResponder, which resyncs the keyboard
        // baseline (Caps Lock + a synchronize) once on focus-in — NOT on every click.
        window?.makeFirstResponder(self)
        coordinator?.inputCaptured = true
        // Assert the modifiers held at click time so Shift/Ctrl(Cmd)-click multi-select
        // reaches the remote. event.modifierFlags is authoritative for this instant.
        coordinator?.syncModifiers(to: event.modifierFlags)
        let pt = remotePoint(from: convert(event.locationInWindow, from: nil))
        coordinator?.controller.sendPointer(buttons: .left, x: pt.x, y: pt.y, down: true, moved: false)
    }

    override func mouseUp(with event: NSEvent) {
        cancelPendingMove()
        let pt = remotePoint(from: convert(event.locationInWindow, from: nil))
        coordinator?.controller.sendPointer(buttons: .left, x: pt.x, y: pt.y, down: false, moved: false)
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = remotePoint(from: convert(event.locationInWindow, from: nil))
        sendCoalescedMove(buttons: .left, x: pt.x, y: pt.y, down: true)
    }

    // PERF-3: coalesce move/drag events to ~125 Hz. AppKit can deliver pointer motion
    // faster than the display refresh (well past 120 Hz with some mice); each send takes
    // the bridge lock the RDP thread holds while processing a frame, so an unthrottled
    // stream both spams the wire and piles onto that contention. Sub-interval events
    // are stashed and flushed by a trailing timer so the final position is never lost.
    // Button downs/ups are NEVER coalesced (each carries its own authoritative point;
    // any stashed move is dropped because the click supersedes it).
    private var lastMoveSendTime: CFTimeInterval = 0
    private var pendingMove: (buttons: PointerButtons, x: Int, y: Int, down: Bool)?
    private var moveFlushScheduled = false
    private let moveSendInterval: CFTimeInterval = 1.0 / 125.0

    private func sendCoalescedMove(buttons: PointerButtons, x: Int, y: Int, down: Bool) {
        let now = CACurrentMediaTime()
        if now - lastMoveSendTime >= moveSendInterval {
            lastMoveSendTime = now
            pendingMove = nil
            coordinator?.controller.sendPointer(buttons: buttons, x: x, y: y,
                                                down: down, moved: true)
            return
        }
        pendingMove = (buttons, x, y, down)
        guard !moveFlushScheduled else { return }
        moveFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + moveSendInterval) { [weak self] in
            guard let self else { return }
            self.moveFlushScheduled = false
            guard let m = self.pendingMove else { return }
            self.pendingMove = nil
            self.lastMoveSendTime = CACurrentMediaTime()
            self.coordinator?.controller.sendPointer(buttons: m.buttons, x: m.x, y: m.y,
                                                     down: m.down, moved: true)
        }
    }

    /// A button event's own position supersedes any stashed motion — drop it so a stale
    /// move can never arrive after the click.
    private func cancelPendingMove() { pendingMove = nil }

    override func mouseMoved(with event: NSEvent) {
        let pt = remotePoint(from: convert(event.locationInWindow, from: nil))
        sendCoalescedMove(buttons: [], x: pt.x, y: pt.y, down: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPendingMove()
        coordinator?.syncModifiers(to: event.modifierFlags)
        let pt = remotePoint(from: convert(event.locationInWindow, from: nil))
        coordinator?.controller.sendPointer(buttons: .right, x: pt.x, y: pt.y, down: true, moved: false)
    }

    override func rightMouseUp(with event: NSEvent) {
        cancelPendingMove()
        let pt = remotePoint(from: convert(event.locationInWindow, from: nil))
        coordinator?.controller.sendPointer(buttons: .right, x: pt.x, y: pt.y, down: false, moved: false)
    }

    /// #24: AppKit routes motion-while-right-button-held here, NOT to mouseDragged/
    /// mouseMoved — without this override the server sees down…up with no path between,
    /// so right-drag gestures (drag-to-copy menus, mesh rotation, …) never happen.
    /// A pure MOVE event is sent: the server tracks the held button from rightMouseDown,
    /// and re-asserting BUTTON2|DOWN on every step would replay the press.
    override func rightMouseDragged(with event: NSEvent) {
        let pt = remotePoint(from: convert(event.locationInWindow, from: nil))
        sendCoalescedMove(buttons: [], x: pt.x, y: pt.y, down: false)
    }

    /// #24: same gap for middle/X-button drags (CAD orbiting lives on middle-drag).
    override func otherMouseDragged(with event: NSEvent) {
        let pt = remotePoint(from: convert(event.locationInWindow, from: nil))
        sendCoalescedMove(buttons: [], x: pt.x, y: pt.y, down: false)
    }

    override func otherMouseDown(with event: NSEvent) {
        cancelPendingMove()
        coordinator?.syncModifiers(to: event.modifierFlags)
        sendOtherButton(event, down: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        cancelPendingMove()
        sendOtherButton(event, down: false)
    }

    /// F-9: route non-left/right buttons by NSEvent.buttonNumber instead of collapsing
    /// them all to middle — 2 = middle (standard pointer event), 3/4 = X1/X2 back/forward
    /// (extended-mouse PDU). Buttons beyond 4 have no RDP encoding and are ignored.
    private func sendOtherButton(_ event: NSEvent, down: Bool) {
        let pt = remotePoint(from: convert(event.locationInWindow, from: nil))
        switch event.buttonNumber {
        case 2:
            coordinator?.controller.sendPointer(buttons: .middle, x: pt.x, y: pt.y,
                                                down: down, moved: false)
        case 3:
            coordinator?.controller.sendExtendedPointer(buttons: .back, x: pt.x, y: pt.y, down: down)
        case 4:
            coordinator?.controller.sendExtendedPointer(buttons: .forward, x: pt.x, y: pt.y, down: down)
        default:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Convert macOS scroll deltas into RDP wheel units, accumulating fractional
        // remainders so slow/precise scrolls aren't truncated to zero (the old bug).
        // `scrollingDelta*` already reflects the system "natural scrolling" setting and
        // carries momentum events, so trackpad momentum scroll flows through unchanged.
        let gain: CGFloat = event.hasPreciseScrollingDeltas
            ? 3.0     // trackpad / Magic Mouse: many small precise deltas per second
            : 30.0    // legacy notched wheel: few coarse line deltas — scale up per notch
        scrollAccumY += event.scrollingDeltaY * gain
        // #25: the horizontal axis needs a sign flip that the vertical axis doesn't.
        // AppKit's positive deltaX means "reveal content to the LEFT", while RDP's
        // PTR_FLAGS_HWHEEL positive rotation means "scroll RIGHT" (MS-RDPBCGR
        // 2.2.8.1.1.3.1.1.3) — the vertical conventions happen to agree (positive =
        // scroll up on both sides), so only X is negated.
        scrollAccumX -= event.scrollingDeltaX * gain
        emitAccumulatedWheel(&scrollAccumY, horizontal: false)
        emitAccumulatedWheel(&scrollAccumX, horizontal: true)
    }

    /// Emit the whole-unit part of an accumulated wheel delta, keeping the fractional
    /// remainder. Sends in ≤255-unit chunks so a fast flick isn't masked/wrapped by RDP's
    /// 9-bit wheel-rotation field.
    private func emitAccumulatedWheel(_ accum: inout CGFloat, horizontal: Bool) {
        let whole = accum < 0 ? accum.rounded(.up) : accum.rounded(.down)   // toward zero
        accum -= whole
        var units = Int(whole)
        guard units != 0 else { return }
        let maxStep = 255
        while units != 0 {
            let step = max(-maxStep, min(maxStep, units))
            coordinator?.controller.sendWheel(delta: step, horizontal: horizontal)
            units -= step
        }
    }

    /// Pinch-to-zoom: NSMagnificationGestureRecognizer reports cumulative magnification; we
    /// reset it each step and fire a Fit↔1:1 toggle once the pinch passes a threshold.
    @objc func handleMagnify(_ gr: NSMagnificationGestureRecognizer) {
        // POL-4: pinch-to-zoom is inert in multi-monitor mode.
        guard !multiMonitor else { return }
        switch gr.state {
        case .began:
            pinchAccum = 0
        case .changed:
            pinchAccum += gr.magnification
            gr.magnification = 0   // consume; track incremental change ourselves
            let threshold: CGFloat = 0.25
            if pinchAccum >= threshold {
                pinchAccum = 0
                coordinator?.onZoom?(true)   // pinch out → 1:1
            } else if pinchAccum <= -threshold {
                pinchAccum = 0
                coordinator?.onZoom?(false)  // pinch in → Fit
            }
        default:
            pinchAccum = 0
        }
    }

    // MARK: - Keyboard events

    override func keyDown(with event: NSEvent) {
        guard coordinator?.inputCaptured == true else {
            // Cmd+Escape toggles capture; otherwise let system handle
            if event.modifierFlags.contains(.command) && event.keyCode == 53 {
                coordinator?.inputCaptured = true
            } else {
                super.keyDown(with: event)
            }
            return
        }
        // Cmd+Escape = release capture
        if event.modifierFlags.contains(.command) && event.keyCode == 53 {
            coordinator?.inputCaptured = false
            return
        }
        let actions = coordinator?.keyboardMapper.actions(
            forKeyCode: event.keyCode,
            characters: event.characters,
            modifiers: UInt(event.modifierFlags.rawValue),
            keyDown: true
        ) ?? []
        coordinator?.handleKeyActions(actions)
    }

    override func keyUp(with event: NSEvent) {
        guard coordinator?.inputCaptured == true else { return }
        let actions = coordinator?.keyboardMapper.actions(
            forKeyCode: event.keyCode,
            characters: event.characters,
            modifiers: UInt(event.modifierFlags.rawValue),
            keyDown: false
        ) ?? []
        coordinator?.handleKeyActions(actions)
    }

    override func flagsChanged(with event: NSEvent) {
        guard coordinator?.inputCaptured == true else { return }
        // Caps Lock (keyCode 57) is a toggle on macOS, not a make/break key. Sending it
        // as a raw scancode would drift out of sync with the Mac's LED; instead push the
        // authoritative toggle state via the RDP synchronize event. The synchronize also
        // resets the server's modifiers, so re-assert any that are currently held.
        if event.keyCode == 57 {
            coordinator?.resyncKeyboardBaseline(capsLock: event.modifierFlags.contains(.capsLock),
                                                modifiers: event.modifierFlags)
            return
        }
        // Reconcile Shift/Ctrl/Alt/Cmd to the reported state (handles press AND release).
        coordinator?.syncModifiers(to: event.modifierFlags)
    }

    // Track mouse moves (requires window tracking area)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        // .cursorUpdate lets us own the pointer shape over this view; enter/exit tracks
        // whether the mouse is inside so we can apply async cursor updates immediately.
        let opts: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited,
                                            .cursorUpdate, .activeInKeyWindow, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: opts, owner: self))
    }

    // MARK: - Remote cursor

    /// Set the cursor the remote host wants. Called on the main actor by the controller's
    /// cursor sink. Applies immediately if the pointer is over the canvas; otherwise it's
    /// picked up by the next cursorUpdate(_:) when the pointer enters.
    func applyRemoteCursor(_ update: CursorUpdate) {
        lastCursorUpdate = update
        rebuildRemoteCursor()
    }

    /// (Re)build `remoteCursor` from `lastCursorUpdate` at the *current* backing scale. Called
    /// on every cursor update and whenever the backing scale changes (display move), so an
    /// image cursor always shows at the right physical size (#26).
    private func rebuildRemoteCursor() {
        switch lastCursorUpdate {
        case .arrow:
            remoteCursor = .arrow
        case .hidden:
            remoteCursor = Self.hiddenCursor
        case .image(let cg, let hot):
            // The cursor bitmap is in remote pixels — the SAME space as the framebuffer,
            // which is shown with resizeAspect in `bounds` (points). Scale the cursor by the
            // desktop's on-screen ratio (points per remote pixel), NOT the display's backing
            // scale: a standard RDP cursor is a fixed ~32 px bitmap regardless of resolution,
            // so dividing by the Retina scale made it render tiny. The fit ratio keeps the
            // cursor proportional to the content in every mode and constant when the window
            // moves between Retina and non-Retina displays (#26).
            let fit = desktopFitScale()
            let size = NSSize(width: CGFloat(cg.width) * fit, height: CGFloat(cg.height) * fit)
            // F-21: build the NSImage with explicit per-scale bitmap reps (see helper) so
            // NSCursor renders the full-resolution bitmap crisply on Retina, instead of the
            // single-rep image being rasterized at 1× point size and stretched. The SIZE in
            // points stays exactly cg.width × fit — the #26 sizing fix is untouched.
            let img = Self.cursorImage(cg, pointSize: size)
            remoteCursor = NSCursor(image: img,
                                    hotSpot: NSPoint(x: hot.x * fit, y: hot.y * fit))
        }
        if pointerInside { effectiveCursor.set() }
    }

    /// The cursor to actually apply. A remote shape is only meaningful while the session
    /// is live: the canvas stays in the hierarchy under the disconnect/reconnect overlay,
    /// and it still owns the pointer through its `.cursorUpdate` tracking area, so a
    /// stale remote "hidden" cursor would otherwise make the pointer invisible over the
    /// overlay's buttons. Belt-and-braces alongside the controller's reset on disconnect.
    private var effectiveCursor: NSCursor {
        guard let controller = coordinator?.controller else { return remoteCursor }
        if case .connected = controller.state { return remoteCursor }
        return .arrow
    }

    /// F-21: build the cursor NSImage so NSCursor renders the full-resolution bitmap
    /// crisply on Retina instead of upscaling a 1× rasterization.
    ///
    /// The rep is built directly from the source `CGImage`, so its pixel dimensions are
    /// the true remote-cursor resolution and its pixel data/format come straight from the
    /// bitmap. Setting the rep's *point* `size` below its pixel size makes it a high-DPI
    /// representation (more pixels than points) that NSCursor renders sharp.
    ///
    /// Do NOT hand-allocate an `NSBitmapImageRep` and draw into it: the obvious
    /// `samplesPerPixel: 4, hasAlpha: true` rep is non-premultiplied RGBA, a format
    /// CoreGraphics can't back a bitmap context with — `NSGraphicsContext(bitmapImageRep:)`
    /// then returns nil, the draw is skipped, and the rep keeps uninitialized memory,
    /// which shows up as a corrupted pointer.
    private static func cursorImage(_ cg: CGImage, pointSize: NSSize) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = pointSize                   // full-res pixels, point size ⇒ HiDPI rep
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    /// Points-per-remote-pixel: how the framebuffer is scaled on screen (resizeAspect of the
    /// remote-pixel image into the view `bounds`, in points). Display-independent, so the
    /// cursor stays the right size across Retina/non-Retina moves. Falls back to 1 before the
    /// first frame/bounds are known.
    private func desktopFitScale() -> CGFloat {
        // #22: viewport-aware — a per-display canvas fits ITS crop, not the whole
        // spanned frame (nil viewport == whole frame: identical to the pre-#22 math).
        let content = contentPixelSize
        guard content.width > 0, content.height > 0,
              bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / content.width, bounds.height / content.height)
    }

    override func cursorUpdate(with event: NSEvent) {
        effectiveCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        effectiveCursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The content sublayer's frame and filter both depend on `bounds`
        // (displayedContentRect), so every resize needs an updateLayer() pass — the
        // sublayer no longer auto-stretches with the view the way gravity-scaled
        // backing-layer contents did.
        needsDisplay = true
        // The cursor scale tracks the desktop fit ratio, which depends on `bounds` — rebuild
        // so it follows a Fit-mode window resize (Dynamic re-resolutions rebuild via the new
        // frame's size change) (#26).
        rebuildRemoteCursor()
        // Dynamic mode follows the window. Apply non-interactive size changes
        // immediately (initial connect layout, fullscreen, zoom) so the remote matches
        // the window automatically; during a live drag we defer to viewDidEndLiveResize
        // to avoid spamming monitor-layout updates.
        if scaleMode == .dynamic && !inLiveResize { requestDynamicResize() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        requestDynamicResize()
    }

    /// In Dynamic mode, ask the server to resize the remote desktop to match the
    /// current canvas. Resolution density follows the Retina toggle: backing pixels
    /// when on (matching the connect-time config), logical points when off. The
    /// Windows DPI is NOT sent (scalePercent 0 = keep the connect-time value): the
    /// connection's configured Zoom is pinned for the whole session, so display moves
    /// re-negotiate resolution only and can never flip the session's DPI (a
    /// DPI/sign-in mismatch makes Windows bitmap-rescale every frame — server-side
    /// blur no local rendering can undo). No-op for Fit/1:1.
    func requestDynamicResize() {
        // POL-4: don't drive window-follow resizes when spanning all displays.
        guard scaleMode == .dynamic, !multiMonitor, let coordinator else { return }
        let density: CGFloat = useHiDPI ? (window?.backingScaleFactor ?? 2) : 1
        // Round (not truncate): the request must land as close to the backing-store
        // pixel size as the protocol's even-dimension rule allows, so the frame can be
        // displayed pixel-exact (see displayedContentRect).
        let w = Int((bounds.width * density).rounded())
        let h = Int((bounds.height * density).rounded())
        if w > 1 && h > 1 {
            coordinator.controller.requestResize(width: w, height: h, scalePercent: 0)
        }
    }
}

// MARK: - State overlay components

struct ConnectionProgressOverlay: View {
    let message: String
    let detail: String
    let showSpinner: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 12) {
                if showSpinner {
                    if reduceMotion {
                        Image(systemName: "circle.dashed")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.5)
                            .tint(.white)
                    }
                }
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
        // POL-2: announce the progress state to VoiceOver as a single modal element.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .onAppear { announce("\(message) \(detail)") }
    }
}

struct ReconnectingOverlay: View {
    let attempt: Int
    let maxAttempts: Int
    /// The controller's actual delay for this attempt (per-connection policy floor
    /// applied — F-20), so the countdown matches reality (UX-4).
    let delaySeconds: Int
    let onCancel: () -> Void
    let reduceMotion: Bool
    @State private var countdown: Int = 0
    @State private var countdownTimer: Timer?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 16) {
                if reduceMotion {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)
                        .tint(.orange)
                }
                Text("Reconnecting…")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityLabel(accessibilityStatus)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityLabel("Cancel reconnection")
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        // UX-4: seed the countdown from the *same* backoff schedule the controller uses
        // (including the per-connection delay floor — F-20), so the number the user sees
        // matches the actual retry delay instead of a fixed 5.
        .onAppear {
            countdown = delaySeconds
            startCountdown()
        }
        // A new attempt re-seeds the countdown (onAppear only fires once for the
        // overlay's lifetime when attempts roll over in place).
        .onChange(of: attempt) {
            countdown = delaySeconds
            startCountdown()
        }
        // Reconnect success / cancel dismisses the overlay mid-countdown: without this
        // the 1 Hz timer keeps firing (and a re-shown overlay stacked a second one).
        .onDisappear {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    private var statusLine: String {
        countdown > 0
            ? "Attempt \(attempt) of \(maxAttempts) — retrying in \(countdown)s"
            : "Attempt \(attempt) of \(maxAttempts)"
    }

    private var accessibilityStatus: String {
        countdown > 0
            ? "Reconnect attempt \(attempt) of \(maxAttempts), retrying in \(countdown) seconds"
            : "Reconnect attempt \(attempt) of \(maxAttempts)"
    }

    private func startCountdown() {
        countdownTimer?.invalidate()   // never two timers on one countdown
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if countdown > 0 {
                countdown -= 1
            } else {
                timer.invalidate()
            }
        }
    }
}

struct FailedOverlay: View {
    let error: RDPError
    let reduceMotion: Bool
    let onAction: (RecoveryAction) -> Void

    /// Buttons to show: the cause-specific recovery actions, plus a universal Reconnect
    /// (skipped when Retry — the same effect — is already offered), Edit Connection…
    /// (F-3; skipped when the cause already offers it, or Update Saved Password… — which
    /// opens the same editor), and Close Tab. This guarantees *every* failure surfaces
    /// the full recovery set (no dead ends).
    private var buttons: [RecoveryAction] {
        var list = error.cause.recoveryActions
        if !list.contains(where: { $0.id == RecoveryAction.retry.id }) {
            list.append(.reconnect)
        }
        if !list.contains(where: { $0.id == RecoveryAction.editConnection.id }),
           !list.contains(where: { $0.id == RecoveryAction.updatePassword.id }) {
            list.append(.editConnection)
        }
        list.append(.closeTab)
        return list
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                Text("Connection Failed")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(error.humanMessage)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: 320)
                // UX-8: MFA can't be completed by retrying blindly — tell the user what to do.
                if error.cause == .mfaRequired {
                    Text("Complete the additional verification (e.g. an authenticator prompt) on the host, then retry. If sign-in keeps failing, edit the connection.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: 320)
                }
                HStack(spacing: 12) {
                    ForEach(buttons) { action in
                        recoveryButton(action, onAction: onAction)
                    }
                }
            }
            .padding(28)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .onAppear { announce("Connection failed. \(error.humanMessage)") }
    }
}

struct DisconnectedOverlay: View {
    let reason: String?
    let onAction: (RecoveryAction) -> Void

    // UX-3: a disconnected session used to be a dead end. Offer a universal recovery row.
    private let buttons: [RecoveryAction] = [.reconnect, .editConnection, .closeTab]

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 12) {
                Image(systemName: "display.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Disconnected")
                    .font(.headline)
                if let reason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    ForEach(buttons) { action in
                        recoveryButton(action, onAction: onAction, tintWhite: false)
                    }
                }
                .padding(.top, 4)
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .onAppear { announce("Disconnected. \(reason ?? "")") }
    }
}

// MARK: - Keyboard-capture HUD (UX-6)

/// A brief on-canvas pill shown when the keyboard is captured, so the user knows why
/// ⌘-shortcuts stopped reaching macOS and how to release. Non-interactive; auto-fades.
struct KeyboardCaptureHUD: View {
    let reduceMotion: Bool
    @State private var visible = true

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                Text("Keyboard captured — ⌘⎋ to release")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.primary)
            .padding(.bottom, 28)
            .opacity(visible ? 1 : 0)
            .accessibilityLabel("Keyboard captured. Press Command-Escape to release.")
        }
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            if reduceMotion {
                visible = false
            } else {
                withAnimation(.easeOut(duration: 0.4)) { visible = false }
            }
        }
    }
}

/// F-14: shown after "Log Off Remote Session…" sends Ctrl-Alt-Del. RDP offers no
/// client-initiated logoff PDU, so the honest affordance is opening the remote security
/// screen and pointing the user at its "Sign out" entry. Auto-dismisses after ~8 s.
struct SignOutHintHUD: View {
    let reduceMotion: Bool
    let onDismiss: () -> Void
    @State private var visible = true

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text("Choose “Sign out” on the remote screen to log off")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.primary)
            .padding(.bottom, 28)
            .opacity(visible ? 1 : 0)
            .accessibilityLabel("Choose Sign out on the remote security screen to log off.")
        }
        .allowsHitTesting(false)
        .onAppear { announce("Choose Sign out on the remote screen to log off.") }
        .task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            if reduceMotion {
                visible = false
            } else {
                withAnimation(.easeOut(duration: 0.4)) { visible = false }
            }
            onDismiss()
        }
    }
}

// MARK: - Screenshot toast (F-13)

/// Brief "Screenshot saved/copied" confirmation pill — same visual language as the
/// keyboard-capture HUD. Auto-fades after ~2 s, then clears the owning state.
/// F-8 reuses it (with a clipboard icon) for file-offer status/rejection notes.
struct ScreenshotToastHUD: View {
    let message: String
    var icon: String = "camera"
    let reduceMotion: Bool
    let onDismiss: () -> Void
    @State private var visible = true

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(message)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.primary)
            .padding(.bottom, 28)
            .opacity(visible ? 1 : 0)
            .accessibilityLabel(message)
        }
        .allowsHitTesting(false)
        .onAppear { announce(message) }
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if reduceMotion {
                visible = false
            } else {
                withAnimation(.easeOut(duration: 0.4)) { visible = false }
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}

// MARK: - Session shortcut cheat sheet (F-5)

/// Popover listing the in-session shortcuts, anchored to the "?" toolbar item. Every row
/// reflects a real binding in this file / the app menus — release capture is ⌘⎋ (see
/// `RDPNSView.keyDown`), pinch toggles Fit↔1:1, ⇧⌘W / ⌃⌘F live in the Connect menu items.
struct SessionCheatSheet: View {
    let modifierMode: ModifierMode
    let multiMonitor: Bool

    // Info.plist values come from Tools/Info.plist (copied in by Tools/build-app.sh);
    // a bare `swift run` binary has no bundle plist, hence the "dev" fallback.
    static var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let short else { return "TouchRDP (dev build)" }
        return build.map { "TouchRDP v\(short) (\($0))" } ?? "TouchRDP v\(short)"
    }

    private var rows: [(shortcut: String, what: String)] {
        var list: [(String, String)] = [
            ("Click desktop", "Capture the keyboard (all keys go to the remote)"),
            ("⌘⎋", "Release / re-capture the keyboard"),
            ("⇧⌘W", "Disconnect the session"),
            ("⌃⌘F", "Toggle full screen"),
            ("Two-finger tap", "Right-click on the remote"),
            ("Middle button", "Middle-click on the remote"),
            ("Side buttons", "Back / Forward (X1/X2) on the remote"),   // F-9
        ]
        // Pinch zoom is inert while spanning all displays (POL-4) — don't advertise it.
        if !multiMonitor {
            list.append(("Pinch out / in", "Switch to 1:1 / Fit scaling"))
        }
        list.append(modifierMode == .cmdAsCtrl
            ? ("⌘ key", "Acts as Ctrl on the remote (⌘C copies)")
            : ("⌘ key", "Sends the Windows key (use ⌃C to copy)"))
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session Shortcuts")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows, id: \.shortcut) { row in
                    GridRow {
                        Text(row.shortcut)
                            .fontWeight(.medium)
                            .gridColumnAlignment(.trailing)
                        Text(row.what)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            Text("Ctrl-Alt-Del, the Windows key, PrintScreen and more live in the toolbar's Send Keys menu (also Connection ▸ Send). Switching away from the window releases the keyboard automatically.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 300, alignment: .leading)
            Divider()
            Text(Self.versionLine)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .accessibilityLabel("Session shortcuts cheat sheet")
    }
}

// MARK: - Send Keys menu items (F-4)

/// The special-key entries shared by the session toolbar's "Send Keys" menu and the
/// Connection ▸ Send submenu (App.swift). Ctrl-Alt-Del keeps its dedicated bridge call;
/// everything else composes scancode sends from `SpecialKeySequence` (TouchRDPCore).
struct SendKeysMenuItems: View {
    let controller: SessionController

    var body: some View {
        Button("Ctrl-Alt-Del") { controller.sendCtrlAltDel() }
        Button("Windows Key") { controller.sendSpecialKeys(.windowsKey) }
        Button("Alt-Tab (switch app)") { controller.sendSpecialKeys(.altTab) }
        Divider()
        Button("PrintScreen") { controller.sendSpecialKeys(.printScreen) }
        Button("Alt-PrintScreen (active window)") { controller.sendSpecialKeys(.altPrintScreen) }
        Divider()
        Button("Win+L (lock remote)") { controller.sendSpecialKeys(.winL) }
        Button("Esc") { controller.sendSpecialKeys(.escape) }
        Button("Ctrl+Esc (Start menu)") { controller.sendSpecialKeys(.ctrlEscape) }
        Menu("Function Keys") {
            ForEach(1...12, id: \.self) { n in
                Button("F\(n)") { controller.sendFunctionKey(n) }
            }
        }
    }
}

// MARK: - Recovery button (shared overlay styling)

/// One recovery button, styled by `RecoveryAction.isPrimary` (prominent) and labelled
/// with its `systemImage`. `tintWhite` keeps borderless buttons legible on the darker
/// failed overlay; the lighter disconnected overlay uses the default tint.
@ViewBuilder
func recoveryButton(_ action: RecoveryAction,
                    onAction: @escaping (RecoveryAction) -> Void,
                    tintWhite: Bool = true) -> some View {
    let button = Button {
        onAction(action)
    } label: {
        Label(action.label, systemImage: action.systemImage)
    }
    .accessibilityLabel(action.label)

    if action.isPrimary {
        button.buttonStyle(.borderedProminent)
    } else if tintWhite {
        button.buttonStyle(.bordered).tint(.white)
    } else {
        button.buttonStyle(.bordered)
    }
}

// MARK: - VoiceOver announcement helper (POL-2)

/// Post a status announcement to VoiceOver. macOS routes `.announcementRequested` through
/// an accessibility element (the main window), unlike UIKit's global accessibility post.
func announce(_ message: String) {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    NSAccessibility.post(
        element: NSApp.mainWindow ?? NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
            .announcement: trimmed,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
}

// MARK: - Certificate review sheet (first-use, host mismatch, or changed)

struct CertReviewSheet: View {
    let review: SessionController.PendingCertReview
    let onTrust: () -> Void
    let onCancel: () -> Void

    // F-11: expandable technical details + old→new comparison for the `changed` case.
    // Purely informational — it feeds the SAME accept/reject decision and adds no
    // auto-accept path.
    @State private var showDetails = false
    @State private var fingerprintCopied = false

    private var certInfo: CertInfo { review.info }

    private var iconName: String {
        switch review.kind {
        case .firstUse: return "lock.shield"
        case .hostMismatch, .changed: return "exclamationmark.shield.fill"
        }
    }
    private var iconColor: Color {
        switch review.kind {
        case .firstUse: return .accentColor
        case .hostMismatch, .changed: return .orange
        }
    }
    private var title: String {
        switch review.kind {
        case .firstUse: return "Verify Certificate"
        case .hostMismatch: return "Certificate Name Mismatch"
        case .changed: return "Certificate Changed"
        }
    }
    private var explanation: String {
        switch review.kind {
        case .firstUse:
            return "This is the first connection to **\(certInfo.host)**. Confirm the fingerprint below matches the server you expect before trusting it."
        case .hostMismatch:
            return "The certificate presented by **\(certInfo.host)** does not match that host name. This can be normal for some servers, but it can also indicate interception. Verify the details before trusting."
        case .changed:
            return "The server certificate for **\(certInfo.host)** has changed since you last trusted it. This could indicate a security issue."
        }
    }
    private var trustLabel: String {
        review.kind == .firstUse ? "Trust & Connect" : "Trust This Certificate"
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundStyle(iconColor)

            Text(title)
                .font(.title2.bold())

            Text(.init(explanation))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 8) {
                if certInfo.hostMismatch {
                    Label("Host name mismatch", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Group {
                    LabeledContent("Common Name", value: certInfo.commonName)
                    LabeledContent("Issuer", value: certInfo.issuer)
                    LabeledContent("Fingerprint (SHA-256)", value: certInfo.fingerprintSHA256)
                        .font(.caption.monospaced())
                }

                Divider()

                // F-11: technical details expander (informs the decision; changes nothing
                // about the trust flow).
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    certDetails
                        .padding(.top, 6)
                }
                .font(.callout)
                .accessibilityLabel("Show certificate details")
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 460)

            HStack(spacing: 16) {
                Button(fingerprintCopied ? "Copied" : "Copy Fingerprint") {
                    // The fingerprint is a public value (never a secret) — the one
                    // cert datum that's allowed on the pasteboard.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(certInfo.fingerprintSHA256, forType: .string)
                    fingerprintCopied = true
                }
                .accessibilityLabel("Copy the SHA-256 fingerprint to the clipboard")

                Spacer().frame(width: 0)

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                    .accessibilityLabel("Cancel — do not trust this certificate")
                Button(trustLabel, action: onTrust)
                    .buttonStyle(.borderedProminent)
                    .tint(iconColor)
                    .accessibilityLabel("Trust this server certificate and connect")
            }
        }
        .padding(32)
        .frame(width: 520)
    }

    // MARK: F-11 detail expander

    /// Everything the bridge's verify callback actually provides: server endpoint, full
    /// subject and issuer DNs, and the SHA-256 fingerprint. FreeRDP's
    /// `VerifyCertificateEx` callback does NOT expose the raw certificate (DER), so
    /// validity dates, serial number, and SHA-1 are honestly unavailable — stated below
    /// rather than invented.
    @ViewBuilder
    private var certDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Server", "\(certInfo.host):\(certInfo.port)")
            detailRow("Subject", certInfo.subject.isEmpty ? "—" : certInfo.subject)
            detailRow("Issuer", certInfo.issuer.isEmpty ? "—" : certInfo.issuer)
            detailRow("SHA-256 fingerprint", certInfo.fingerprintSHA256, mono: true)

            if review.kind == .changed {
                Divider()
                changeComparison
            }

            Text("The RDP verification callback provides the subject, issuer, and SHA-256 fingerprint only; validity dates and serial number are not available for review.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Old→new diff against the PREVIOUSLY pinned record. The fingerprint always
    /// differs (that's what triggered the review); subject/issuer are compared when the
    /// old pin recorded them (pins written before F-11 stored only the fingerprint).
    @ViewBuilder
    private var changeComparison: some View {
        let previous = review.previousPin
        Text("Previously trusted certificate")
            .font(.caption.bold())
        if let previous {
            comparisonRow("Fingerprint",
                          old: previous.fingerprintSHA256,
                          new: certInfo.fingerprintSHA256, mono: true)
            if let oldSubject = previous.subject {
                comparisonRow("Subject", old: oldSubject, new: certInfo.subject)
            }
            if let oldIssuer = previous.issuer {
                comparisonRow("Issuer", old: oldIssuer, new: certInfo.issuer)
            }
            if let pinnedAt = previous.pinnedAt {
                detailRow("Trusted since", pinnedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if previous.subject == nil && previous.issuer == nil {
                Text("The earlier pin recorded only the fingerprint, so subject/issuer can't be compared.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("The previously pinned details are unavailable.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Stacked old→new pair; the pair is highlighted when the values differ.
    private func comparisonRow(_ label: String, old: String, new: String,
                               mono: Bool = false) -> some View {
        let differs = old != new
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if differs {
                    Text("changed")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
            }
            Text("Old: \(old)")
                .font(mono ? .caption.monospaced() : .caption)
                .foregroundStyle(differs ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("New: \(new)")
                .font(mono ? .caption.monospaced() : .caption)
                .foregroundStyle(differs ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Recovery actions (0c)

/// The concrete next steps an overlay can offer after a failed/disconnected session.
/// Replaces the old `RDPError.suggestedAction` shim (which routed through a dead
/// `NotificationCenter` post). `SessionView.perform(_:)` dispatches each case to the
/// controller (`retry`) or the ContentView-owned callbacks (`SessionActions`).
enum RecoveryAction: Identifiable {
    case retry, reconnect, reviewCertificate, editConnection, updatePassword, closeTab

    var id: String { label }

    var label: String {
        switch self {
        case .retry:             return "Retry"
        case .reconnect:         return "Reconnect"
        case .reviewCertificate: return "Review Certificate"
        case .editConnection:    return "Edit Connection…"
        case .updatePassword:    return "Update Saved Password…"
        case .closeTab:          return "Close Tab"
        }
    }

    var systemImage: String {
        switch self {
        case .retry:             return "arrow.clockwise"
        case .reconnect:         return "arrow.triangle.2.circlepath"
        case .reviewCertificate: return "lock.shield"
        case .editConnection:    return "pencil"
        case .updatePassword:    return "key"
        case .closeTab:          return "xmark"
        }
    }

    var isPrimary: Bool {
        switch self {
        case .retry, .reconnect, .reviewCertificate, .updatePassword: return true
        default: return false
        }
    }
}

extension RDPErrorCause {
    /// Cause-appropriate recovery actions. Exhaustive over every cause so a new cause
    /// forces a decision here rather than silently rendering no button.
    var recoveryActions: [RecoveryAction] {
        switch self {
        case .authenticationFailed:          return [.updatePassword]
        case .credentialsIncomplete:         return [.editConnection]
        case .credentialsUnavailable:        return [.updatePassword]
        case .certificateRejected:           return [.reviewCertificate]
        case .hostUnreachable, .dnsFailure:  return [.editConnection]
        case .timeout, .connectionFailed, .protocolError, .unknown: return [.retry]
        case .mfaRequired:                   return [.retry, .editConnection]
        case .sessionTakenOver, .sessionEndedByServer: return [.reconnect]
        case .cancelled:                     return []
        }
    }
}

extension SessionView {
    /// Dispatch a recovery action. `retry`/`reconnect` re-run the connect; #32:
    /// "Review Certificate" re-opens the sheet from the certificate the rejected
    /// handshake already captured, so it never depends on a fresh connect succeeding
    /// far enough to raise it again.
    func perform(_ action: RecoveryAction) {
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
