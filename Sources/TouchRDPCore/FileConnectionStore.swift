import Foundation
import Combine
import os

// MARK: - FileConnectionStore

public final class FileConnectionStore: ObservableObject, ConnectionStore {

    @Published public private(set) var connections: [Connection] = []
    /// Last load/save problem, surfaced to the app layer (DATA-1) instead of silently
    /// resetting or swallowing.
    @Published public private(set) var lastError: StoreError?

    private let storeURL: URL
    private static let logger = Logger(subsystem: "com.touchrdp.app", category: "ConnectionStore")

    // DATA-2: versioned envelope with a legacy bare-array fallback.
    private struct ConnectionsFile: Codable {
        var schemaVersion: Int
        var connections: [Connection]
    }
    private static let currentSchemaVersion = 1

    public convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        self.init(directory: appSupport.appendingPathComponent("TouchRDP", isDirectory: true))
    }

    /// Test seam (DATA-1): store under an arbitrary directory so ValidateCore can exercise
    /// corrupt/legacy/envelope loads in a temp dir.
    public init(directory: URL) {
        storeURL = directory.appendingPathComponent("connections.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - ConnectionStore

    public func add(_ connection: Connection) throws {
        try commit(connections + [connection])
    }

    public func update(_ connection: Connection) throws {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        var updated = connections
        updated[idx] = connection
        try commit(updated)
    }

    public func delete(id: UUID) throws {
        try commit(connections.filter { $0.id != id })
    }

    @discardableResult
    public func duplicate(id: UUID) throws -> Connection? {
        guard let original = connections.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " copy"
        try add(copy)
        return copy
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) throws {
        var updated = connections
        // Replicate SwiftUI List move semantics without SwiftUI extensions.
        let items = fromOffsets.map { connections[$0] }
        // Remove in reverse order so earlier indices stay valid.
        for idx in fromOffsets.reversed() { updated.remove(at: idx) }
        // Adjust destination for elements that were removed below it.
        let adjustment = fromOffsets.filter { $0 < toOffset }.count
        let destination = max(0, min(toOffset - adjustment, updated.count))
        updated.insert(contentsOf: items, at: destination)
        try commit(updated)
    }

    public func importRDPFile(at url: URL) throws -> Connection {
        let connection = try RDPFileImporter.parse(url)
        try add(connection)
        return connection
    }

    public func exportConnections(to url: URL) throws {
        let data = try JSONEncoder().encode(connections)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch {
            // Unreadable (permissions/IO) — treat as empty; not a decode-corruption.
            connections = []
            return
        }
        // 1) Versioned envelope.
        if let file = try? JSONDecoder().decode(ConnectionsFile.self, from: data) {
            connections = migrate(file.connections, from: file.schemaVersion)
            if file.schemaVersion != Self.currentSchemaVersion { try? commit(connections) }  // error retained below
            return
        }
        // 2) Legacy bare array (schema 0) — migrate + rewrite as an envelope so existing
        //    files keep loading. This fallback is load-bearing.
        if let legacy = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = migrate(legacy, from: 0)
            try? commit(connections) // migration errors remain available as lastError
            return
        }
        // 3) Corrupt — back up the recoverable bytes before resetting to empty.
        let backup = backUpCorruptFile(data)
        connections = []
        lastError = .loadCorrupt(backupURL: backup)
        Self.logger.error("connection store corrupt; backed up to \(backup?.lastPathComponent ?? "<none>", privacy: .public)")
    }

    /// Schema migration ladder (DATA-2). No structural migrations exist yet; this is the
    /// hook for future schema bumps.
    private func migrate(_ items: [Connection], from version: Int) -> [Connection] {
        return items
    }

    private func commit(_ updated: [Connection]) throws {
        do {
            let file = ConnectionsFile(schemaVersion: Self.currentSchemaVersion, connections: updated)
            let data = try JSONEncoder().encode(file)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            let failure = StoreError.saveFailed(error.localizedDescription)
            lastError = failure
            Self.logger.error("connection store save failed: \(error.localizedDescription, privacy: .public)")
            throw failure
        }
        lastError = nil
        connections = updated
    }

    /// Copy the recoverable bytes to a timestamped sidecar so a corrupt file is never
    /// silently overwritten by the next `save()`.
    private func backUpCorruptFile(_ data: Data) -> URL? {
        let ts = Int(Date().timeIntervalSince1970)
        let backupURL = storeURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(ts)")
            .appendingPathExtension("json")
        do {
            try data.write(to: backupURL, options: .atomic)
            return backupURL
        } catch {
            return nil
        }
    }
}
