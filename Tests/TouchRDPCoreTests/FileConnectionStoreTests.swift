import XCTest
@testable import TouchRDPCore

/// Tests for FileConnectionStore CRUD/duplicate/move logic.
/// Every test uses an isolated temporary directory, never the user’s profiles.
final class FileConnectionStoreTests: XCTestCase {

    private var store: FileConnectionStore!

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TouchRDP-store-tests-\(UUID())")
        store = FileConnectionStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    func testFailedMutationsThrowAndKeepTheSavedSnapshot() throws {
        let a = makeConnection(name: "A")
        let b = makeConnection(name: "B")
        try store.add(a)
        try store.add(b)
        let saved = store.connections
        let file = directory.appendingPathComponent("connections.json")
        let backup = directory.appendingPathComponent("saved.json")
        let bytes = try Data(contentsOf: file)
        // A directory at the file path makes atomic writes fail deterministically,
        // including when the tests run with elevated privileges.
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var edited = a
        edited.name = "Edited"
        let imported = directory.appendingPathComponent("import.rdp")
        try Data("full address:s:example.test\nusername:s:test\n".utf8).write(to: imported)
        let changes: [() throws -> Void] = [
            { try self.store.add(self.makeConnection()) },
            { try self.store.update(edited) },
            { try self.store.delete(id: a.id) },
            { _ = try self.store.duplicate(id: a.id) },
            { try self.store.move(fromOffsets: [1], toOffset: 0) },
            { _ = try self.store.importRDPFile(at: imported) }
        ]
        for change in changes {
            XCTAssertThrowsError(try change()) { error in
                guard case StoreError.saveFailed = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(store.connections, saved)
            XCTAssertNotNil(store.lastError)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
        }
        // The caller can keep its edits and retry after resolving the disk problem.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        try store.update(edited)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(FileConnectionStore(directory: directory).connections.first?.name, "Edited")
    }

    private func makeConnection(name: String = "TestServer") -> Connection {
        Connection(name: name, host: "192.0.2.1", port: 3389, username: "testuser")
    }

    /// Remove a set of UUIDs from the store, cleaning up after a test.
    private func cleanup(ids: [UUID]) {
        for id in ids { try? store.delete(id: id) }
    }

    // MARK: - Add

    func testAddAppearsInConnections() throws {
        let c = makeConnection()
        try store.add(c)
        defer { cleanup(ids: [c.id]) }

        XCTAssertTrue(store.connections.contains(where: { $0.id == c.id }))
    }

    func testAddMultiple() throws {
        let c1 = makeConnection(name: "A")
        let c2 = makeConnection(name: "B")
        try store.add(c1)
        try store.add(c2)
        defer { cleanup(ids: [c1.id, c2.id]) }

        let ids = store.connections.map(\.id)
        XCTAssertTrue(ids.contains(c1.id))
        XCTAssertTrue(ids.contains(c2.id))
    }

    // MARK: - Update

    func testUpdateChangesName() throws {
        var c = makeConnection(name: "Original")
        try store.add(c)
        defer { cleanup(ids: [c.id]) }

        c.name = "Updated"
        try store.update(c)

        let found = store.connections.first(where: { $0.id == c.id })
        XCTAssertEqual(found?.name, "Updated")
    }

    func testUpdateNonExistentIsNoop() throws {
        let phantom = makeConnection(name: "Ghost")
        // Don't add; just update — should not crash or mutate store.
        let before = store.connections.count
        try store.update(phantom)
        XCTAssertEqual(store.connections.count, before)
    }

    // MARK: - Delete

    func testDeleteRemovesConnection() throws {
        let c = makeConnection()
        try store.add(c)
        try store.delete(id: c.id)
        XCTAssertFalse(store.connections.contains(where: { $0.id == c.id }))
    }

    func testDeleteNonExistentIsNoop() throws {
        let before = store.connections.count
        try store.delete(id: UUID())
        XCTAssertEqual(store.connections.count, before)
    }

    // MARK: - Duplicate

    func testDuplicateCreatesNewUUID() throws {
        let c = makeConnection(name: "Base")
        try store.add(c)

        let copy = try store.duplicate(id: c.id)
        defer { cleanup(ids: [c.id, copy!.id]) }

        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy!.id, c.id)
    }

    func testDuplicateNameHasCopySuffix() throws {
        let c = makeConnection(name: "Base")
        try store.add(c)

        let copy = try store.duplicate(id: c.id)
        defer { cleanup(ids: [c.id, copy!.id]) }

        XCTAssertEqual(copy?.name, "Base copy")
    }

    func testDuplicateAppearsInConnections() throws {
        let c = makeConnection(name: "Base")
        try store.add(c)

        let copy = try store.duplicate(id: c.id)!
        defer { cleanup(ids: [c.id, copy.id]) }

        XCTAssertTrue(store.connections.contains(where: { $0.id == copy.id }))
    }

    func testDuplicateNonExistentReturnsNil() throws {
        let result = try store.duplicate(id: UUID())
        XCTAssertNil(result)
    }

    // MARK: - Move

    func testMoveReordersConnections() throws {
        // Add three items and move the last one to position 0.
        let a = makeConnection(name: "A")
        let b = makeConnection(name: "B")
        let c = makeConnection(name: "C")
        try store.add(a); try store.add(b); try store.add(c)
        defer { cleanup(ids: [a.id, b.id, c.id]) }

        // Find current indices of our three items (store may have pre-existing ones).
        let before = store.connections
        let idxA = before.firstIndex(where: { $0.id == a.id })!
        let idxC = before.firstIndex(where: { $0.id == c.id })!

        // Move C to just before A.
        try store.move(fromOffsets: IndexSet([idxC]), toOffset: idxA)

        let after = store.connections
        let posA = after.firstIndex(where: { $0.id == a.id })!
        let posC = after.firstIndex(where: { $0.id == c.id })!
        XCTAssertLessThan(posC, posA, "C should appear before A after move")
    }
}
