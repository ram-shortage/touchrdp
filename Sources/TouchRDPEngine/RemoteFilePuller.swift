import Foundation
import TouchRDPCore

/// #25 (remote→Mac file paste): the transfer engine behind the local file promises.
///
/// When the server announces "FileGroupDescriptorW", SessionView puts one
/// `NSFilePromiseProvider` per file on the local pasteboard. Nothing is transferred at
/// that point. When the user pastes/drops in Finder, AppKit asks the promise to write
/// its file to a destination URL — the promise bridges into this actor, which pulls the
/// bytes over cliprdr (FILECONTENTS_SIZE when the descriptor omitted the size, then
/// sequential 4 MiB FILECONTENTS_RANGE requests) and writes them to the destination.
/// This is how Microsoft's own macOS RDP client does it — no FUSE filesystem needed.
///
/// Threading: this is an ACTOR. Promise callbacks arrive on the promise
/// OperationQueue; they hop in via `Task { await pull(…) }`. While a pull awaits a
/// chunk (a `CheckedContinuation` keyed by streamId), the actor is free, so
/// `handleResponse` — forwarded nonisolated straight off the RDP thread — can resume
/// it. File writes happen inside the actor between awaits (a background cooperative
/// thread, never the main thread; at most one 4 MiB write between chunks).
///
/// Transfers are strictly SERIAL (`beginTransfer`/`endTransfer` FIFO): cliprdr is a
/// single channel, and one outstanding FILECONTENTS request at a time keeps the
/// request/response matching trivial and the remote unstressed.
///
/// Caps (SEC-3 spirit, server side of the wire is hostile until proven otherwise):
/// 4 MiB chunks, 256 MiB per file, 1 GiB total per clipboard generation, 30 s per
/// request. A violated cap or a stale generation fails the PROMISE with a clear error
/// — never a crash, never a partial file left behind (the caller deletes on failure).
public actor RemoteFilePuller {
    public static let chunkBytes: UInt32 = 4 * 1024 * 1024
    public static let maxFileBytes: UInt64 = 256 * 1024 * 1024
    public static let maxTotalBytesPerGeneration: UInt64 = 1024 * 1024 * 1024
    public static let requestTimeoutSeconds: UInt64 = 30

    public enum PullError: LocalizedError {
        case notActive          // no live announcement (disconnected or superseded)
        case staleGeneration    // the remote copied something new; this promise is dead
        case sendFailed         // channel down / request refused by the bridge
        case remoteFailed       // server FAILed a FILECONTENTS request
        case timedOut           // no response within 30 s
        case fileTooLarge       // > 256 MiB per file
        case totalCapExceeded   // > 1 GiB pulled for this clipboard generation
        case ioFailure(String)  // local write failed

        public var errorDescription: String? {
            switch self {
            case .notActive, .staleGeneration:
                return "The files are no longer available on the remote clipboard."
            case .sendFailed:
                return "The remote session's clipboard channel is not available."
            case .remoteFailed:
                return "The remote host couldn't provide the file's contents."
            case .timedOut:
                return "Timed out waiting for the remote host."
            case .fileTooLarge:
                return "Remote file is larger than the 256 MB per-file limit."
            case .totalCapExceeded:
                return "This paste would exceed the 1 GB transfer limit for one remote copy."
            case .ioFailure(let why):
                return "Couldn't write the file: \(why)"
            }
        }
    }

    /// How requests reach the wire. Closures wrap `RDPSession.requestFileSize/Range`
    /// (which are thread-safe: the C bridge serializes under its own locks), so this is
    /// genuinely Sendable despite capturing the session.
    public struct Sender: @unchecked Sendable {
        let requestSize: (_ streamId: UInt32, _ listIndex: UInt32) -> Bool
        let requestRange: (_ streamId: UInt32, _ listIndex: UInt32,
                           _ offset: UInt64, _ length: UInt32) -> Bool
        public init(requestSize: @escaping (UInt32, UInt32) -> Bool,
                    requestRange: @escaping (UInt32, UInt32, UInt64, UInt32) -> Bool) {
            self.requestSize = requestSize
            self.requestRange = requestRange
        }
    }

    private var sender: Sender?
    private var active = false
    private var currentGeneration = -1
    private var pulledBytesThisGeneration: UInt64 = 0

    // Pending-request table: streamId → continuation (+ its timeout watchdog).
    private var pending: [UInt32: CheckedContinuation<Data?, Never>] = [:]
    private var timeouts: [UInt32: Task<Void, Never>] = [:]
    private var streamIds = RemoteFileClipboard.StreamIdAllocator()

    // Serial-transfer gate (FIFO). Actors are reentrant across awaits, so two promise
    // fulfillments could interleave without this.
    private var transferBusy = false
    private var transferWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Wire the puller to the current session. Called on (re)connect; a nil sender
    /// (disconnect) also deactivates.
    public func setSender(_ newSender: Sender?) {
        sender = newSender
        if newSender == nil { deactivate() }
    }

    /// A new remote file announcement: outstanding pulls belong to a dead clipboard
    /// generation — fail them, reset the total-bytes budget, and accept `generation`.
    public func activate(generation: Int) {
        failAllPending()
        active = true
        currentGeneration = generation
        pulledBytesThisGeneration = 0
    }

    /// The remote clipboard no longer holds files (new text/image copy, disconnect):
    /// fail outstanding pulls and refuse new ones until the next announcement.
    public func deactivate() {
        failAllPending()
        active = false
        currentGeneration = -1
    }

    /// RDP-thread entry (via the nonisolated delegate forward): match a FILECONTENTS
    /// response to its pending request. Unknown streamIds (timed out, superseded, or a
    /// misbehaving server) are dropped harmlessly.
    public func handleResponse(streamId: UInt32, success: Bool, data: Data) {
        timeouts.removeValue(forKey: streamId)?.cancel()
        guard let cont = pending.removeValue(forKey: streamId) else { return }
        cont.resume(returning: success ? data : nil)
    }

    /// Fulfill one file promise: pull `listIndex` (size `announcedSize` when the
    /// descriptor carried one) into `url`. Throws a `PullError`; the caller removes the
    /// partial file on failure.
    public func pull(listIndex: UInt32, announcedSize: UInt64?, generation: Int,
                     to url: URL) async throws {
        await beginTransfer()
        defer { endTransfer() }
        try checkLive(generation)

        // Size: trust FD_FILESIZE when present, else ask (FILECONTENTS_SIZE → 8B LE).
        let size: UInt64
        if let s = announcedSize {
            size = s
        } else {
            guard let reply = await roundTrip(sendRequest: { [sender] sid in
                sender?.requestSize(sid, listIndex) ?? false
            }) else { throw lastFailure(generation) }
            guard reply.count >= 8 else { throw PullError.remoteFailed }
            size = reply.prefix(8).enumerated().reduce(UInt64(0)) { acc, el in
                acc | UInt64(el.element) << (8 * UInt64(el.offset))
            }
        }
        guard size <= Self.maxFileBytes else { throw PullError.fileTooLarge }
        guard pulledBytesThisGeneration + size <= Self.maxTotalBytesPerGeneration else {
            throw PullError.totalCapExceeded
        }

        // Create/truncate the destination and stream chunks into it. The FileHandle
        // write happens on the actor's executor (background), never the main thread.
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw PullError.ioFailure("couldn't create \(url.lastPathComponent)")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: url) } catch {
            throw PullError.ioFailure(error.localizedDescription)
        }
        defer { try? handle.close() }

        var offset: UInt64 = 0
        while true {
            let want = RemoteFileClipboard.chunkLength(at: offset, totalSize: size,
                                                       chunkSize: Self.chunkBytes)
            if want == 0 { break }   // done (a 0-byte file needs zero RANGE pulls)
            try checkLive(generation)
            guard let chunk = await roundTrip(sendRequest: { [sender] sid in
                sender?.requestRange(sid, listIndex, offset, want) ?? false
            }) else { throw lastFailure(generation) }
            // The server may legally return fewer bytes than asked; zero bytes before
            // EOF means the remote file shrank/vanished — fail rather than loop.
            guard !chunk.isEmpty, chunk.count <= Int(want) else { throw PullError.remoteFailed }
            do { try handle.write(contentsOf: chunk) } catch {
                throw PullError.ioFailure(error.localizedDescription)
            }
            offset += UInt64(chunk.count)
            pulledBytesThisGeneration += UInt64(chunk.count)
        }
        do { try handle.close() } catch {
            throw PullError.ioFailure(error.localizedDescription)
        }
    }

    // MARK: - Internals

    private func checkLive(_ generation: Int) throws {
        guard active else { throw PullError.notActive }
        guard generation == currentGeneration else { throw PullError.staleGeneration }
        guard sender != nil else { throw PullError.sendFailed }
    }

    /// Distinguish "why did the round trip return nil" for a better promise error:
    /// a dead/superseded generation reads as invalidation, otherwise a remote failure.
    private func lastFailure(_ generation: Int) -> PullError {
        if !active { return .notActive }
        if generation != currentGeneration { return .staleGeneration }
        return .remoteFailed
    }

    /// One request/response round trip: allocate a streamId, register the
    /// continuation, hand the send closure the id, and arm the 30 s watchdog. Resolves
    /// nil on send failure, server FAIL, timeout, or invalidation.
    private func roundTrip(sendRequest: (UInt32) -> Bool) async -> Data? {
        let sid = streamIds.allocate()
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            pending[sid] = cont
            guard sendRequest(sid) else {
                pending.removeValue(forKey: sid)
                cont.resume(returning: nil)
                return
            }
            timeouts[sid] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: RemoteFilePuller.requestTimeoutSeconds
                                                   * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.timeOut(streamId: sid)
            }
        }
    }

    private func timeOut(streamId: UInt32) {
        timeouts.removeValue(forKey: streamId)
        pending.removeValue(forKey: streamId)?.resume(returning: nil)
    }

    private func failAllPending() {
        for (_, task) in timeouts { task.cancel() }
        timeouts.removeAll()
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting { cont.resume(returning: nil) }
    }

    private func beginTransfer() async {
        if !transferBusy {
            transferBusy = true
            return
        }
        await withCheckedContinuation { transferWaiters.append($0) }
    }

    private func endTransfer() {
        if transferWaiters.isEmpty {
            transferBusy = false
        } else {
            transferWaiters.removeFirst().resume()   // busy stays true for the next one
        }
    }
}
