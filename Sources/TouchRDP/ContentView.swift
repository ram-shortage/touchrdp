import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TouchRDPCore
import TouchRDPEngine

struct ContentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var selectedConnectionID: UUID?
    @State private var sessions: [UUID: SessionController] = [:]
    @State private var activeTabID: UUID?
    // F-7: runtime display order of the session tabs (never persisted). All mutations go
    // through the pure SessionTabOrder helpers: new sessions append, closing keeps the
    // remaining order, drag-to-reorder moves only IDs. Reordering never touches the
    // `sessions` dictionary, so it can never recreate or disturb a SessionController.
    @State private var tabOrder: [UUID] = []
    // Drives the editor sheet via .sheet(item:) so SwiftUI keys the sheet to the
    // connection's identity — fixes stale/blank fields and the "opens a new
    // connection instead of editing" bug caused by .sheet(isPresented:) racing a
    // separate editingConnection state.
    @State private var editorContext: EditorContext?
    @State private var searchText = ""
    // Remember the last selected connection across launches so reopening the app lands
    // on it (and the default action is Connect) rather than the "add a connection" screen.
    @AppStorage("lastSelectedConnectionID") private var lastSelectedConnectionRaw = ""
    // Collapsed sidebar groups, persisted across launches as a JSON array of group keys.
    @AppStorage("collapsedSidebarGroups") private var collapsedGroupsRaw = ""
    // New-group prompt state (driven from the connection context menu).
    @State private var showNewGroupAlert = false
    @State private var newGroupName = ""
    @State private var groupingTarget: Connection?
    // Quick Connect (ad-hoc, unsaved host) sheet.
    @State private var showQuickConnect = false
    // F-1: .rdp import — open-panel trigger (File ▸ Import .rdp File…) + failure alert.
    @State private var showImportPanel = false
    @State private var importErrorMessage = ""
    @State private var showImportError = false
    @State private var passwordSaveErrorMessage = ""
    @State private var showPasswordSaveError = false
    // The app's main NSWindow, captured for per-connection geometry memory (#21).
    @State private var hostWindow: NSWindow?
    // F-16: sessions torn off into their own windows. The SessionController itself
    // stays in `sessions` (state ownership in exactly one place) — this set only marks
    // which IDs currently live in a detached window instead of the main tab strip.
    @State private var detachedIDs: Set<UUID> = []

    /// F-16: the AppKit-side manager for detached windows (windows only; no session state).
    private var windowManager: DetachedWindowManager { .shared }

    // Sentinel key for the unnamed ("Ungrouped") section in collapse persistence.
    private static let ungroupedKey = "\u{1}ungrouped"

    private var fileStore: FileConnectionStore? {
        coordinator.store as? FileConnectionStore
    }

    private var connections: [Connection] {
        fileStore?.connections ?? []
    }
    // #32: Quick Connect WITHOUT "save" runs a session for a connection that is not in
    // the store. The session pane and tab strip look the session's connection up by id,
    // so an unsaved one rendered a blank pane — no canvas, no failure overlay, no
    // certificate sheet. Kept here for the life of the session so both can find it.
    @State private var adHocConnections: [UUID: Connection] = [:]
    private var sessionConnections: [Connection] {
        adHocConnections.isEmpty ? connections : connections + Array(adHocConnections.values)
    }

    /// F-16: the sessions shown in THIS (main) window — everything not torn off. The
    /// tab strip, tab commands, and detail pane all work off this subset so a detached
    /// session can never reappear as a phantom tab (via `orderedTabIDs`' missing-ID
    /// fallback) while its window is open.
    private var mainSessions: [UUID: SessionController] {
        detachedIDs.isEmpty ? sessions : sessions.filter { !detachedIDs.contains($0.key) }
    }

    private var filteredConnections: [Connection] {
        guard !searchText.isEmpty else { return connections }
        return connections.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.host.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// A sidebar section. `id` is stable and never nil (the ungrouped bucket uses a
    /// sentinel) — a nil ForEach identity for that section made its rows unselectable once
    /// real groups coexisted.
    private struct SidebarGroup: Identifiable {
        let id: String
        let name: String?   // nil = the "Ungrouped" bucket
        let items: [Connection]
    }

    private var groupedConnections: [SidebarGroup] {
        let grouped = Dictionary(grouping: filteredConnections) { $0.groupName }
        let ungrouped = grouped[nil] ?? []
        let named = grouped
            .filter { $0.key != nil }
            .sorted { ($0.key ?? "").localizedCaseInsensitiveCompare($1.key ?? "") == .orderedAscending }
        var result: [SidebarGroup] = []
        if !ungrouped.isEmpty {
            result.append(SidebarGroup(id: Self.ungroupedKey, name: nil, items: ungrouped))
        }
        for (key, items) in named {
            result.append(SidebarGroup(id: key ?? Self.ungroupedKey, name: key, items: items))
        }
        return result
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
        }
        .sheet(item: $editorContext) { ctx in
            switch ctx {
            case .edit(let conn):
                ConnectionEditorView(connection: conn, isNew: false) { updated in
                    try coordinator.store.update(updated)
                }
                .environmentObject(coordinator)
            case .new:
                ConnectionEditorView(connection: Connection(name: "", host: "", username: ""), isNew: true) { newConn in
                    try coordinator.store.add(newConn)
                    selectedConnectionID = newConn.id
                }
                .environmentObject(coordinator)
            }
        }
        // Window toolbar — lives on the split view (not the detail) so the
        // Connect/Reconnect control stays visible even when the sidebar is collapsed.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: reconnectOrConnectCurrent) {
                    Label(currentHasSession ? "Reconnect" : "Connect",
                          systemImage: currentHasSession ? "arrow.clockwise" : "play.fill")
                }
                .disabled(currentConnection == nil)
                .help(reconnectButtonHelp)
                .accessibilityLabel(currentHasSession
                    ? "Reconnect the current session"
                    : "Connect to the selected connection")
            }
            // Session tabs live in the title bar (replacing the otherwise-empty window
            // title) to reclaim the vertical space a separate tab strip used to take.
            ToolbarItem(placement: .principal) {
                if !mainSessions.isEmpty {
                    SessionTabStrip(sessions: mainSessions, activeTabID: $activeTabID,
                                    tabOrder: $tabOrder,
                                    connections: sessionConnections, onClose: closeSession,
                                    onDetach: detachSession)   // F-16 tab context menu
                }
            }
        }
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectSheet { connection, password, save in
                quickConnect(connection, password: password, save: save)
            }
        }
        // F-1: publish the import action for File ▸ Import .rdp File… (see AppCommands),
        // and present the open panel + failure alert it drives.
        .focusedSceneValue(\.importRDPFiles, ImportRDPAction { showImportPanel = true })
        // F-7: publish tab-switching for the Window-menu commands (⌘⇧[ / ⌘⇧] / ⌘1–⌘9).
        // Equatable on `count`, so it republishes only as tabs open/close. F-16: counts
        // and cycles MAIN-window tabs only — detached sessions are not in the rotation.
        .focusedSceneValue(\.sessionTabs, SessionTabCommands(
            count: mainSessions.count,
            selectPrevious: { cycleTab(-1) },
            selectNext: { cycleTab(1) },
            select: selectTab(at:)))
        .fileImporter(isPresented: $showImportPanel,
                      allowedContentTypes: Self.rdpContentTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importRDPFiles(urls) }
        }
        .alert("Import Failed", isPresented: $showImportError) {
            Button("OK") {}
        } message: {
            Text(importErrorMessage)
        }
        .alert("Password Not Saved", isPresented: $showPasswordSaveError) {
            Button("OK") {}
        } message: {
            Text(passwordSaveErrorMessage)
        }
        .alert("Connection Changes Not Saved", isPresented: Binding(
            get: { coordinator.persistenceError != nil },
            set: { if !$0 { coordinator.persistenceError = nil } })) {
            Button("OK") { coordinator.persistenceError = nil }
        } message: {
            Text(coordinator.persistenceError ?? "")
        }
        // Capture the single app window for per-connection geometry memory.
        .background(WindowAccessor { window in configureWindow(window) })
        // Persist the active connection's window frame when the user resizes/moves it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
            if let w = note.object as? NSWindow, w === hostWindow { persistActiveWindowFrame() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { note in
            if let w = note.object as? NSWindow, w === hostWindow { persistActiveWindowFrame() }
        }
        .onAppear {
            if let error = fileStore?.lastError { coordinator.persistenceError = error.localizedDescription }
            restoreLastSelection()
            registerTearOffHandlers()   // F-16
        }
        // Persist the selection so the next launch restores it.
        .onChange(of: selectedConnectionID) { _, newValue in
            lastSelectedConnectionRaw = newValue?.uuidString ?? ""
        }
        // F-16: keep the Window-menu "Move Session to New Window" enablement honest.
        .onChange(of: activeTabID) { _, newValue in
            windowManager.canDetachActive = newValue != nil
        }
    }

    /// F-16: wire the tear-off menu commands and detached-window close events to the
    /// proven state-mutation paths owned here. The closures only touch ContentView's
    /// stable `@State` storage (same retained-closure pattern as `ImportRDPAction`).
    private func registerTearOffHandlers() {
        windowManager.onDetachActive = { detachActiveSession() }
        windowManager.onReattach = { reattachSession($0) }
        windowManager.onWindowClosed = { closeSession($0) }
        windowManager.canDetachActive = activeTabID != nil
        // #22: closing ANY per-display window closes the session — the same funnel.
        PerDisplayWindowPresenter.shared.onWindowClosed = { closeSession($0) }
    }

    /// On launch, select the connection used last time (if it still exists), falling back
    /// to the first available one — so the app opens ready to Connect rather than on the
    /// onboarding/"add a connection" screen. No-op once something is already selected.
    private func restoreLastSelection() {
        guard selectedConnectionID == nil, !connections.isEmpty else { return }
        if let id = UUID(uuidString: lastSelectedConnectionRaw),
           connections.contains(where: { $0.id == id }) {
            selectedConnectionID = id
        } else {
            selectedConnectionID = connections.first?.id
        }
    }

    // MARK: - Current connection (toolbar target)

    /// The connection the toolbar Connect/Reconnect button acts on: the active
    /// session's connection when one is showing, otherwise the sidebar selection.
    private var currentConnection: Connection? {
        if !mainSessions.isEmpty, let id = activeTabID,
           let conn = connections.first(where: { $0.id == id }) {
            return conn
        }
        if let id = selectedConnectionID,
           let conn = connections.first(where: { $0.id == id }) {
            return conn
        }
        return nil
    }

    private var currentHasSession: Bool {
        guard let conn = currentConnection else { return false }
        return sessions[conn.id] != nil
    }

    private var reconnectButtonHelp: String {
        guard let conn = currentConnection else { return "Select a connection to connect" }
        let name = conn.name.isEmpty ? conn.host : conn.name
        return currentHasSession ? "Reconnect \(name)" : "Connect to \(name)"
    }

    /// Identity-bearing editor context for `.sheet(item:)`.
    private enum EditorContext: Identifiable {
        case new
        case edit(Connection)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let c): return c.id.uuidString
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedConnectionID) {
                ForEach(groupedConnections) { group in
                    // A single all-ungrouped list stays a plain flat list (no header /
                    // disclosure); once named groups exist, every section — including the
                    // "Ungrouped" bucket — becomes a collapsible, labelled group.
                    if group.name == nil && !hasNamedGroups {
                        Section {
                            groupRows(group.items)
                        }
                    } else {
                        Section(isExpanded: expansionBinding(for: group.id)) {
                            groupRows(group.items)
                        } header: {
                            Text(group.name ?? "Ungrouped")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, prompt: "Search connections")
            .alert("New Group", isPresented: $showNewGroupAlert) {
                TextField("Group name", text: $newGroupName)
                Button("Cancel", role: .cancel) { groupingTarget = nil }
                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let conn = groupingTarget, !name.isEmpty { setGroup(name, for: conn) }
                    groupingTarget = nil
                }
            } message: {
                Text("Move this connection into a new group.")
            }

            Divider()

            VStack(spacing: 6) {
                Button(action: { editorContext = .new }) {
                    Label("Add Connection", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("Add Connection")
                .help("Add a new connection (⌘N)")

                Button(action: { showQuickConnect = true }) {
                    Label("Quick Connect", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel("Quick Connect to an ad-hoc host")
                .help("Connect to a host without saving it (⌘K)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 220)
        // F-1: drag .rdp files from Finder onto the sidebar to import them (same flow as
        // File ▸ Import .rdp File…). Non-.rdp drops are rejected so list reorder drags
        // and other payloads pass through untouched.
        .dropDestination(for: URL.self) { urls, _ in
            let rdpFiles = urls.filter { $0.pathExtension.lowercased() == "rdp" }
            guard !rdpFiles.isEmpty else { return false }
            importRDPFiles(rdpFiles)
            return true
        }
    }

    // MARK: - .rdp import (F-1)

    /// Accepted types for the import open panel. `.rdp` has no system-declared UTType,
    /// so this resolves the dynamic type for the extension.
    private static let rdpContentTypes: [UTType] = [UTType(filenameExtension: "rdp") ?? .data]

    /// Import each .rdp file into the connection store, then open the editor on the last
    /// imported connection for review before its first connect. Passwords never appear in
    /// .rdp files, so there is no vault interaction here. Parse failures are collected
    /// into one alert; successful files still import.
    private func importRDPFiles(_ urls: [URL]) {
        var lastImported: Connection?
        var failures: [String] = []
        for url in urls {
            // No-op when not sandboxed; required for security-scoped open-panel URLs.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let conn = try RDPFileImporter.parse(url)
                try coordinator.store.add(conn)
                lastImported = conn
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let conn = lastImported {
            selectedConnectionID = conn.id
            editorContext = .edit(conn)
        }
        if !failures.isEmpty {
            importErrorMessage = failures.joined(separator: "\n")
            showImportError = true
        }
    }

    /// Rows for one group, with drag-to-reorder wired to the flat store. Reordering is
    /// disabled while a search filter is active (the visible rows are a subset, so offsets
    /// wouldn't map cleanly).
    @ViewBuilder
    private func groupRows(_ items: [Connection]) -> some View {
        ForEach(items) { conn in
            ConnectionRow(
                connection: conn,
                hasPassword: coordinator.hasPassword(for: conn),
                isActive: sessions[conn.id] != nil
            )
            .tag(conn.id)
            .contentShape(Rectangle())   // make the whole row hit-testable
            // Handle selection explicitly: the List's native single-click selection is
            // unreliable once rows carry their own tap gestures and `.onMove`, so a
            // double-click connects/reconnects and a single click sets the selection
            // ourselves (the List still highlights the row whose tag matches).
            .onTapGesture(count: 2) { activateOrConnect(conn) }
            .onTapGesture(count: 1) { selectedConnectionID = conn.id }
            .contextMenu {
                connectionContextMenu(conn)
            }
        }
        .onMove { source, destination in
            guard searchText.isEmpty else { return }
            moveWithinGroup(items, source: source, destination: destination)
        }
    }

    // MARK: - Grouping helpers

    private var hasNamedGroups: Bool {
        connections.contains { $0.groupName != nil }
    }

    /// Existing group names (deduped, sorted) for the "Move to Group" menu.
    private var existingGroups: [String] {
        Set(connections.compactMap { $0.groupName }).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Persisted set of collapsed group keys (JSON-encoded in @AppStorage).
    private var collapsedGroups: Set<String> {
        get {
            guard let data = collapsedGroupsRaw.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(arr)
        }
        nonmutating set {
            let data = (try? JSONEncoder().encode(Array(newValue).sorted())) ?? Data()
            collapsedGroupsRaw = String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// Binding for a Section's expanded state, backed by the persisted collapsed set.
    private func expansionBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(key) },
            set: { expanded in
                var set = collapsedGroups
                if expanded { set.remove(key) } else { set.insert(key) }
                collapsedGroups = set
            }
        )
    }

    /// Translate a group-local move (offsets into `items`) into a move on the flat store
    /// array, preserving SwiftUI's pre-removal `toOffset` convention.
    private func moveWithinGroup(_ items: [Connection], source: IndexSet, destination: Int) {
        let globalSource = IndexSet(source.compactMap { local in
            connections.firstIndex(where: { $0.id == items[local].id })
        })
        guard !globalSource.isEmpty else { return }
        let globalDestination: Int
        if destination < items.count {
            globalDestination = connections.firstIndex(where: { $0.id == items[destination].id })
                ?? connections.count
        } else if let last = items.last,
                  let lastIdx = connections.firstIndex(where: { $0.id == last.id }) {
            globalDestination = lastIdx + 1
        } else {
            globalDestination = connections.count
        }
        performStoreChange {
            try coordinator.store.move(fromOffsets: globalSource, toOffset: globalDestination)
        }
    }

    /// Assign (or clear, with `nil`) a connection's group and persist it.
    private func setGroup(_ group: String?, for connection: Connection) {
        var updated = connection
        updated.groupName = group
        performStoreChange { try coordinator.store.update(updated) }
    }

    @discardableResult
    private func performStoreChange(_ change: () throws -> Void) -> Bool {
        do {
            try change()
            return true
        } catch {
            coordinator.persistenceError = error.localizedDescription
            return false
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if mainSessions.isEmpty {
            // Show detail or onboarding
            if let id = selectedConnectionID, let conn = connections.first(where: { $0.id == id }) {
                ConnectionDetailView(
                    connection: conn,
                    hasPassword: coordinator.hasPassword(for: conn),
                    onConnect: { startSession(for: conn) },
                    onEdit: { editorContext = .edit(conn) },
                    onDuplicate: { performStoreChange { try coordinator.store.duplicate(id: conn.id) } },
                    onDelete: { deleteConnection(conn) }
                )
                .environmentObject(coordinator)
            } else {
                OnboardingView(coordinator: coordinator) {
                    editorContext = .new
                }
            }
        } else {
            // Active session content; the tabs themselves live in the title bar.
            SessionTabView(
                sessions: mainSessions,
                activeTabID: $activeTabID,
                connections: sessionConnections,
                onCloseTab: { closeSession($0) },
                onEdit: { editorContext = .edit($0) }
            )
            .environmentObject(coordinator)
        }
    }

    // MARK: - Actions

    private func startSession(for connection: Connection) {
        // Saved/imported profiles can predate today's editor validation. If either half
        // of the credential pair is absent, open the editor immediately: do not create a
        // tab, probe the host, request Touch ID, or start FreeRDP.
        let usernameMissing = connection.username
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let passwordMissing = !coordinator.hasPassword(for: connection)
        guard !usernameMissing, !passwordMissing else {
            editorContext = .edit(connection)
            return
        }
        // F-16 (#7): if this connection already lives in a detached window, focus that
        // window instead of opening a duplicate (which would orphan the live controller).
        if detachedIDs.contains(connection.id) {
            windowManager.focusWindow(for: connection.id)
            return
        }
        let firstSession = mainSessions.isEmpty
        // Restore this connection's remembered window geometry before measuring the window
        // for Auto/Dynamic sizing, so the remote resolution matches the restored size.
        if firstSession { applySavedWindowFrame(for: connection.id) }
        let controller = coordinator.makeSessionController()
        sessions[connection.id] = controller
        // F-7: append at the end; a reconnect (id already present) keeps its slot.
        tabOrder = SessionTabOrder.appending(connection.id, to: tabOrder)
        activeTabID = connection.id
        // Auto/Dynamic mode uses the window's content size (points) + Retina scale to
        // pick a Retina-matched remote resolution; ignored by Fit/1:1.
        let (size, scale) = Self.windowLogicalSize()
        // Multi-monitor: span all attached displays as remote monitors when opted in.
        let monitors = connection.display.useAllDisplays
            ? Self.multiMonitorLayout(useHiDPI: connection.display.useHiDPI)
            : []
        coordinator.connect(connection, using: controller,
                            preferredLogicalSize: size, backingScale: scale,
                            monitors: monitors)
        // #22: opt-in per-display presentation — the presenter opens one window per
        // display when the session reaches .connected (and closes them on any drop).
        // Presentation only: same session, same spanned framebuffer. With a single
        // display attached (monitors == []), the session is ordinary single-monitor
        // and no presenter is involved.
        if connection.display.perDisplayWindows, monitors.count > 1 {
            PerDisplayWindowPresenter.shared.attach(
                sessionID: connection.id, controller: controller, connection: connection,
                coordinator: coordinator,
                actions: SessionActions(
                    closeTab: { closeSession(connection.id) },
                    editConnection: { editorContext = .edit(connection) }))
        }
    }

    /// Quick Connect: start an ad-hoc session from the inline-entered host/credentials.
    /// When `save` is set, also persist the profile + password for next time, but still
    /// connect with the typed password now (so there's no immediate second Touch ID prompt).
    private func quickConnect(_ connection: Connection, password: String, save: Bool) {
        let saved = save && performStoreChange { try coordinator.store.add(connection) }
        if saved {
            // A silent `try?` here once let a profile land in the sidebar as "Password:
            // Saved" with nothing usable behind it. Say so instead.
            do {
                try coordinator.storePassword(password, for: connection)
            } catch {
                passwordSaveErrorMessage = "\(connection.name) was added, but its password could not be saved to the Keychain (\(error)). Open Edit Connection… and enter it again."
                showPasswordSaveError = true
            }
            selectedConnectionID = connection.id
        } else {
            adHocConnections[connection.id] = connection   // #32: see sessionConnections
        }
        let firstSession = mainSessions.isEmpty
        if firstSession { applySavedWindowFrame(for: connection.id) }
        let controller = coordinator.makeSessionController()
        sessions[connection.id] = controller
        tabOrder = SessionTabOrder.appending(connection.id, to: tabOrder)   // F-7
        activeTabID = connection.id
        let (size, scale) = Self.windowLogicalSize()
        coordinator.connectAdHoc(connection, using: controller, password: password,
                                 preferredLogicalSize: size, backingScale: scale)
    }

    /// Close a session tab (used by the title-bar tab strip). F-7: the remaining tabs
    /// keep their order; if the closed tab was active, its right-hand neighbour (else
    /// the new last tab) becomes active. Selection is computed against the PRE-close
    /// order so neighbour semantics hold.
    private func closeSession(_ id: UUID) {
        adHocConnections.removeValue(forKey: id)   // #32: no-op for saved connections
        // #22: take down any per-display window group first (no-op otherwise; the
        // session teardown below is shared by every presentation).
        PerDisplayWindowPresenter.shared.detach(id)
        // F-16: a detached session closes with the SAME teardown as a main tab (this is
        // also where the detached window's red-button close funnels, via
        // DetachedWindowManager.onWindowClosed). Window down first (a no-op when the
        // window already closed itself), then disconnect+remove. It was never in
        // `tabOrder` while detached, so the main selection is untouched.
        if detachedIDs.contains(id) {
            windowManager.dismissWindow(for: id)
            detachedIDs.remove(id)
            sessions[id]?.disconnect()
            sessions.removeValue(forKey: id)
            return
        }
        let next = activeTabID == id
            ? SessionTabOrder.selectionAfterClosing(id, in: orderedTabIDs)
            : activeTabID
        sessions[id]?.disconnect()
        sessions.removeValue(forKey: id)
        tabOrder = SessionTabOrder.removing(id, from: tabOrder)
        activeTabID = next
    }

    // MARK: - Tear-off windows (F-16)

    /// Detach the main window's active tab into its own window (Window-menu command).
    private func detachActiveSession() {
        guard let id = activeTabID else { return }
        detachSession(id)
    }

    /// F-16: move a session into a dedicated secondary window. The SessionController
    /// MOVES — same instance, still owned by `sessions` — only the tab bookkeeping and
    /// the hosting window change. Selection falls back exactly as if the tab closed
    /// (pure logic in `SessionTabOrder.detaching`, ValidateCore-checked).
    private func detachSession(_ id: UUID) {
        // #22: a per-display session already lives in its own window group — tearing
        // its main-window placeholder off would put a second (spanned) canvas on the
        // same session. Not offered.
        guard !PerDisplayWindowPresenter.shared.isAttached(id) else { return }
        guard !detachedIDs.contains(id), let controller = sessions[id],
              let conn = connections.first(where: { $0.id == id }) else { return }
        let (order, active) = SessionTabOrder.detaching(id, from: orderedTabIDs,
                                                        active: activeTabID)
        tabOrder = order
        activeTabID = active
        detachedIDs.insert(id)
        windowManager.openWindow(
            for: id, controller: controller, connection: conn, coordinator: coordinator,
            actions: SessionActions(
                closeTab: { closeSession(id) },              // same teardown path
                editConnection: { editorContext = .edit(conn) }))
        windowManager.canDetachActive = activeTabID != nil
    }

    /// F-16: bring a torn-off session back — it re-enters the main tab order at the
    /// END (`SessionTabOrder.reattaching`) and becomes the active tab. The window goes
    /// away WITHOUT touching the session.
    private func reattachSession(_ id: UUID) {
        guard detachedIDs.contains(id) else { return }
        windowManager.dismissWindow(for: id)
        detachedIDs.remove(id)
        tabOrder = SessionTabOrder.reattaching(id, to: tabOrder)
        activeTabID = id
        hostWindow?.makeKeyAndOrderFront(nil)
        windowManager.canDetachActive = true
    }

    // MARK: - Tab order & switching (F-7)

    /// Tab IDs in strip order — MAIN-window sessions only (F-16: detached sessions are
    /// not in the strip or the ⌘1–9/⌘⇧[] rotation). Defensive: a main session somehow
    /// missing from `tabOrder` (shouldn't happen — every open path appends) is tacked on
    /// the end in the stable openSequence order (UX-7) rather than dropped.
    private var orderedTabIDs: [UUID] {
        let main = mainSessions
        let known = tabOrder.filter { main[$0] != nil }
        let missing = main
            .filter { !known.contains($0.key) }
            .sorted { $0.value.openSequence < $1.value.openSequence }
            .map(\.key)
        return known + missing
    }

    /// ⌘⇧[ / ⌘⇧]: move the active tab selection by `delta`, wrapping at the ends.
    private func cycleTab(_ delta: Int) {
        let ids = orderedTabIDs
        guard !ids.isEmpty else { return }
        guard let current = activeTabID, let idx = ids.firstIndex(of: current) else {
            activeTabID = ids.first
            return
        }
        activeTabID = ids[(idx + delta + ids.count) % ids.count]
    }

    /// ⌘1–⌘9: select the tab at a strip position (0-based); out of range is a no-op.
    private func selectTab(at index: Int) {
        let ids = orderedTabIDs
        guard ids.indices.contains(index) else { return }
        activeTabID = ids[index]
    }

    // MARK: - Window geometry memory (#21)

    private func configureWindow(_ window: NSWindow) {
        guard hostWindow !== window else { return }
        hostWindow = window
        // Restore the app window's size/position across launches (the no-session default).
        window.setFrameAutosaveName("TouchRDPMainWindow")
        // Reclaim the title bar's vertical space: the tab strip already sits in the
        // principal toolbar slot, so the window title row is a duplicate label above it.
        // Hiding the title stops AppKit reserving room to draw it, which is where the
        // saved row comes from. `.unified` — NOT `.unifiedCompact`: the compact row is
        // shorter than the window controls need, and the sidebar's `.searchable` field
        // draws in that same strip, so it collided with the traffic lights and the
        // rounded corner.
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        // Full screen: auto-hide the title/toolbar with the menu bar (delegate proxy —
        // SwiftUI owns this window's delegate).
        FullScreenToolbarAutoHider.install(on: window)
    }

    private func windowFrameKey(_ id: UUID) -> String { "windowFrame." + id.uuidString }

    /// Remember the active connection's window frame (only while a session is showing, so
    /// the per-connection memory reflects the session window the user actually sized).
    private func persistActiveWindowFrame() {
        guard let w = hostWindow, !mainSessions.isEmpty, let id = activeTabID else { return }
        let r = w.frame
        UserDefaults.standard.set([Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)],
                                  forKey: windowFrameKey(id))
    }

    /// Apply a connection's remembered window frame, if any (used when opening it into an
    /// empty window). Off-screen frames are left to AppKit's own constraining on display.
    private func applySavedWindowFrame(for id: UUID) {
        guard let w = hostWindow,
              let a = UserDefaults.standard.array(forKey: windowFrameKey(id)) as? [Double],
              a.count == 4, a[2] > 200, a[3] > 150 else { return }
        w.setFrame(CGRect(x: a[0], y: a[1], width: a[2], height: a[3]), display: true, animate: false)
    }

    /// Build a remote multi-monitor layout from the Mac's attached displays. The pure
    /// math (Y-flip to top-left pixel space, non-negative-origin normalization, single
    /// uniform scale) lives in `MonitorLayout.makeMonitors` (TouchRDPCore) — moved
    /// there verbatim for #22 so the per-display viewport mapping is consistent with
    /// the declaration BY CONSTRUCTION and both are ValidateCore-checked. Returns []
    /// for a single display (caller falls back to the normal single-monitor path).
    private static func multiMonitorLayout(useHiDPI: Bool) -> [MonitorDef] {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return [] }
        let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens[0]
        let scale: CGFloat = useHiDPI ? primary.backingScaleFactor : 1
        return MonitorLayout.makeMonitors(screenFramesPoints: screens.map(\.frame),
                                          scale: scale)
    }

    /// The app window's content size in points and its Retina backing scale, falling
    /// back to the main screen, then a sane default.
    private static func windowLogicalSize() -> (CGSize?, CGFloat) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let points = window?.contentLayoutRect.size ?? NSScreen.main?.visibleFrame.size
        guard let points, points.width > 1, points.height > 1 else { return (nil, scale) }
        return (points, scale)
    }

    private func deleteConnection(_ connection: Connection) {
        // Keep the profile, its active session and its secrets intact if disk
        // persistence fails; a later restart must not resurrect a half-deletion.
        guard performStoreChange({ try coordinator.store.delete(id: connection.id) }) else { return }
        // Disconnect the active session, if any (also fixes tab order/selection — F-7).
        if sessions[connection.id] != nil { closeSession(connection.id) }
        if selectedConnectionID == connection.id {
            selectedConnectionID = nil
        }
        // Best-effort cleanup
        try? coordinator.forgetPassword(for: connection)
    }

    @ViewBuilder
    private func connectionContextMenu(_ conn: Connection) -> some View {
        if sessions[conn.id] != nil {
            Button("Disconnect") { disconnectSession(for: conn) }
            Button("Reconnect") { reconnectSession(for: conn) }
        } else {
            Button("Connect") { startSession(for: conn) }
        }
        Button("Edit…") { editorContext = .edit(conn) }
        Button("Duplicate") { performStoreChange { try coordinator.store.duplicate(id: conn.id) } }
        Menu("Move to Group") {
            ForEach(existingGroups.filter { $0 != conn.groupName }, id: \.self) { g in
                Button(g) { setGroup(g, for: conn) }
            }
            if existingGroups.contains(where: { $0 != conn.groupName }) { Divider() }
            Button("New Group…") {
                groupingTarget = conn
                newGroupName = ""
                showNewGroupAlert = true
            }
            if conn.groupName != nil {
                Divider()
                Button("Remove from Group") { setGroup(nil, for: conn) }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { deleteConnection(conn) }
    }

    /// Tear down an active session for a connection (from the context menu) without
    /// deleting the connection itself. Same semantics as closing its tab (F-7).
    private func disconnectSession(for connection: Connection) {
        closeSession(connection.id)
    }

    /// Drop the current session and immediately start a fresh one (new Touch-ID-gated
    /// connect). Useful after a network change or to recover a wedged session.
    /// F-16: a DETACHED session instead retries in place (`controller.retry()`, the same
    /// path its own recovery overlays use) — recreating the controller would strand the
    /// detached window on a dead instance.
    private func reconnectSession(for connection: Connection) {
        if detachedIDs.contains(connection.id) {
            windowManager.focusWindow(for: connection.id)
            sessions[connection.id]?.retry()
            return
        }
        // #22: drop any per-display window group with the old controller; startSession
        // re-attaches a fresh one for per-display connections.
        PerDisplayWindowPresenter.shared.detach(connection.id)
        sessions[connection.id]?.disconnect()
        sessions.removeValue(forKey: connection.id)
        startSession(for: connection)
    }

    /// Toolbar button: reconnect the current session if there is one, otherwise
    /// connect to the selected connection.
    private func reconnectOrConnectCurrent() {
        guard let conn = currentConnection else { return }
        if sessions[conn.id] != nil {
            reconnectSession(for: conn)
        } else {
            startSession(for: conn)
        }
    }

    /// Sidebar double-click: connect when there's no session, reconnect a dead
    /// one (idle/failed/disconnected), or just bring a live session's tab to front.
    private func activateOrConnect(_ connection: Connection) {
        selectedConnectionID = connection.id
        if let controller = sessions[connection.id] {
            // F-16 (#7): a session living in a detached window is focused there instead
            // of opening a duplicate; a dead one retries in place (same as its overlay).
            if detachedIDs.contains(connection.id) {
                windowManager.focusWindow(for: connection.id)
                if !controller.state.isActive { controller.retry() }
            } else if controller.state.isActive {
                activeTabID = connection.id
            } else {
                reconnectSession(for: connection)
            }
        } else {
            startSession(for: connection)
        }
    }
}

// MARK: - Connection row

struct ConnectionRow: View {
    let connection: Connection
    let hasPassword: Bool
    let isActive: Bool

    private var lastConnectedLabel: String {
        guard let date = connection.lastConnected else { return "Never connected" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(connection.name.isEmpty ? connection.host : connection.name)
                        .fontWeight(.medium)
                    if isActive {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Active session")
                    }
                }
                Text(connection.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(lastConnectedLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if hasPassword {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Password saved")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Connection detail

struct ConnectionDetailView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let connection: Connection
    let hasPassword: Bool
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "display")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(connection.name.isEmpty ? connection.host : connection.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                // verbatim: a LocalizedStringKey would format the Int port as "3,389".
                Text(verbatim: "\(connection.host):\(connection.port)")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                if !connection.username.isEmpty {
                    DetailRow(label: "User", value: connection.username)
                }
                DetailRow(label: "Security", value: connection.security.displayLabel)
                DetailRow(label: "Display", value: "\(connection.display.width)×\(connection.display.height)")
                DetailRow(label: "Password", value: hasPassword ? "Saved (\(coordinator.vaultTierLabel))" : "Not saved")
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)

            Button(action: onConnect) {
                Label("Connect", systemImage: "play.fill")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Connect to \(connection.name)")

            HStack(spacing: 16) {
                Button("Edit…", action: onEdit)
                Button("Duplicate", action: onDuplicate)
                Button("Delete", role: .destructive, action: onDelete)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .fontWeight(.medium)
        }
        .font(.callout)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    let coordinator: AppCoordinator
    let onAddConnection: () -> Void

    private var biometricCopy: String {
        let cap = coordinator.biometricCapability
        if cap.available {
            switch cap.type {
            case .touchID: return "Passwords are protected by Touch ID."
            case .faceID: return "Passwords are protected by Face ID."
            case .none: return "Passwords are protected by your login password."
            }
        } else {
            return "Passwords are secured with your Mac password."
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Add your first PC")
                .font(.title)
                .fontWeight(.semibold)
            Text("Connect to Windows PCs and servers using Remote Desktop.\n\(biometricCopy)")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Text("Protected by \(coordinator.vaultTierLabel)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button(action: onAddConnection) {
                Label("Add Connection", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Add your first connection")

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Session tab container

struct SessionTabView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let sessions: [UUID: SessionController]
    @Binding var activeTabID: UUID?
    let connections: [Connection]
    // 0b: ContentView-owned recovery callbacks, forwarded to the active SessionView so its
    // overlays can close the tab / open the editor via the proven paths.
    let onCloseTab: (UUID) -> Void
    let onEdit: (Connection) -> Void
    // #22: observed so the pane swaps between placeholder and canvas when a session's
    // per-display presentation attaches, falls back, or ends.
    @ObservedObject private var perDisplayPresenter = PerDisplayWindowPresenter.shared

    var body: some View {
        // The tab strip itself lives in the window title bar (SessionTabStrip); here we
        // just render the active session's content, full-height.
        if let id = activeTabID, let controller = sessions[id],
           let conn = connections.first(where: { $0.id == id }) {
            let actions = SessionActions(
                closeTab: { onCloseTab(id) },
                editConnection: { onEdit(conn) })
            // #22: a per-display session's canvases live in the presenter's windows —
            // the main pane shows a placeholder (plus the connect/recovery overlays)
            // instead of a second canvas. Fallback (screen mismatch) or a normal
            // session renders the proven single canvas.
            if perDisplayPresenter.isPresenting(id) {
                PerDisplaySessionPlaceholderView(controller: controller,
                                                 connection: conn, actions: actions)
                    .id(id)
                    .focusedValue(\.activeSession, controller)
            } else {
                SessionView(controller: controller, connection: conn, actions: actions)
                    .id(id)
                    .focusedValue(\.activeSession, controller)
            }
        } else {
            Color(nsColor: .underPageBackgroundColor)
        }
    }
}

/// Horizontal strip of session tabs, hosted in the window title bar.
struct SessionTabStrip: View {
    let sessions: [UUID: SessionController]
    @Binding var activeTabID: UUID?
    // F-7: runtime display order owned by ContentView (never persisted). Drag-to-reorder
    // mutates ONLY this ID array — the SessionController dictionary is untouched, so a
    // reorder can never recreate or disturb a live session.
    @Binding var tabOrder: [UUID]
    let connections: [Connection]
    let onClose: (UUID) -> Void
    // F-16: tear the tab off into its own window (context-menu action).
    let onDetach: (UUID) -> Void
    // The tab currently being dragged; drives the drop delegate's live reordering.
    @State private var draggingTabID: UUID?

    // F-7: tabs follow the reorderable tabOrder array. Any session not yet in it
    // (shouldn't happen — ContentView appends on every open path) falls back to the
    // stable openSequence order (UX-7) at the end, rather than being dropped.
    private var orderedSessions: [(UUID, SessionController)] {
        let known = tabOrder.compactMap { id in sessions[id].map { (id, $0) } }
        let missing = sessions
            .filter { !tabOrder.contains($0.key) }
            .sorted { $0.value.openSequence < $1.value.openSequence }
            .map { ($0.key, $0.value) }
        return known + missing
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(orderedSessions, id: \.0) { id, controller in
                    SessionTab(
                        connection: connections.first(where: { $0.id == id }),
                        controller: controller,
                        isActive: activeTabID == id,
                        onSelect: { activeTabID = id },
                        onClose: { onClose(id) }
                    )
                    // F-7: drag-to-reorder. The payload is only used as a drag token —
                    // the live reorder happens in the drop delegate as the dragged tab
                    // passes over its siblings.
                    .onDrag {
                        draggingTabID = id
                        return NSItemProvider(object: id.uuidString as NSString)
                    }
                    .onDrop(of: [.plainText],
                            delegate: TabReorderDropDelegate(item: id,
                                                             tabOrder: $tabOrder,
                                                             dragging: $draggingTabID))
                    // F-16: tear-off via the tab's context menu (a literal drag-out-of-
                    // strip gesture is deliberately NOT implemented — SwiftUI has no
                    // reliable "dropped outside every target" signal).
                    .contextMenu {
                        Button("Move Session to New Window") { onDetach(id) }
                            .disabled(!connections.contains(where: { $0.id == id }))
                    }
                }
            }
        }
        // Same metric as the chips themselves: the strip must not stretch them to the
        // scroll view's height, or they grow taller than the rest of the toolbar again.
        .frame(maxWidth: 540, maxHeight: SessionTab.toolbarControlHeight)
    }
}

/// F-7: live drag-to-reorder for the title-bar tab strip. As the dragged tab enters
/// another tab, the dragged ID takes that tab's slot (pure logic in
/// `SessionTabOrder.moving`, validated headlessly). Only the runtime ID array moves.
private struct TabReorderDropDelegate: DropDelegate {
    let item: UUID
    @Binding var tabOrder: [UUID]
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragged = dragging, dragged != item else { return }
        tabOrder = SessionTabOrder.moving(dragged, toSlotOf: item, in: tabOrder)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct SessionTab: View {
    let connection: Connection?
    @ObservedObject var controller: SessionController
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    /// The height every tab chip draws at, matching the bordered controls AppKit puts in
    /// a `.unified` toolbar row. One constant so the strip and the chips cannot disagree.
    static let toolbarControlHeight: CGFloat = 24

    private var label: String {
        connection.map { $0.name.isEmpty ? $0.host : $0.name } ?? "Session"
    }

    private var statusColor: Color {
        switch controller.state {
        case .connected: return .green
        case .failed: return .red
        case .reconnecting: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        // F-7: a plain tappable container, NOT an outer Button — a Button swallows the
        // mouse-down that `.onDrag` needs to start a reorder drag (same gesture conflict
        // as the sidebar rows). The inner close Button still wins its own hits.
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(label)
                .lineLimit(1)
                .frame(maxWidth: 140)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(label) tab")
        }
        .padding(.horizontal, 12)
        // Height comes from the shared toolbar metric, NOT from vertical padding: padding
        // sized the chip from its own content (dot, text, close button), which made it
        // stand taller than the buttons and the segmented picker sitting beside it in the
        // same toolbar row.
        .frame(height: Self.toolbarControlHeight)
        .background(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                    in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(label) session tab")
    }
}

// MARK: - Window accessor (captures the NSWindow for geometry memory)

/// A zero-size representable whose only job is to hand the enclosing `NSWindow` back to
/// SwiftUI once it's attached, so we can drive per-connection window geometry (#21).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in if let w = v?.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in if let w = nsView?.window { onWindow(w) } }
    }
}

// MARK: - Quick Connect (ad-hoc host)

/// Connect to a host without first saving a profile. Reuses the inline-password
/// connect path; optionally saves the profile + password for next time.
struct QuickConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hostField = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var saveProfile = false
    /// (connection, password, saveProfile)
    let onConnect: (Connection, String, Bool) -> Void

    /// Parse `host` or `host:port` (defaulting to 3389). nil = not yet valid.
    private var parsed: (host: String, port: Int)? {
        let trimmed = hostField.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let colon = trimmed.lastIndex(of: ":") {
            let portStr = trimmed[trimmed.index(after: colon)...]
            guard let port = Int(portStr), port > 0, port <= 65535 else { return nil }
            let host = String(trimmed[..<colon])
            guard !host.isEmpty else { return nil }
            return (host, port)
        }
        return (trimmed, 3389)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quick Connect")
                .font(.headline)
                .padding([.top, .horizontal])
            Form {
                TextField("Host", text: $hostField, prompt: Text("hostname or hostname:port"))
                    .accessibilityLabel("Host name, optionally with port")
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                TextField("Domain (optional)", text: $domain)
                Toggle("Save to my connections", isOn: $saveProfile)
                    .help("Also store this host and password for next time")
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    // Quick Connect always uses NLA, which cannot sign in with an empty
                    // password — and with "Save" on, an empty one used to be persisted
                    // as a profile that could never connect.
                    .disabled(parsed == nil || username.isEmpty || password.isEmpty)
                    .help(password.isEmpty ? "Enter the account password to connect"
                                           : "Connect to \(parsed?.host ?? "the host")")
            }
            .padding([.bottom, .horizontal])
        }
        .frame(width: 420)
    }

    private func connect() {
        guard let p = parsed else { return }
        let conn = Connection(name: p.host, host: p.host, port: p.port,
                              username: username, domain: domain.isEmpty ? nil : domain)
        onConnect(conn, password, saveProfile)
        dismiss()
    }
}

// MARK: - RDPSecurity display label

extension RDPSecurity {
    var displayLabel: String {
        switch self {
        case .nla: return "NLA (recommended)"
        case .tls: return "TLS"
        case .rdpLegacy: return "RDP Legacy"
        }
    }
}
