import AppKit
import UniformTypeIdentifiers
import TouchRDPCore
import TouchRDPEngine

/// #25 (remote→Mac file paste): bridges a remote file-clipboard announcement into
/// `NSFilePromiseProvider`s on the local pasteboard.
///
/// Copying files on the REMOTE puts promises (not bytes) on the Mac pasteboard; only
/// when the user pastes/drops in Finder does AppKit call
/// `filePromiseProvider(_:writePromiseTo:)` — and only THEN are the bytes pulled over
/// cliprdr (via `RemoteFilePuller`) and written to Finder's destination. The server
/// can never push file contents unrequested.
///
/// Threading: AppKit invokes the delegate on `promiseQueue` (serial, background). The
/// write callback hops into the puller ACTOR with an unstructured `Task`; the pull
/// coordination and the chunked file writes happen on the actor's (background)
/// executor, and the completion handler is safe to call from there. The main thread
/// only ever stages providers.
///
/// Lifetime: each provider's `userInfo` retains this coordinator, so promises stay
/// fulfillable for as long as ANYTHING (pasteboard, an in-flight Finder drag) still
/// references them — even after a newer announcement replaced the coordinator in the
/// view layer. Staleness is handled by the puller's generation check, not by
/// deallocation races.
final class RemoteFilePromiseCoordinator: NSObject, NSFilePromiseProviderDelegate {
    private let announcement: RemoteFileAnnouncement
    private let puller: RemoteFilePuller
    /// Serial: promises are fulfilled one file at a time (cliprdr is a single channel;
    /// the puller additionally serializes internally).
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.touchrdp.remote-file-promises"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    init(announcement: RemoteFileAnnouncement, puller: RemoteFilePuller) {
        self.announcement = announcement
        self.puller = puller
    }

    /// One `NSFilePromiseProvider` per announced file. The UTType comes from the
    /// (sanitized) name's extension, falling back to plain data.
    func makeProviders() -> [NSFilePromiseProvider] {
        announcement.descriptors.enumerated().map { index, descriptor in
            let ext = (descriptor.name as NSString).pathExtension
            let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = PromiseItem(coordinator: self, descriptorIndex: index)
            return provider
        }
    }

    /// Carried in `provider.userInfo`: which descriptor this promise is for, plus a
    /// strong back-reference that keeps the coordinator alive with the promise.
    private final class PromiseItem: NSObject {
        let coordinator: RemoteFilePromiseCoordinator
        let descriptorIndex: Int
        init(coordinator: RemoteFilePromiseCoordinator, descriptorIndex: Int) {
            self.coordinator = coordinator
            self.descriptorIndex = descriptorIndex
        }
    }

    private func descriptor(for provider: NSFilePromiseProvider)
        -> RemoteFileClipboard.Descriptor? {
        guard let item = provider.userInfo as? PromiseItem,
              announcement.descriptors.indices.contains(item.descriptorIndex)
        else { return nil }
        return announcement.descriptors[item.descriptorIndex]
    }

    // MARK: NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        descriptor(for: filePromiseProvider)?.name ?? "file"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let descriptor = descriptor(for: filePromiseProvider) else {
            completionHandler(RemoteFilePuller.PullError.notActive)
            return
        }
        let puller = self.puller
        let generation = announcement.generation
        // Hop promise-queue → puller actor. `descriptor.size` over 256 MiB (or a paste
        // that would blow the 1 GiB generation budget) fails INSIDE pull with a clear
        // error — the file stays listed on the pasteboard, only its promise fails.
        Task {
            do {
                try await puller.pull(listIndex: descriptor.listIndex,
                                      announcedSize: descriptor.size,
                                      generation: generation,
                                      to: url)
                completionHandler(nil)
            } catch {
                // Never leave a partial file where Finder expects the real one.
                try? FileManager.default.removeItem(at: url)
                completionHandler(error)
            }
        }
    }
}
