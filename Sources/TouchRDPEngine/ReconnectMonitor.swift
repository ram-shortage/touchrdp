import Foundation
import Network
#if canImport(AppKit)
import AppKit
#endif

/// Watches two system signals that make a dropped RDP session worth retrying
/// immediately rather than waiting out the exponential backoff:
///   1. The network path transitioning back to `.satisfied` (e.g. Wi-Fi→Ethernet,
///      VPN reconnect, captive-portal cleared).
///   2. The Mac waking from sleep (lid open), after which any prior socket is dead.
///
/// `onTrigger` is always delivered on the main thread. It is advisory: the owner
/// decides whether a reconnect is actually appropriate (it must ignore the signal for
/// user-initiated disconnects, healthy sessions, and non-retryable auth/cert failures).
final class ReconnectMonitor {
    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.touchrdp.reconnect-path")
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    // nil until the first path update; lets us fire only on a genuine
    // unsatisfied→satisfied transition (not the initial "already online" callback).
    private var lastSatisfied: Bool?
    private let onTrigger: @Sendable () -> Void

    init(onTrigger: @escaping @Sendable () -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        guard !started else { return }
        started = true

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = (path.status == .satisfied)
            let was = self.lastSatisfied
            self.lastSatisfied = satisfied
            // Only when the network comes back from a down/unknown state.
            if satisfied, was == false {
                DispatchQueue.main.async { self.onTrigger() }
            }
        }
        pathMonitor.start(queue: queue)

        #if canImport(AppKit)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onTrigger()
        }
        #endif
    }

    func stop() {
        guard started else { return }
        started = false
        pathMonitor.cancel()
        #if canImport(AppKit)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        #endif
    }

    deinit { stop() }
}
